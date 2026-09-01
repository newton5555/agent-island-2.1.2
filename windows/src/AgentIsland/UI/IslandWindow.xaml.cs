using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using AgentIsland.Core;
using AgentIsland.UI.Theme;
using AgentIsland.Usage;
using AgentIsland.Model;

namespace AgentIsland.UI;

/// The island itself: a borderless, topmost, per-pixel-transparent window
/// docked to an edge of the chosen screen (top-center by default). Fully
/// transparent pixels pass clicks through to whatever is behind, so only the
/// black silhouette is interactive — the WPF equivalent of the macOS hitTest
/// override.
public partial class IslandWindow : Window
{
    private readonly IslandModel _model = IslandModel.Shared;
    // Unsubscribe actions for the singleton-store handlers, run on Closed —
    // the island is discarded and recreated on a language switch, and without
    // this the dead window stays pinned by the stores and keeps handling
    // events (placement/usage/alert) forever.
    private readonly List<Action> _teardown = new();
    private bool _hovering;
    private System.Windows.Controls.StackPanel? _claudeTitle;
    private System.Windows.Controls.StackPanel? _codexTitle;
    private ResetCardChip? _resetCards;
    private System.Windows.Controls.TextBlock? _claudeChip;
    private System.Windows.Controls.TextBlock? _codexChip;

    /// What the two physical flanks currently carry. Any two of the five
    /// providers can hold the slots (任选两家) — the elements keep their
    /// historical Claude*/Codex* names but are retargeted per selection.
    private TriggerTool? _leftTool = TriggerTool.Claude;
    private TriggerTool? _rightTool = TriggerTool.Codex;

    public IslandWindow()
    {
        InitializeComponent();
        ClaudeLogo.Tool = TriggerTool.Claude;
        CodexLogo.Tool = TriggerTool.Codex;
        ClaudePill.Tool = TriggerTool.Claude;
        CodexPill.Tool = TriggerTool.Codex;
        Loaded += OnLoaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        ApplyEdgeLayout();
        PositionOnScreen();
        // Floating mode: drag the silhouette to move (and remember) the
        // window; a non-drag press still expands.
        Silhouette.MouseLeftButtonDown += OnSilhouetteMouseDown;

        // The sweep ring tracks the silhouette through every spring morph
        // (+4 so half its stroke rides outside the edge).
        Silhouette.SizeChanged += (_, args) =>
        {
            Sweep.Width = args.NewSize.Width + 4;
            Sweep.Height = args.NewSize.Height + 4;
        };
        System.ComponentModel.PropertyChangedEventHandler onLowPower =
            (_, _) => Dispatcher.BeginInvoke(UpdateHalo);
        Model.LowPowerModeStore.Shared.PropertyChanged += onLowPower;
        _teardown.Add(() => Model.LowPowerModeStore.Shared.PropertyChanged -= onLowPower);

        System.ComponentModel.PropertyChangedEventHandler onGlowColor =
            (_, _) => Dispatcher.BeginInvoke(UpdateHalo);
        Model.GlowColorStore.Shared.PropertyChanged += onGlowColor;
        _teardown.Add(() => Model.GlowColorStore.Shared.PropertyChanged -= onGlowColor);

        ApplyInterfaceScale();
        System.ComponentModel.PropertyChangedEventHandler onScale =
            (_, _) => Dispatcher.BeginInvoke(() =>
            {
                ApplyInterfaceScale();
                PositionOnScreen();
            });
        Model.IslandScaleStore.Shared.PropertyChanged += onScale;
        _teardown.Add(() => Model.IslandScaleStore.Shared.PropertyChanged -= onScale);

        System.ComponentModel.PropertyChangedEventHandler onSysParams = (_, args) =>
        {
            if (args.PropertyName is nameof(SystemParameters.WorkArea)
                or nameof(SystemParameters.PrimaryScreenWidth))
            {
                Dispatcher.BeginInvoke(PositionOnScreen);
            }
        };
        SystemParameters.StaticPropertyChanged += onSysParams;
        _teardown.Add(() => SystemParameters.StaticPropertyChanged -= onSysParams);

        // WorkArea/PrimaryScreenWidth only cover the primary display;
        // plug/unplug or resolution changes on a pinned secondary arrive via
        // SystemEvents (the didChangeScreenParameters analog).
        Microsoft.Win32.SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
        _teardown.Add(() =>
            Microsoft.Win32.SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged);

        StartVisibilityWatchdog();

        System.ComponentModel.PropertyChangedEventHandler onTargetDisplay =
            (_, _) => Dispatcher.BeginInvoke(PositionOnScreen);
        Model.IslandTargetDisplayStore.Shared.PropertyChanged += onTargetDisplay;
        _teardown.Add(() => Model.IslandTargetDisplayStore.Shared.PropertyChanged -= onTargetDisplay);

        System.ComponentModel.PropertyChangedEventHandler onPlacement = (_, _) => Dispatcher.BeginInvoke(() =>
        {
            ApplyEdgeLayout();
            PositionOnScreen();
        });
        Model.IslandPositionStore.Shared.PropertyChanged += onPlacement;
        _teardown.Add(() => Model.IslandPositionStore.Shared.PropertyChanged -= onPlacement);
        Closed += (_, _) => { foreach (var teardown in _teardown) teardown(); };

        ApplySizeInstant();
        BuildExpandedChrome();

        System.ComponentModel.PropertyChangedEventHandler onActivity =
            (_, _) => Dispatcher.BeginInvoke(UpdateActivityVisuals);
        ActivityMonitor.Shared.PropertyChanged += onActivity;
        _teardown.Add(() => ActivityMonitor.Shared.PropertyChanged -= onActivity);

        System.ComponentModel.PropertyChangedEventHandler onUsage = (_, _) => Dispatcher.BeginInvoke(() =>
        {
            UpdatePills();
            UpdateHalo();
        });
        UsageStore.Shared.PropertyChanged += onUsage;
        _teardown.Add(() => UsageStore.Shared.PropertyChanged -= onUsage);

        System.ComponentModel.PropertyChangedEventHandler onAlert = (_, args) => Dispatcher.BeginInvoke(() =>
        {
            if (args.PropertyName == nameof(Model.AlertEngine.Pulse)) HandleAlertPulse();
            UpdateHalo();
            UpdatePills();
        });
        Model.AlertEngine.Shared.PropertyChanged += onAlert;
        _teardown.Add(() => Model.AlertEngine.Shared.PropertyChanged -= onAlert);

        // Live layout changes (Settings bar width, provider visibility, solo
        // centering, placement) reflow the collapsed bar with the open
        // spring — everything but state transitions, which SetState drives
        // itself. _model is the IslandModel singleton, so this too must be
        // torn down.
        System.ComponentModel.PropertyChangedEventHandler onModel = (_, args) =>
        {
            if (args.PropertyName != nameof(IslandModel.Size) || _stateDrivenResize) return;
            Dispatcher.BeginInvoke(() =>
            {
                if (_model.State != IslandState.Expanded) AnimateBarMetrics();
            });
        };
        _model.PropertyChanged += onModel;
        _teardown.Add(() => _model.PropertyChanged -= onModel);

        System.ComponentModel.PropertyChangedEventHandler onVisibility =
            (_, _) => Dispatcher.BeginInvoke(ApplyProviderVisibility);
        Model.ProviderVisibilityStore.Shared.PropertyChanged += onVisibility;
        _teardown.Add(() => Model.ProviderVisibilityStore.Shared.PropertyChanged -= onVisibility);

        System.ComponentModel.PropertyChangedEventHandler onAlwaysShow = (_, _) => Dispatcher.BeginInvoke(() =>
        {
            // The Size re-emit lands in onModel, which animates the reflow.
            _model.NotifyAlwaysShowUsageChanged();
            UpdatePills();
        });
        AlwaysShowUsageStore.Shared.PropertyChanged += onAlwaysShow;
        _teardown.Add(() => AlwaysShowUsageStore.Shared.PropertyChanged -= onAlwaysShow);

        ApplyProviderVisibility();
        UpdateActivityVisuals();
        UpdatePills();

        // Scripted layout diagnosis: dump geometry once a second.
        if (Environment.GetEnvironmentVariable("AGENTISLAND_DEBUG_LAYOUTLOG") == "1")
        {
            var log = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            log.Tick += (_, _) =>
            {
                try
                {
                    System.IO.File.AppendAllText(
                        System.IO.Path.Combine(Core.IslandPaths.AppSupportDir, "layout.log"),
                        $"{DateTime.Now:HH:mm:ss.f} state={_model.State} winLeft={Left:F0} winW={Width:F0} " +
                        $"silW={Silhouette.Width:F0} silActualW={Silhouette.ActualWidth:F0} " +
                        $"leftSlot={LeftPillColumn.Width} rightSlot={RightPillColumn.Width} " +
                        $"modelSize={_model.Size.Width:F0}x{_model.Size.Height:F0}\n");
                }
                catch
                {
                }
            };
            log.Start();
        }
    }

    /// Hidden providers drop their logo, peek pill, and expanded title —
    /// the balanced peek width is preserved by the model's fixed slots.
    private void ApplyProviderVisibility()
    {
        var slots = Model.ProviderVisibilityStore.Shared.Slots;
        if (slots.Count >= 2)
        {
            _leftTool = slots[0].ToTriggerTool();
            _rightTool = slots[1].ToTriggerTool();
        }
        else if (slots.Count == 1)
        {
            // Solo keeps the provider on its home flank (macOS
            // SoloLogoFlankIsLeading): Claude/Antigravity/Cursor lead left,
            // Codex/Grok sit right.
            var only = slots[0];
            _leftTool = only.SoloLogoFlankIsLeading() ? only.ToTriggerTool() : null;
            _rightTool = only.SoloLogoFlankIsLeading() ? null : only.ToTriggerTool();
        }
        else
        {
            _leftTool = null;
            _rightTool = null;
        }

        if (_leftTool is { } left) ClaudeLogo.Tool = left;
        if (_rightTool is { } right) CodexLogo.Tool = right;
        // The logo's fixed grid column reserves its slot either way, so we
        // fade opacity (the macOS openMorph spring) rather than hard-toggle
        // Visibility — toggling a provider springs the mark in/out.
        FadeLogo(ClaudeLogo, _leftTool is not null);
        FadeLogo(CodexLogo, _rightTool is not null);
        RetitleFlank(_claudeTitle, _leftTool);
        RetitleFlank(_codexTitle, _rightTool);
        ApplySoloSplit();
        UpdatePlanChips();
        UpdatePills();
    }

    /// Expanded-panel flank title follows its slot's provider.
    private static void RetitleFlank(System.Windows.Controls.StackPanel? title, TriggerTool? tool)
    {
        if (title is null) return;
        title.Visibility = tool is not null ? Visibility.Visible : Visibility.Collapsed;
        if (tool is { } t
            && title.Children.OfType<System.Windows.Controls.TextBlock>().FirstOrDefault() is { } label)
        {
            label.Text = Model.ProviderIdentity.DisplayName(t);
        }
    }

    private static void FadeLogo(UIElement logo, bool visible)
    {
        var fade = new DoubleAnimation(visible ? 1 : 0, IslandAnimations.OpenMorphDuration)
        {
            EasingFunction = IslandAnimations.OpenMorph(),
        };
        logo.BeginAnimation(OpacityProperty, fade);
        logo.IsHitTestVisible = visible;
    }

    /// Pages + footer inside the expanded area; provider titles + plan chips
    /// in the top strip (visible only when expanded, exactly like the macOS
    /// PanelHeader living beside the notch).
    private void BuildExpandedChrome()
    {
        var pages = new PagedContent();
        System.Windows.Controls.Grid.SetRow(pages, 0);
        ExpandedContent.Children.Add(pages);

        var footer = new PanelFooter();
        System.Windows.Controls.Grid.SetRow(footer, 1);
        ExpandedContent.Children.Add(footer);

        // Titles live in the center column, hugging the logo tabs on each
        // side — the macOS PanelHeader arrangement.
        (_claudeTitle, _claudeChip) = MakeProviderTitle("Claude");
        _claudeTitle.HorizontalAlignment = HorizontalAlignment.Left;
        _claudeTitle.Margin = new Thickness(8, 0, 0, 0);
        System.Windows.Controls.Grid.SetColumn(_claudeTitle, 2);
        TopStrip.Children.Add(_claudeTitle);

        (_codexTitle, _codexChip) = MakeProviderTitle("Codex");
        _codexTitle.HorizontalAlignment = HorizontalAlignment.Right;
        _codexTitle.Margin = new Thickness(0, 0, 8, 0);
        System.Windows.Controls.Grid.SetColumn(_codexTitle, 2);
        // Banked-reset count ("reset cards") — the escape hatches of the
        // weekly-only quota era. Always shown, ×0 included, in the dead
        // space left of the title; click for per-card expiry.
        _resetCards = new ResetCardChip { Margin = new Thickness(0, 0, 10, 0) };
        // The popup suppressed the hover-out collapse while it was up; when
        // it closes, run the deferred check — if the mouse has genuinely
        // left the island, fold now instead of hanging open forever.
        _resetCards.PopupClosed += (_, _) => Dispatcher.BeginInvoke(() =>
        {
            if (!Silhouette.IsMouseOver && !_hovering && _model.State != IslandState.Compact)
            {
                SetState(IslandState.Compact);
            }
        });
        _codexTitle.Children.Insert(0, _resetCards);
        TopStrip.Children.Add(_codexTitle);

        System.ComponentModel.PropertyChangedEventHandler onPlanChips =
            (_, _) => Dispatcher.BeginInvoke(UpdatePlanChips);
        UsageStore.Shared.PropertyChanged += onPlanChips;
        _teardown.Add(() => UsageStore.Shared.PropertyChanged -= onPlanChips);
        UpdatePlanChips();

        // Overview needs the taller panel (contribution grid); the size
        // morphs live when paging while expanded — and the persisted page
        // must seed the height at startup, or reopening on Overview squashes
        // the grid.
        ApplyPanelHeightForScreen();
        System.ComponentModel.PropertyChangedEventHandler onScreen = (_, args) =>
        {
            if (args.PropertyName != nameof(ScreenPref.Screen)) return;
            Dispatcher.BeginInvoke(() =>
            {
                ApplyPanelHeightForScreen();
                if (_model.State == IslandState.Expanded)
                {
                    AnimateSize(_model.Size, open: true);
                }
            });
        };
        ScreenPref.Shared.PropertyChanged += onScreen;
        _teardown.Add(() => ScreenPref.Shared.PropertyChanged -= onScreen);
    }

    private void ApplyPanelHeightForScreen() =>
        _model.ExpandedContentHeight = ScreenPref.Shared.Screen == IslandScreen.Overview
            ? IslandModel.OverviewContentHeight
            : IslandModel.UsageContentHeight;

    private static (System.Windows.Controls.StackPanel Panel, System.Windows.Controls.TextBlock Chip) MakeProviderTitle(string name)
    {
        var panel = new System.Windows.Controls.StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center,
            Opacity = 0,
            IsHitTestVisible = false,
        };
        panel.Children.Add(new System.Windows.Controls.TextBlock
        {
            Text = name,
            FontFamily = Charts.IslandFonts.Ui,
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brushes.White,
            VerticalAlignment = VerticalAlignment.Center,
        });
        var chip = new System.Windows.Controls.TextBlock
        {
            FontFamily = Charts.IslandFonts.Mono,
            FontSize = 9,
            FontWeight = FontWeights.Bold,
            Foreground = IslandColors.Brush(IslandColors.White(0.78)),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var chipHost = new System.Windows.Controls.Border
        {
            Child = chip,
            CornerRadius = new CornerRadius(3),
            Background = IslandColors.Brush(IslandColors.White(0.06)),
            BorderBrush = IslandColors.Brush(IslandColors.White(0.08)),
            BorderThickness = new Thickness(0.5),
            Padding = new Thickness(5, 2, 5, 2),
            Margin = new Thickness(8, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        panel.Children.Add(chipHost);
        return (panel, chip);
    }

    private void UpdatePlanChips()
    {
        UpdateChip(_claudeChip, _leftTool is { } l ? UsagePage.UsageFor(l.ToDisplayProvider()).Plan : null);
        UpdateChip(_codexChip, _rightTool is { } r ? UsagePage.UsageFor(r.ToDisplayProvider()).Plan : null);
        if (_resetCards is not null)
        {
            // The banked-reset chip is Codex data living inside the right
            // title panel; any other occupant collapses it — and it only
            // exists at all when a card is actually banked (macOS
            // PanelHeader: resetCards > 0; a permanent ×0 was noise).
            var store = UsageStore.Shared;
            var codexRight = _rightTool == TriggerTool.Codex;
            var banked = (store.Codex.ResetCards ?? 0) > 0;
            _resetCards.Visibility = codexRight && banked ? Visibility.Visible : Visibility.Collapsed;
            if (codexRight && banked)
            {
                _resetCards.Update(store.Codex.ResetCards, store.Codex.ResetCardDetails);
            }
        }
    }

    private static void UpdateChip(System.Windows.Controls.TextBlock? chip, string? plan)
    {
        if (chip is null) return;
        var host = (System.Windows.Controls.Border)chip.Parent;
        if (string.IsNullOrEmpty(plan))
        {
            host.Visibility = Visibility.Collapsed;
        }
        else
        {
            host.Visibility = Visibility.Visible;
            chip.Text = plan.ToUpperInvariant();
        }
    }

    private bool IsFloating =>
        Model.IslandPositionStore.Shared.Placement == Model.IslandPlacement.Floating;

    private void PositionOnScreen()
    {
        var area = WorkAreaDip(Model.IslandTargetDisplayStore.Shared.Resolve());
        var store = Model.IslandPositionStore.Shared;
        if (store.Placement == Model.IslandPlacement.Floating)
        {
            var pt = store.FloatingPoint;
            if (pt is { } p)
            {
                // Clamp the VISIBLE silhouette (not the oversized
                // transparent canvas) so the island can be parked right
                // at a screen edge; the canvas simply overhangs off-screen.
                var silW = Silhouette.ActualWidth > 0 ? Silhouette.ActualWidth : 280;
                var silH = Silhouette.ActualHeight > 0 ? Silhouette.ActualHeight : IslandModel.SilhouetteHeight;
                var insetX = (Width - silW) / 2; // silhouette is centered in the canvas
                var minLeft = area.Left - insetX;
                var maxLeft = area.Right - silW - insetX;
                var maxTop = area.Bottom - silH;
                Left = Math.Clamp(p.X, minLeft, Math.Max(minLeft, maxLeft));
                Top = Math.Clamp(p.Y, area.Top, Math.Max(area.Top, maxTop));
            }
            else
            {
                Left = area.Left + (area.Width - Width) / 2;
                Top = area.Top + 72;
            }
        }
        else
        {
            Left = area.Left + (area.Width - Width) / 2;
            Top = area.Top;
        }
    }

    /// The chosen monitor's work area (taskbar excluded, so a top-docked
    /// taskbar pushes the island below it) in WPF units. WinForms screens
    /// report physical pixels; TransformFromDevice maps them into this
    /// window's DIP space.
    private Rect WorkAreaDip(System.Windows.Forms.Screen screen)
    {
        var area = screen.WorkingArea;
        if (PresentationSource.FromVisual(this)?.CompositionTarget is { } target)
        {
            var device = target.TransformFromDevice;
            return new Rect(
                device.Transform(new Point(area.Left, area.Top)),
                device.Transform(new Point(area.Right, area.Bottom)));
        }
        return SystemParameters.WorkArea;
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e) =>
        Dispatcher.BeginInvoke(PositionOnScreen);

    /// The island must never stay gone (macOS 2.1.2 parity — the same
    /// belt-and-suspenders rule that fixed "the island randomly
    /// disappears" there). On Windows the vanish paths are z-order theft
    /// (a fullscreen or topmost app parks itself above; explorer restarts
    /// drop the band) and a stray Hide. A slow sweep re-asserts both.
    /// SetWindowPos with NOACTIVATE never steals focus, so the sweep is
    /// invisible when nothing was wrong.
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool SetWindowPos(
        IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint flags);

    private static readonly IntPtr HwndTopmost = new(-1);
    private const uint SwpNoMove = 0x2;
    private const uint SwpNoSize = 0x1;
    private const uint SwpNoActivate = 0x10;

    /// Set when the user hid the island through the tray toggle — the
    /// watchdog must never fight a deliberate hide.
    public bool DeliberatelyHidden;

    private void StartVisibilityWatchdog()
    {
        var sweep = new System.Windows.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(20),
        };
        sweep.Tick += (_, _) =>
        {
            if (!IsVisible && !DeliberatelyHidden)
            {
                Show();
                PositionOnScreen();
            }
            var handle = new System.Windows.Interop.WindowInteropHelper(this).Handle;
            if (handle != IntPtr.Zero)
            {
                SetWindowPos(handle, HwndTopmost, 0, 0, 0, 0,
                    SwpNoMove | SwpNoSize | SwpNoActivate);
            }
        };
        sweep.Start();
        _teardown.Add(sweep.Stop);
    }

    /// Top bar sits flush against the screen edge, so only its bottom
    /// corners round; a floating island rounds all four.
    private CornerRadius ShapeRadius(double radius) => IsFloating
        ? new CornerRadius(radius)
        : new CornerRadius(0, 0, radius, radius);

    /// Hidden panel content parks 8px toward the bar strip so the expand
    /// reveal always slides down and away from it.
    private const double PanelRestY = -8;

    /// Re-shapes the silhouette corners for the current placement.
    private void ApplyEdgeLayout()
    {
        Silhouette.CornerRadius = ShapeRadius(_model.CornerRadius);
        Sweep.CornerRadius = ShapeRadius(_model.CornerRadius + 2);
        if (_model.State != IslandState.Expanded)
        {
            ContentSlide.BeginAnimation(TranslateTransform.YProperty, null);
            ContentSlide.Y = PanelRestY;
        }
    }

    // MARK: - State transitions

    private DispatcherTimer? _hoverIntent;

    private void OnSilhouetteMouseEnter(object sender, MouseEventArgs e)
    {
        _hovering = true;
        UpdateHalo();
        if (_model.State != IslandState.Compact) return;
        // Hover intent: unlike the macOS notch, this island sits where the
        // cursor routinely passes straight THROUGH it (especially floating
        // placement mid-screen). Peeking on raw enter made every pass-over
        // pop the bar open and snap it shut. The halo still lights up
        // instantly above; the size morph waits until the cursor has
        // actually settled on the island.
        _hoverIntent?.Stop();
        var intent = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(120) };
        _hoverIntent = intent;
        intent.Tick += (_, _) =>
        {
            intent.Stop();
            if (_hovering && _model.State == IslandState.Compact)
            {
                SetState(IslandState.Peek);
            }
        };
        intent.Start();
    }

    private void OnSilhouetteMouseLeave(object sender, MouseEventArgs e)
    {
        _hovering = false;
        _hoverIntent?.Stop();
        UpdateHalo();
        // Pills fade first (~80ms), then the silhouette springs back.
        var delay = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(80) };
        delay.Tick += (_, _) =>
        {
            delay.Stop();
            // The reset-card popup steals the mouse the instant it opens,
            // which reads as a MouseLeave here — folding the panel would
            // yank the popup shut mid-look. Hold the panel while it's up;
            // its Closed handler runs this collapse check again.
            if (_resetCards?.IsPopupOpen == true) return;
            if (!_hovering && _model.State != IslandState.Compact)
            {
                SetState(IslandState.Compact);
            }
        };
        if (_model.State == IslandState.Peek)
        {
            // With "always show usage" the percentages stay painted on the
            // compact bar, so nothing fades on the way out.
            FadePills(visible: AlwaysShowUsageStore.Shared.Enabled, delayMs: 0, seconds: 0.08);
        }
        delay.Start();
    }

    /// In Floating mode a left-press either drags the window (and persists
    /// the new spot) or, if it barely moved, counts as the click that
    /// expands. DragMove swallows the mouse-up, so we drive expand here and
    /// let OnSilhouetteClick bail for floating.
    private void OnSilhouetteMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (Model.IslandPositionStore.Shared.Placement != Model.IslandPlacement.Floating) return;
        if (_model.State != IslandState.Compact && _model.State != IslandState.Peek) return;
        var startLeft = Left;
        var startTop = Top;
        try { DragMove(); } catch { }
        var moved = Math.Abs(Left - startLeft) > 3 || Math.Abs(Top - startTop) > 3;
        if (moved)
        {
            Model.IslandPositionStore.Shared.SetFloatingPoint(Left, Top);
            // Settle into the clamped resting spot now, so it matches where a
            // later reposition (display change / relaunch) would place it.
            PositionOnScreen();
        }
        else if (_model.State is IslandState.Peek or IslandState.Compact)
        {
            SetState(IslandState.Expanded);
            Activate();
            Focus();
        }
        e.Handled = true;
    }

    /// Scripted glow/sweep verification: render the live visual tree (sweep +
    /// halo effects included) to a PNG, composited over a desktop-like grey so
    /// the aura reads the way it does on screen. Immune to window occlusion —
    /// a plain screen grab loses to whatever sits on top of the topmost bar.
    public void SaveVisualSnapshot(string path)
    {
        var settle = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(600) };
        settle.Tick += (_, _) =>
        {
            settle.Stop();
            try
            {
                var w = (int)Math.Ceiling(RootHost.ActualWidth);
                var h = (int)Math.Ceiling(RootHost.ActualHeight);
                if (w <= 0 || h <= 0) return;
                var visual = new DrawingVisual();
                using (var dc = visual.RenderOpen())
                {
                    // The light desktop the island actually floats over, so the
                    // glow spread shows against a real backdrop, not transparency.
                    dc.DrawRectangle(
                        new SolidColorBrush(Color.FromRgb(0xF2, 0xF2, 0xF2)),
                        null, new Rect(0, 0, w, h));
                    dc.DrawRectangle(new VisualBrush(RootHost), null, new Rect(0, 0, w, h));
                }
                var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap(
                    w, h, 96, 96, PixelFormats.Pbgra32);
                bitmap.Render(visual);
                var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
                encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));
                using var stream = System.IO.File.Create(path);
                encoder.Save(stream);
            }
            catch
            {
            }
        };
        settle.Start();
    }

    /// Bring the island up and open it — the tray-icon launcher.
    public void PopUp()
    {
        Show();
        ApplyEdgeLayout();
        PositionOnScreen();
        if (_model.State != IslandState.Expanded) SetState(IslandState.Expanded);
        Activate();
        Focus();
    }

    private void OnSilhouetteClick(object sender, MouseButtonEventArgs e)
    {
        // Floating handles expand in the mouse-down path (DragMove consumes
        // the up), so ignore the click there to avoid a double expand.
        if (Model.IslandPositionStore.Shared.Placement == Model.IslandPlacement.Floating) return;
        if (_model.State is IslandState.Peek or IslandState.Compact)
        {
            SetState(IslandState.Expanded);
            // Take focus so the wheel and arrow keys page the carousel even
            // when Windows' hover-scroll setting is off.
            Activate();
            Focus();
        }
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (_model.State != IslandState.Expanded) return;
        switch (e.Key)
        {
            case Key.Right:
                ScreenPref.Shared.ShowNext(1);
                e.Handled = true;
                break;
            case Key.Left:
                ScreenPref.Shared.ShowNext(-1);
                e.Handled = true;
                break;
        }
    }

    /// True while SetState mutates the model — its Size re-emit must not
    /// ALSO trigger the live-reflow path (SetState animates everything
    /// itself with the state-appropriate spring).
    private bool _stateDrivenResize;

    private void SetState(IslandState state)
    {
        var previous = _model.State;
        if (previous == state) return;
        _stateDrivenResize = true;
        _model.State = state;
        _stateDrivenResize = false;

        var open = state != IslandState.Compact
            && (previous == IslandState.Compact || state == IslandState.Expanded);
        ApplySoloSplit();
        AnimateSize(_model.Size, open);
        AnimatePillSlots(open);
        AnimateTabColumns(open);
        Silhouette.CornerRadius = ShapeRadius(_model.CornerRadius);
        Sweep.CornerRadius = ShapeRadius(_model.CornerRadius + 2);

        // Expanded panel gains the hairline stroke and grounding shadow of
        // the macOS GlowLayer; both drop on collapse.
        var expanded = state == IslandState.Expanded;
        Silhouette.BorderBrush = expanded ? IslandColors.Brush(IslandColors.White(0.12)) : null;
        Silhouette.BorderThickness = new Thickness(expanded ? 0.5 : 0);
        RootHost.Effect = expanded
            ? new System.Windows.Media.Effects.DropShadowEffect
            {
                Color = Colors.Black,
                Opacity = 0.5,
                // macOS radius 20 is a sigma; WPF's kernel-extent BlurRadius
                // needs ~3x for the same soft grounding falloff.
                BlurRadius = 60,
                ShadowDepth = 10,
                // Grounding shadow falls downward, away from the bar strip.
                Direction = 270,
            }
            : null;

        switch (state)
        {
            case IslandState.Peek:
                // Shape commits first, pills follow.
                FadePills(visible: true, delayMs: 60, seconds: 0.18);
                break;
            case IslandState.Expanded:
                ShowExpandedContent();
                // Opening the island refreshes usage when it has gone stale,
                // so the numbers are current the moment you look — gated by
                // the poll interval, so it never out-polls the schedule.
                UsageStore.Shared.RefreshIfStale();
                // Pills travel with the growing shape, then cross-fade out
                // after the expanded content has settled.
                FadePills(visible: false, delayMs: 250, seconds: 0.18);
                StartPanelHeartbeat();
                break;
            case IslandState.Compact:
            default:
                FadePills(visible: AlwaysShowUsageStore.Shared.Enabled, delayMs: 0, seconds: 0.08);
                HideExpandedContent();
                break;
        }
        if (state != IslandState.Expanded) StopPanelHeartbeat();
    }

    // Heartbeat failsafe for the black expanded panel (macOS IslandRootView):
    // expanded with invisible content is never a legal steady state. The
    // WPF choreography triggers the content fade in the same call as the
    // state flip, so the macOS timer races shouldn't exist here — but any
    // path that strands the panel dark (an animation clobbered elsewhere, a
    // visual rebuilt under an expanded model) gets healed within 0.6s
    // instead of reading as a crash. Runs only while expanded, so the idle
    // island keeps zero timers.
    private DispatcherTimer? _panelHeartbeat;
    private long _lastShowContentMs;

    private void StartPanelHeartbeat()
    {
        if (_panelHeartbeat is not null) return;
        _panelHeartbeat = new DispatcherTimer { Interval = TimeSpan.FromSeconds(0.6) };
        _panelHeartbeat.Tick += (_, _) =>
        {
            if (_model.State != IslandState.Expanded) return;
            // Give the entrance choreography (180ms delay + fade) room; only
            // an opacity still pinned near zero well after it ran is stuck.
            var settled = Environment.TickCount64 - _lastShowContentMs > 700;
            if (ExpandedContent.Visibility != Visibility.Visible
                || (ExpandedContent.Opacity < 0.01 && settled))
            {
                ShowExpandedContent();
            }
        };
        _panelHeartbeat.Start();
    }

    private void StopPanelHeartbeat()
    {
        _panelHeartbeat?.Stop();
        _panelHeartbeat = null;
    }

    private void AnimateSize(Size target, bool open)
    {
        var duration = open ? IslandAnimations.OpenMorphDuration : IslandAnimations.CloseMorphDuration;
        SpringEase ease = open ? IslandAnimations.OpenMorph() : IslandAnimations.CloseMorph();
        var width = new DoubleAnimation(target.Width, duration) { EasingFunction = ease };
        var height = new DoubleAnimation(target.Height, duration) { EasingFunction = ease };
        Silhouette.BeginAnimation(WidthProperty, width);
        Silhouette.BeginAnimation(HeightProperty, height);
    }

    private void ApplySizeInstant()
    {
        Silhouette.BeginAnimation(WidthProperty, null);
        Silhouette.BeginAnimation(HeightProperty, null);
        var size = _model.Size;
        Silhouette.Width = size.Width;
        Silhouette.Height = size.Height;
        Silhouette.CornerRadius = ShapeRadius(_model.CornerRadius);
        Sweep.CornerRadius = ShapeRadius(_model.CornerRadius + 2);
        SetColumnInstant(LeftPillColumn, PillSlotTarget());
        SetColumnInstant(RightPillColumn, PillSlotTarget());
        SetColumnInstant(ClaudeTabColumn, IslandModel.TabWidth);
        SetColumnInstant(CodexTabColumn, IslandModel.TabWidth);
        ApplySoloSplit();
    }

    private static void SetColumnInstant(System.Windows.Controls.ColumnDefinition column, double width)
    {
        column.BeginAnimation(System.Windows.Controls.ColumnDefinition.WidthProperty, null);
        column.Width = new GridLength(width);
    }

    /// Morph the collapsed bar to the model's current metrics — silhouette,
    /// pill slots, and tab columns — with the open spring. Drives live
    /// layout changes (provider visibility, solo centering, placement, bar
    /// width) so the bar reflows instead of snapping.
    private void AnimateBarMetrics()
    {
        ApplySoloSplit();
        AnimateSize(_model.Size, open: true);
        AnimatePillSlots(open: true);
        AnimateTabColumns(open: true);
    }

    /// Pill slots exist in peek — and in compact when "always show usage"
    /// keeps the percentages painted; they collapse in expanded so the logo
    /// tabs glide out to the panel corners. In the solo split both slots
    /// stay open (one carries the logo, the other the number), keeping the
    /// bar symmetric around the notch.
    private double PillSlotTarget()
    {
        return _model.State switch
        {
            IslandState.Peek => IslandModel.PillSlotWidth,
            IslandState.Compact when AlwaysShowUsageStore.Shared.Enabled => IslandModel.PillSlotWidth,
            _ => 0,
        };
    }

    private void AnimatePillSlots(bool open)
    {
        AnimateColumn(LeftPillColumn, PillSlotTarget(), open);
        AnimateColumn(RightPillColumn, PillSlotTarget(), open);
    }

    private void AnimateTabColumns(bool open)
    {
        AnimateColumn(ClaudeTabColumn, IslandModel.TabWidth, open);
        AnimateColumn(CodexTabColumn, IslandModel.TabWidth, open);
    }

    /// Solo split (macOS 9ee4219): with one subscription the collapsed bar
    /// keeps its full symmetric width and splits the flanks — the lone logo
    /// rides the OUTER slot on its provider's side (14pt off the edge, where
    /// a pill would sit) and its usage pill crosses to the opposite flank.
    /// With both providers (or in expanded, where logos glide to the panel
    /// corners) everything returns to its home column.
    private void ApplySoloSplit()
    {
        var leftSolo = _leftTool is not null && _rightTool is null;
        var rightSolo = _rightTool is not null && _leftTool is null;
        var slotted = _model.State == IslandState.Peek
            || (_model.State == IslandState.Compact && AlwaysShowUsageStore.Shared.Enabled);

        // Claude logo: home is column 1 (centered tab); solo puts it in the
        // left slot, tucked to the edge.
        if (leftSolo && slotted)
        {
            System.Windows.Controls.Grid.SetColumn(ClaudeLogo, 0);
            ClaudeLogo.HorizontalAlignment = HorizontalAlignment.Left;
            ClaudeLogo.Margin = new Thickness(14, 0, 0, 0);
        }
        else
        {
            System.Windows.Controls.Grid.SetColumn(ClaudeLogo, 1);
            ClaudeLogo.HorizontalAlignment = HorizontalAlignment.Center;
            ClaudeLogo.Margin = new Thickness(0);
        }

        if (rightSolo && slotted)
        {
            System.Windows.Controls.Grid.SetColumn(CodexLogo, 4);
            CodexLogo.HorizontalAlignment = HorizontalAlignment.Right;
            CodexLogo.Margin = new Thickness(0, 0, 14, 0);
        }
        else
        {
            System.Windows.Controls.Grid.SetColumn(CodexLogo, 3);
            CodexLogo.HorizontalAlignment = HorizontalAlignment.Center;
            CodexLogo.Margin = new Thickness(0);
        }

        // Pills: the solo provider's number crosses to the opposite flank;
        // duo keeps each pill outboard of its own logo.
        if (leftSolo)
        {
            System.Windows.Controls.Grid.SetColumn(ClaudePill, 4);
            ClaudePill.HorizontalAlignment = HorizontalAlignment.Right;
            ClaudePill.Margin = new Thickness(6, 0, 14, 0);
        }
        else
        {
            System.Windows.Controls.Grid.SetColumn(ClaudePill, 0);
            ClaudePill.HorizontalAlignment = HorizontalAlignment.Left;
            ClaudePill.Margin = new Thickness(14, 0, 6, 0);
        }

        if (rightSolo)
        {
            System.Windows.Controls.Grid.SetColumn(CodexPill, 0);
            CodexPill.HorizontalAlignment = HorizontalAlignment.Left;
            CodexPill.Margin = new Thickness(14, 0, 6, 0);
        }
        else
        {
            System.Windows.Controls.Grid.SetColumn(CodexPill, 4);
            CodexPill.HorizontalAlignment = HorizontalAlignment.Right;
            CodexPill.Margin = new Thickness(6, 0, 14, 0);
        }
    }

    private static void AnimateColumn(System.Windows.Controls.ColumnDefinition column, double target, bool open)
    {
        var animation = new GridLengthAnimation
        {
            From = column.Width,
            To = new GridLength(target),
            Duration = open ? IslandAnimations.OpenMorphDuration : IslandAnimations.CloseMorphDuration,
            EasingFunction = open ? IslandAnimations.OpenMorph() : IslandAnimations.CloseMorph(),
            FillBehavior = FillBehavior.Stop,
        };
        animation.Completed += (_, _) => column.Width = new GridLength(target);
        column.BeginAnimation(System.Windows.Controls.ColumnDefinition.WidthProperty, animation);
    }

    private void FadePills(bool visible, int delayMs, double seconds)
    {
        var fade = new DoubleAnimation(visible ? 1 : 0, new Duration(TimeSpan.FromSeconds(seconds)))
        {
            BeginTime = TimeSpan.FromMilliseconds(delayMs),
            EasingFunction = new QuadraticEase
            {
                EasingMode = visible ? EasingMode.EaseOut : EasingMode.EaseIn,
            },
        };
        ClaudePill.BeginAnimation(OpacityProperty, fade);
        CodexPill.BeginAnimation(OpacityProperty, fade.Clone());
    }

    private void ShowExpandedContent()
    {
        _lastShowContentMs = Environment.TickCount64;
        ExpandedContent.Visibility = Visibility.Visible;
        SettingsGear.Visibility = Visibility.Visible;
        var fade = new DoubleAnimation(1, IslandAnimations.StrongEaseOutDuration)
        {
            BeginTime = TimeSpan.FromMilliseconds(180),
            EasingFunction = IslandAnimations.StrongEaseOut(),
        };
        var slide = new DoubleAnimation(0, IslandAnimations.StrongEaseOutDuration)
        {
            BeginTime = TimeSpan.FromMilliseconds(180),
            EasingFunction = IslandAnimations.StrongEaseOut(),
        };
        ExpandedContent.BeginAnimation(OpacityProperty, fade);
        ContentSlide.BeginAnimation(TranslateTransform.YProperty, slide);
        _claudeTitle?.BeginAnimation(OpacityProperty, fade.Clone());
        _codexTitle?.BeginAnimation(OpacityProperty, fade.Clone());
        // The titles are built hit-test-off so the invisible strip never eats
        // bar clicks; expanded they host a real control (the reset-card chip).
        if (_codexTitle is not null) _codexTitle.IsHitTestVisible = true;
        SettingsGear.BeginAnimation(OpacityProperty, fade.Clone());
    }

    private void HideExpandedContent()
    {
        var fade = new DoubleAnimation(0, new Duration(TimeSpan.FromSeconds(0.12)))
        {
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseIn },
        };
        fade.Completed += (_, _) =>
        {
            if (_model.State == IslandState.Compact)
            {
                ExpandedContent.Visibility = Visibility.Collapsed;
                SettingsGear.Visibility = Visibility.Collapsed;
                ContentSlide.BeginAnimation(TranslateTransform.YProperty, null);
                ContentSlide.Y = PanelRestY;
            }
        };
        ExpandedContent.BeginAnimation(OpacityProperty, fade);
        _claudeTitle?.BeginAnimation(OpacityProperty, fade.Clone());
        _codexTitle?.BeginAnimation(OpacityProperty, fade.Clone());
        if (_codexTitle is not null) _codexTitle.IsHitTestVisible = false;
        SettingsGear.BeginAnimation(OpacityProperty, fade.Clone());
    }

    private void OnSettingsGearClick(object sender, MouseButtonEventArgs e)
    {
        SettingsWindow.Open();
        e.Handled = true;
    }

    private void OnSettingsGearEnter(object sender, MouseEventArgs e) =>
        SettingsGear.Foreground = IslandColors.Brush(IslandColors.White(0.9));

    private void OnSettingsGearLeave(object sender, MouseEventArgs e) =>
        SettingsGear.Foreground = IslandColors.Brush(IslandColors.White(0.45));

    // MARK: - Live state visuals

    private void UpdateActivityVisuals()
    {
        var monitor = ActivityMonitor.Shared;
        ClaudeLogo.SetState(monitor.Claude);
        CodexLogo.SetState(monitor.Codex);
        UpdateHalo();
    }

    private enum HaloMode
    {
        Rest,
        WarningTint,
        CriticalTint,
        AttentionSteady,
        AttentionPulse,
    }

    private HaloMode _haloMode = HaloMode.Rest;
    private readonly RotateTransform _sweepRotate = new() { CenterX = 0.5, CenterY = 0.5 };
    private Color _sweepTint;
    private bool _sweepActive;
    private bool _sweepSpinning;

    /// Stalled/rate-limited pulse the halo red (opacity and radius breathe
    /// together, macOS GlowLayer numbers); auth-required holds a static red
    /// — a login can pend for hours and endless blinking reads as a crash;
    /// threshold alerts hold a sustained amber/red tint; at rest, Vivid keeps
    /// the ambient aura in the chosen glow color and Calm keeps nothing at
    /// all — no hover or refresh light, ambient is a mode, not an event
    /// (macOS 1.7 semantics). Hidden providers don't get a vote.
    /// Interface scale (macOS 1f97e4d): a LayoutTransform on the canvas
    /// magnifies every layout constant at once, and the window grows with
    /// it so nothing clips. The positioning math already keys on the
    /// window's Width, so centering holds at any scale.
    private void ApplyInterfaceScale()
    {
        var scale = Model.IslandScaleStore.Shared.Scale;
        RootHost.LayoutTransform = Math.Abs(scale - 1.0) < 0.001
            ? null
            : new ScaleTransform(scale, scale);
        Width = 900 * scale;
        Height = 360 * scale;
    }

    private static bool AttentionShown()
    {
        var monitor = ActivityMonitor.Shared;
        return Model.ProviderVisibilityStore.Shared.Slots
            .Any(provider => monitor.StateFor(provider.ToTriggerTool()).IsAttentionState());
    }

    private void UpdateHalo()
    {
        var monitor = ActivityMonitor.Shared;
        var pulsing = Model.ProviderVisibilityStore.Shared.Slots
            .Any(provider => monitor.StateFor(provider.ToTriggerTool()).PulsesAttention());
        var attention = AttentionShown();
        var severity = Model.AlertEngine.Shared.Severity;
        var mode = pulsing
            ? HaloMode.AttentionPulse
            : attention
                ? HaloMode.AttentionSteady
                : severity switch
                {
                    Model.AlertSeverity.Critical => HaloMode.CriticalTint,
                    Model.AlertSeverity.Warning => HaloMode.WarningTint,
                    _ => HaloMode.Rest,
                };
        if (mode != _haloMode)
        {
            _haloMode = mode;
            Halo.BeginAnimation(System.Windows.Media.Effects.DropShadowEffect.BlurRadiusProperty, null);
            Halo.BeginAnimation(System.Windows.Media.Effects.DropShadowEffect.OpacityProperty, null);
            switch (mode)
            {
                case HaloMode.AttentionPulse:
                    Halo.Color = IslandColors.AlertRed;
                    var half = IslandAnimations.AttentionPulseDuration.TimeSpan;
                    // Opacity only, frame-capped: animating BlurRadius
                    // re-runs the gaussian per frame on the CPU, and every
                    // frame recomposites the whole layered window. The
                    // brightness swing carries the pulse.
                    var strength = new DoubleAnimation(0.3, 0.9, new Duration(half))
                    {
                        AutoReverse = true,
                        RepeatBehavior = RepeatBehavior.Forever,
                        EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
                    };
                    Timeline.SetDesiredFrameRate(strength, 24);
                    Halo.BlurRadius = 54;
                    Halo.BeginAnimation(System.Windows.Media.Effects.DropShadowEffect.OpacityProperty, strength);
                    break;
                case HaloMode.AttentionSteady:
                    // authRequired: red, steady 0.55 — attention without the
                    // pulse (macOS GlowLayer).
                    Halo.Color = IslandColors.AlertRed;
                    Halo.Opacity = 0.55;
                    Halo.BlurRadius = 42;
                    break;
                case HaloMode.CriticalTint:
                    Halo.Color = IslandColors.AlertRed;
                    Halo.Opacity = 0.35;
                    Halo.BlurRadius = 42;
                    break;
                case HaloMode.WarningTint:
                    Halo.Color = IslandColors.AlertAmber;
                    Halo.Opacity = 0.35;
                    Halo.BlurRadius = 42;
                    break;
                case HaloMode.Rest:
                default:
                    Halo.Opacity = 0.35;
                    Halo.BlurRadius = 42;
                    break;
            }
        }
        // At rest the halo IS the ambient light: Vivid paints it in the
        // chosen glow color, Calm turns it fully off. Color is re-applied
        // every pass (not only on mode changes) so a swatch click lands
        // without a state flip. EffectiveEnabled folds in the battery saver.
        if (_haloMode == HaloMode.Rest)
        {
            Halo.Color = Model.GlowColorStore.Shared.Color;
            Halo.Opacity = Model.LowPowerModeStore.Shared.EffectiveEnabled ? 0 : 0.35;
        }
        UpdateSweep();
    }

    /// The orbit sweep hugging the island edge. Vivid keeps it alive
    /// continuously in the glow color (alert tints override); Calm shows no
    /// ambient light, so it never spins there — hover and refresh no longer
    /// light anything (macOS 1.7: ambient is a mode, not an event).
    private void UpdateSweep()
    {
        var attention = AttentionShown();
        var tint = attention
            ? IslandColors.AlertRed
            : Model.AlertEngine.Shared.Severity switch
            {
                Model.AlertSeverity.Critical => IslandColors.AlertRed,
                Model.AlertSeverity.Warning => IslandColors.AlertAmber,
                _ => Model.GlowColorStore.Shared.Color,
            };
        var active = !Model.LowPowerModeStore.Shared.EffectiveEnabled;
        if (active == _sweepActive && tint == _sweepTint) return;
        _sweepActive = active;
        _sweepTint = tint;
        if (!active)
        {
            Sweep.Visibility = Visibility.Collapsed;
            _sweepTimer?.Stop();
            _sweepSpinning = false;
            return;
        }
        Sweep.Visibility = Visibility.Visible;
        // The brush swaps with the tint, but the shared transform keeps the
        // rotation phase, so recolors never visibly restart the sweep.
        Sweep.BorderBrush = ConicSweepBrush.Make(tint, _sweepRotate);
        if (!_sweepSpinning)
        {
            _sweepSpinning = true;
            // 100°/s like the macOS TimelineView sweep — but stepped at
            // 15fps by a timer, not a smooth 60fps animation. Every frame
            // recomposites the whole layered window in software (measured:
            // the smooth spin held 47% of a core); at 15 steps/s the comet
            // is a soft blur whose 6.7° hops read as motion, and the cost
            // drops to roughly a quarter. macOS spins free on Metal.
            if (_sweepTimer is null)
            {
                _sweepTimer = new DispatcherTimer(DispatcherPriority.Render)
                {
                    Interval = TimeSpan.FromMilliseconds(66),
                };
                _sweepTimer.Tick += (_, _) =>
                    _sweepRotate.Angle = (_sweepRotate.Angle + 6.67) % 360;
            }
            _sweepTimer.Start();
        }
    }

    private DispatcherTimer? _sweepTimer;

    private void UpdatePills()
    {
        var store = UsageStore.Shared;
        var engine = Model.AlertEngine.Shared;
        if (_leftTool is { } leftTool)
        {
            ClaudePill.Update(
                UsagePage.UsageFor(leftTool.ToDisplayProvider()).FiveHour,
                store.Loading,
                engine.SeverityFor(leftTool));
        }
        if (_rightTool is { } rightTool)
        {
            CodexPill.Update(
                UsagePage.UsageFor(rightTool.ToDisplayProvider()).FiveHour,
                store.Loading,
                engine.SeverityFor(rightTool));
        }

        // In compact, the pills normally hide. "Always show usage" keeps the
        // visible providers' 5h percent painted on the bare silhouette. A
        // finished FadePills animation holds the opacity, so detach it
        // before assigning or the value silently never lands.
        var alwaysShow = AlwaysShowUsageStore.Shared.Enabled && _model.State == IslandState.Compact;
        if (_model.State == IslandState.Peek || alwaysShow)
        {
            ClaudePill.BeginAnimation(OpacityProperty, null);
            CodexPill.BeginAnimation(OpacityProperty, null);
            ClaudePill.Opacity = _leftTool is not null ? 1 : 0;
            CodexPill.Opacity = _rightTool is not null ? 1 : 0;
        }
        else if (_model.State == IslandState.Compact)
        {
            ClaudePill.BeginAnimation(OpacityProperty, null);
            CodexPill.BeginAnimation(OpacityProperty, null);
            ClaudePill.Opacity = 0;
            CodexPill.Opacity = 0;
        }
    }

    /// First threshold crossing inside a reset window auto-peeks the pills
    /// for ~4s — the ambient nudge from the macOS design.
    private void HandleAlertPulse()
    {
        if (Model.AlertEngine.Shared.Pulse is null) return;
        Model.AlertEngine.Shared.ClearPulse();
        if (_model.State != IslandState.Compact) return;
        SetState(IslandState.Peek);
        var collapse = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
        collapse.Tick += (_, _) =>
        {
            collapse.Stop();
            if (!_hovering && _model.State == IslandState.Peek)
            {
                SetState(IslandState.Compact);
            }
        };
        collapse.Start();
    }
}
