using System.Windows.Media;
using AgentIsland.Core;

namespace AgentIsland.Model;

/// One authority for "what does this provider look like": display name,
/// accent, CLI executable. It replaces the scattered
/// `provider == Claude ? A : B` ternaries that each silently rendered Grok
/// and Gemini as Codex — wrong name in the alarm, wrong accent on the chip.
/// Every consumer reads the same switch here, so a sixth provider is one
/// case away.
public static class ProviderIdentity
{
    /// Claude terracotta.
    public static readonly Color ClaudeAccent = Color.FromRgb(0xCC, 0x78, 0x5C);

    /// Codex sky blue.
    public static readonly Color CodexAccent = Color.FromRgb(0x5A, 0xA8, 0xF0);

    /// Google blue — Antigravity's mark is a sweep through Google's four
    /// hues, so the flat stand-in is their blue rather than the washed-out
    /// periwinkle the Gemini era used (owner review, 2026-08-09).
    public static readonly Color AntigravityAccent = Color.FromRgb(0x42, 0x85, 0xF4);

    /// Grok cool steel — near-white, so it needs a dark backing to read.
    public static readonly Color GrokAccent = Color.FromRgb(0xD8, 0xDE, 0xE4);

    /// Cursor bone.
    public static readonly Color CursorAccent = Color.FromRgb(0xF5, 0xF3, 0xEE);

    /// The short product name: island slots, Settings rows, chips.
    public static string DisplayName(DisplayProvider provider) => provider switch
    {
        DisplayProvider.Claude => "Claude",
        DisplayProvider.Codex => "Codex",
        DisplayProvider.Antigravity => "Antigravity",
        DisplayProvider.Grok => "Grok",
        DisplayProvider.Cursor => "Cursor",
        _ => "Claude",
    };

    public static string DisplayName(TriggerTool tool) => DisplayName(tool.ToDisplayProvider());

    /// The alarm/status layer spells Claude out in full, matching macOS — an
    /// alarm that just says "Claude" reads as the desktop app, not the CLI
    /// session that finished a turn.
    public static string AlarmName(DisplayProvider provider) =>
        provider == DisplayProvider.Claude ? "Claude Code" : DisplayName(provider);

    public static string AlarmName(TriggerTool tool) => AlarmName(tool.ToDisplayProvider());

    public static Color Accent(DisplayProvider provider) => provider switch
    {
        DisplayProvider.Claude => ClaudeAccent,
        DisplayProvider.Codex => CodexAccent,
        DisplayProvider.Antigravity => AntigravityAccent,
        DisplayProvider.Grok => GrokAccent,
        DisplayProvider.Cursor => CursorAccent,
        _ => ClaudeAccent,
    };

    /// The brand RAMP (macOS brandStops): Antigravity carries Google's four
    /// hues; everyone else is their accent as a flat two-stop ramp so every
    /// consumer can treat "the brand color" as a gradient.
    public static IReadOnlyList<Color> BrandStops(DisplayProvider provider) =>
        provider == DisplayProvider.Antigravity ? GoogleRamp : new[] { Accent(provider), Accent(provider) };

    private static readonly Color[] GoogleRamp =
    {
        Color.FromRgb(66, 133, 244),
        Color.FromRgb(52, 168, 83),
        Color.FromRgb(251, 188, 5),
        Color.FromRgb(234, 67, 53),
    };

    /// macOS brandGradient: the ramp as a WPF brush at one opacity.
    public static LinearGradientBrush BrandGradient(
        DisplayProvider provider, double opacity,
        System.Windows.Point start, System.Windows.Point end)
    {
        var stops = BrandStops(provider);
        var collection = new GradientStopCollection();
        for (var i = 0; i < stops.Count; i++)
        {
            collection.Add(new GradientStop(
                Color.FromArgb((byte)Math.Round(opacity * 255), stops[i].R, stops[i].G, stops[i].B),
                stops.Count == 1 ? 0 : (double)i / (stops.Count - 1)));
        }
        var brush = new LinearGradientBrush(collection, start, end);
        brush.Freeze();
        return brush;
    }

    public static Color Accent(TriggerTool tool) => Accent(tool.ToDisplayProvider());

    /// Frozen and shared, so a repaint never allocates a brush and any
    /// thread may read one.
    public static SolidColorBrush AccentBrush(DisplayProvider provider) => provider switch
    {
        DisplayProvider.Claude => AccentBrushes.Claude,
        DisplayProvider.Codex => AccentBrushes.Codex,
        DisplayProvider.Antigravity => AccentBrushes.Antigravity,
        DisplayProvider.Grok => AccentBrushes.Grok,
        DisplayProvider.Cursor => AccentBrushes.Cursor,
        _ => AccentBrushes.Claude,
    };

    public static SolidColorBrush AccentBrush(TriggerTool tool) => AccentBrush(tool.ToDisplayProvider());

    /// CLI executable name; null where the product is app-only and there is
    /// nothing on PATH to find.
    public static string? CliName(DisplayProvider provider) => provider switch
    {
        DisplayProvider.Claude => "claude",
        DisplayProvider.Codex => "codex",
        DisplayProvider.Antigravity => "agy",
        DisplayProvider.Grok => "grok",
        DisplayProvider.Cursor => null,
        _ => null,
    };

    public static string? CliName(TriggerTool tool) => CliName(tool.ToDisplayProvider());

    private static SolidColorBrush Frozen(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    /// Nested so that asking for a name or a raw Color never constructs a
    /// Freezable — a SolidColorBrush built on a worker thread spins up a
    /// Dispatcher for that thread, and name lookups run everywhere.
    private static class AccentBrushes
    {
        internal static readonly SolidColorBrush Claude = Frozen(ClaudeAccent);
        internal static readonly SolidColorBrush Codex = Frozen(CodexAccent);
        internal static readonly SolidColorBrush Antigravity = Frozen(AntigravityAccent);
        internal static readonly SolidColorBrush Grok = Frozen(GrokAccent);
        internal static readonly SolidColorBrush Cursor = Frozen(CursorAccent);
    }
}
