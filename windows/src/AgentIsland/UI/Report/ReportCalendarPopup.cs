using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using AgentIsland.UI.Charts;
using AgentIsland.UI.Theme;

namespace AgentIsland.UI.Report;

/// A real month calendar in a dark popover — click any day and the report
/// window re-anchors to it (macOS: graphical DatePicker; WPF's stock
/// Calendar is a light-theme control that would sit on the dark card like
/// a sticker, so the grid is drawn by hand). Days outside
/// [earliest scanned day, today] are dimmed and inert.
public sealed class ReportCalendarPopup : Popup
{
    private readonly DateTime _minDay;
    private readonly DateTime _maxDay;
    private readonly Action<DateTime> _picked;
    private DateTime _visibleMonth;

    public ReportCalendarPopup(DateTime? earliestDataDay, Action<DateTime> picked)
    {
        _minDay = (earliestDataDay ?? DateTime.Today).Date;
        _maxDay = DateTime.Today;
        _picked = picked;
        _visibleMonth = new DateTime(_maxDay.Year, _maxDay.Month, 1);

        StaysOpen = false;
        AllowsTransparency = true;
        Placement = PlacementMode.Bottom;
        VerticalOffset = 6;
        PopupAnimation = PopupAnimation.Fade;
        Child = Build();
    }

    private FrameworkElement Build()
    {
        var body = new StackPanel { Margin = new Thickness(12) };
        var host = new Border
        {
            Background = IslandColors.Brush(Color.FromRgb(0x15, 0x17, 0x1C)),
            BorderBrush = IslandColors.Brush(IslandColors.White(0.13)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Child = body,
            Width = 252,
        };

        var header = new Grid { Margin = new Thickness(2, 0, 2, 8) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = new TextBlock
        {
            FontFamily = IslandFonts.Ui,
            FontSize = 12,
            FontWeight = FontWeights.Bold,
            Foreground = IslandColors.Brush(IslandColors.White(0.92)),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(title, 1);
        var grid = new UniformGrid { Columns = 7 };

        void Refresh()
        {
            title.Text = Localization.L10n.IsChinese
                ? _visibleMonth.ToString("yyyy年M月")
                : _visibleMonth.ToString("MMMM yyyy", CultureInfo.InvariantCulture);
            FillDays(grid);
        }

        var back = MonthArrow("", () =>
        {
            _visibleMonth = _visibleMonth.AddMonths(-1);
            Refresh();
        });
        Grid.SetColumn(back, 0);
        var forward = MonthArrow("", () =>
        {
            _visibleMonth = _visibleMonth.AddMonths(1);
            Refresh();
        });
        Grid.SetColumn(forward, 2);
        header.Children.Add(back);
        header.Children.Add(title);
        header.Children.Add(forward);
        body.Children.Add(header);

        var zh = Localization.L10n.IsChinese;
        var weekdayLetters = zh
            ? new[] { "日", "一", "二", "三", "四", "五", "六" }
            : new[] { "S", "M", "T", "W", "T", "F", "S" };
        var letterRow = new UniformGrid { Columns = 7, Margin = new Thickness(0, 0, 0, 4) };
        foreach (var letter in weekdayLetters)
        {
            letterRow.Children.Add(new TextBlock
            {
                Text = letter,
                FontFamily = IslandFonts.Ui,
                FontSize = 10,
                FontWeight = FontWeights.SemiBold,
                Foreground = IslandColors.Brush(IslandColors.White(0.4)),
                HorizontalAlignment = HorizontalAlignment.Center,
            });
        }
        body.Children.Add(letterRow);
        body.Children.Add(grid);

        Refresh();
        return host;
    }

    private void FillDays(UniformGrid grid)
    {
        grid.Children.Clear();
        var first = _visibleMonth;
        var lead = (int)first.DayOfWeek;   // Sunday-start, matching the header row
        for (var i = 0; i < lead; i++)
        {
            grid.Children.Add(new Border { Height = 28 });
        }
        var daysInMonth = DateTime.DaysInMonth(first.Year, first.Month);
        for (var day = 1; day <= daysInMonth; day++)
        {
            var date = new DateTime(first.Year, first.Month, day);
            var inRange = date >= _minDay && date <= _maxDay;
            var isToday = date == _maxDay;
            var label = new TextBlock
            {
                Text = day.ToString(CultureInfo.InvariantCulture),
                FontFamily = IslandFonts.Mono,
                FontSize = 11,
                FontWeight = isToday ? FontWeights.Bold : FontWeights.Medium,
                Foreground = IslandColors.Brush(IslandColors.White(inRange ? 0.9 : 0.22)),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
            var cell = new Border
            {
                Height = 28,
                CornerRadius = new CornerRadius(6),
                Background = isToday ? IslandColors.Brush(IslandColors.White(0.12)) : Brushes.Transparent,
                Child = label,
                Cursor = inRange ? Cursors.Hand : Cursors.Arrow,
            };
            if (inRange)
            {
                cell.MouseEnter += (_, _) => cell.Background = IslandColors.Brush(IslandColors.White(0.16));
                cell.MouseLeave += (_, _) => cell.Background = isToday
                    ? IslandColors.Brush(IslandColors.White(0.12))
                    : Brushes.Transparent;
                cell.MouseLeftButtonUp += (_, args) =>
                {
                    args.Handled = true;
                    IsOpen = false;
                    _picked(date);
                };
            }
            grid.Children.Add(cell);
        }
    }

    private static UIElement MonthArrow(string glyph, Action action)
    {
        var face = new Border
        {
            Width = 24,
            Height = 24,
            CornerRadius = new CornerRadius(12),
            Background = IslandColors.Brush(IslandColors.White(0.08)),
            Cursor = Cursors.Hand,
            Child = new TextBlock
            {
                Text = glyph,
                FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
                FontSize = 9,
                Foreground = IslandColors.Brush(IslandColors.White(0.8)),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        };
        face.MouseEnter += (_, _) => face.Background = IslandColors.Brush(IslandColors.White(0.14));
        face.MouseLeave += (_, _) => face.Background = IslandColors.Brush(IslandColors.White(0.08));
        face.MouseLeftButtonUp += (_, args) =>
        {
            args.Handled = true;
            action();
        };
        return face;
    }
}
