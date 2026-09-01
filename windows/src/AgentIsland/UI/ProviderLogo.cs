using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using AgentIsland.Core;
using AgentIsland.Model;
using AgentIsland.UI.Theme;

namespace AgentIsland.UI;

/// One provider mark in the island bar: renders the brand geometry and
/// animates it per activity state — spin + breath while working, red pulse
/// for attention states, still otherwise. Mirrors LogoOverlay/
/// StatePreviewLogo on macOS.
public sealed class ProviderLogo : Grid
{
    private readonly System.Windows.Shapes.Path _path;
    private readonly RotateTransform _rotate = new();
    private readonly ScaleTransform _scale = new();
    // The glow is NOT a DropShadowEffect: a bitmap effect on a spinning,
    // breathing mark re-runs its gaussian every frame on the CPU — two
    // working logos held ~40% of a core. A radial-gradient blob behind the
    // mark reads the same (the eye sees a soft halo either way), and its
    // breath animates UIElement.Opacity — a composition-time parameter
    // that never re-rasterizes anything.
    private readonly System.Windows.Shapes.Ellipse _glowBlob;
    // Mutable (unfrozen) fill so the state-change tint can crossfade — a
    // frozen IslandColors.Brush can't be animated.
    private readonly SolidColorBrush _fill = new(IslandColors.Claude);
    private TriggerTool _tool = TriggerTool.Claude;
    private ActivityState _state = ActivityState.Idle;
    private bool _tintSeeded;

    public const double MarkSize = 20;
    // Small enough to live inside the 36px bar strip: an overhanging blob
    // gets clipped by the strip into a hard-edged square of tint.
    private const double BlobSize = 34;

    public ProviderLogo()
    {
        _glowBlob = new System.Windows.Shapes.Ellipse
        {
            Width = BlobSize,
            Height = BlobSize,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Opacity = 0,
            IsHitTestVisible = false,
        };
        _path = new System.Windows.Shapes.Path
        {
            Fill = _fill,
            Width = MarkSize,
            Height = MarkSize,
            Stretch = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        // Spin/breath ride the HOST, not the mark element — so a provider
        // whose mark is a masked bitmap (no extracted vector) animates
        // exactly like the vector ones.
        var transforms = new TransformGroup();
        transforms.Children.Add(_scale);
        transforms.Children.Add(_rotate);
        _markHost = new Grid
        {
            Width = MarkSize,
            Height = MarkSize,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            RenderTransformOrigin = new Point(0.5, 0.5),
            RenderTransform = transforms,
        };
        Children.Add(_glowBlob);
        Children.Add(_markHost);
        ApplyTool();
    }

    private readonly Grid _markHost;

    private void RetintBlob(Color color)
    {
        // Fast falloff: by half the radius the halo is already faint, so
        // the blob reads as light around the mark, not a disc of paint.
        _glowBlob.Fill = new RadialGradientBrush
        {
            GradientStops = new GradientStopCollection
            {
                new GradientStop(IslandColors.Alpha(color, 0.75), 0.0),
                new GradientStop(IslandColors.Alpha(color, 0.22), 0.5),
                new GradientStop(IslandColors.Alpha(color, 0.0), 0.95),
            },
        };
    }

    public TriggerTool Tool
    {
        get => _tool;
        set
        {
            _tool = value;
            // A tool identity change is instant, not a state crossfade — the
            // ctor seeds with the default Claude, so reset the seed here or
            // a Codex logo would fade terracotta→blue on every launch.
            _tintSeeded = false;
            ApplyTool();
        }
    }

    private void ApplyTool()
    {
        // Every provider renders its REAL mark (macOS LogoOverlay →
        // ProviderMark): extracted vectors where they exist, the rasterized
        // brand masks elsewhere, Antigravity in its own colours.
        _markHost.Children.Clear();
        var provider = _tool.ToDisplayProvider();
        if (BrandGeometry.PathData(provider) is { } data)
        {
            _path.Data = Geometry.Parse("F1 " + data);
            _markHost.Children.Add(_path);
        }
        else
        {
            _markHost.Children.Add(ProviderMarks.IslandMark(provider, MarkSize, _fill));
        }
        ApplyTint();
    }

    /// The attention tint is a brighter alarm red than the chart alertRed —
    /// Color(0.96, 0.34, 0.29) in LogoOverlay.
    private static readonly Color AlarmRed = Color.FromRgb(0xF5, 0x57, 0x4A);

    private void ApplyTint()
    {
        var color = _state.IsAttentionState() ? AlarmRed : IslandColors.For(_tool);
        // First paint is instant; later state changes crossfade over 0.3s,
        // the macOS LogoOverlay easeInOut(0.3) tint transition (e.g.
        // working blue → attention red). The blob just swaps its gradient —
        // during the crossfade the eye tracks the mark, not the halo.
        RetintBlob(color);
        if (!_tintSeeded)
        {
            _tintSeeded = true;
            _fill.Color = color;
            return;
        }
        var fade = new Duration(TimeSpan.FromSeconds(0.3));
        var ease = new SineEase { EasingMode = EasingMode.EaseInOut };
        _fill.BeginAnimation(SolidColorBrush.ColorProperty,
            new ColorAnimation(color, fade) { EasingFunction = ease });
    }

    public void SetState(ActivityState state)
    {
        if (_state == state) return;
        var wasWorking = _state == ActivityState.Working;
        _state = state;
        ApplyTint();
        StopAnimations(unwindSpin: wasWorking);
        switch (state)
        {
            case ActivityState.Working:
                StartSpin();
                StartBreath(from: 1.0, to: 1.05, halfCycle: IslandAnimations.WorkingBreathDuration.TimeSpan);
                // macOS radii are gaussian sigmas; WPF BlurRadius is the
                // kernel extent (~3x), else the glow reads as an outline.
                StartGlow(radiusFrom: 6, radiusTo: 15, halfCycle: IslandAnimations.WorkingBreathDuration.TimeSpan);
                break;
            case ActivityState.Stalled:
            case ActivityState.RateLimited:
                StartBreath(from: 1.0, to: 1.16, halfCycle: IslandAnimations.AttentionPulseDuration.TimeSpan);
                StartGlow(radiusFrom: 12, radiusTo: 33, halfCycle: IslandAnimations.AttentionPulseDuration.TimeSpan);
                break;
            case ActivityState.AuthRequired:
                // Static red, no pulse: a login can stay pending for hours,
                // and an endless blink reads as a crash (macOS
                // pulsesAttention excludes authRequired).
                _glowBlob.Opacity = 0.25;
                break;
            case ActivityState.Idle:
            case ActivityState.NeedsYou:
            default:
                break;
        }
    }

    /// Every frame of any animation recomposites the whole layered window
    /// in software — the per-frame bill is the window, not the animated
    /// element. 24fps is where a 3.8s spin still reads as continuous motion
    /// while the composition bill drops to 40% of the 60fps default.
    private const int GlowFps = 24;

    private void StartSpin()
    {
        // The marks counter-rotate: Claude clockwise, Codex the other way.
        var to = _tool is TriggerTool.Claude or TriggerTool.Antigravity or TriggerTool.Cursor ? 360d : -360d;
        var spin = new DoubleAnimation(0, to, IslandAnimations.SpinDuration)
        {
            RepeatBehavior = RepeatBehavior.Forever,
        };
        Timeline.SetDesiredFrameRate(spin, GlowFps);
        _rotate.BeginAnimation(RotateTransform.AngleProperty, spin);
    }

    private void StartBreath(double from, double to, TimeSpan halfCycle)
    {
        var breath = new DoubleAnimation(from, to, new Duration(halfCycle))
        {
            AutoReverse = true,
            RepeatBehavior = RepeatBehavior.Forever,
            EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
        };
        Timeline.SetDesiredFrameRate(breath, GlowFps);
        _scale.BeginAnimation(ScaleTransform.ScaleXProperty, breath);
        _scale.BeginAnimation(ScaleTransform.ScaleYProperty, breath);
    }

    private void StartGlow(double radiusFrom, double radiusTo, TimeSpan halfCycle)
    {
        // macOS breathes radius and strength together; here only the blob's
        // element opacity breathes — the halo brightens and dims, which is
        // what the eye actually reads, and the animation never leaves the
        // composition stage. (radiusFrom/To kept for call-site parity.)
        _ = radiusFrom; _ = radiusTo;
        var strength = new DoubleAnimation(0.2, 0.8, new Duration(halfCycle))
        {
            AutoReverse = true,
            RepeatBehavior = RepeatBehavior.Forever,
            EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
        };
        Timeline.SetDesiredFrameRate(strength, GlowFps);
        _glowBlob.BeginAnimation(OpacityProperty, strength);
    }

    private void StopAnimations(bool unwindSpin = false)
    {
        // Capture the live angle before detaching the animation so a
        // finished spin can settle back to upright instead of snapping.
        var angle = _rotate.Angle % 360;
        if (angle > 180) angle -= 360;
        if (angle < -180) angle += 360;
        _rotate.BeginAnimation(RotateTransform.AngleProperty, null);
        _scale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
        _scale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
        _glowBlob.BeginAnimation(OpacityProperty, null);
        // Back to the no-glow baseline — without this an auth→idle flip
        // kept a faint leftover halo.
        _glowBlob.Opacity = 0;
        _rotate.Angle = 0;
        if (unwindSpin && Math.Abs(angle) > 0.5 && _state != ActivityState.Working)
        {
            var settle = new DoubleAnimation(angle, 0, new Duration(TimeSpan.FromSeconds(0.35)))
            {
                EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut },
                FillBehavior = FillBehavior.Stop,
            };
            _rotate.BeginAnimation(RotateTransform.AngleProperty, settle);
        }
        _scale.ScaleX = 1;
        _scale.ScaleY = 1;
    }
}
