using AgentIsland.Model;

namespace AgentIsland.Tests;

/// Pins the island's two-slot selection rules. The silhouette geometry is two
/// tabs and two pills, so a third pick must be REFUSED rather than silently
/// evicting an earlier one, and a persisted list must survive an unknown or
/// duplicated entry without ever handing back more than two providers.
public static class ProviderSelectionTests
{
    public static void RunAll()
    {
        var tests = new (string Name, Action Test)[]
        {
            ("sanitize keeps canonical order", TestSanitizeOrders),
            ("sanitize drops unknown and duplicate entries", TestSanitizeCleans),
            ("sanitize caps at two", TestSanitizeCaps),
            ("sanitize of null is empty", TestSanitizeNull),
            ("toggle on adds in canonical order", TestToggleAdds),
            ("toggle off removes", TestToggleRemoves),
            ("third pick is refused, nothing evicted", TestThirdPickRefused),
            ("toggle off at the cap always succeeds", TestToggleOffAtCap),
            ("migration carries the pre-slot pair over", TestMigration),
        };
        foreach (var (name, test) in tests)
        {
            test();
            Console.WriteLine($"PASS {name}");
        }
        Console.WriteLine("ProviderSelectionTests GREEN");
    }

    private static void Expect(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    private static string Spell(IEnumerable<DisplayProvider> providers) =>
        string.Join(",", providers.Select(p => p.RawValue()));

    private static void TestSanitizeOrders()
    {
        var result = ProviderSelection.Sanitize(new[] { "codex", "claude" });
        Expect(Spell(result) == "claude,codex", $"canonical order not restored: {Spell(result)}");
    }

    private static void TestSanitizeCleans()
    {
        var result = ProviderSelection.Sanitize(new[] { "grok", "nope", "grok", "" });
        Expect(Spell(result) == "grok", $"unknown/duplicate entries survived: {Spell(result)}");
    }

    private static void TestSanitizeCaps()
    {
        var result = ProviderSelection.Sanitize(new[] { "cursor", "grok", "gemini", "codex", "claude" });
        Expect(result.Count == ProviderSelection.MaxEnabled,
            $"cap of {ProviderSelection.MaxEnabled} not enforced: {Spell(result)}");
        // The cap keeps the FIRST two in canonical order, so a settings file
        // hand-edited to five providers degrades to the historical pair.
        Expect(Spell(result) == "claude,codex", $"cap kept the wrong two: {Spell(result)}");
    }

    private static void TestSanitizeNull()
    {
        Expect(ProviderSelection.Sanitize(null).Count == 0, "a missing key must decode to an empty selection");
    }

    private static void TestToggleAdds()
    {
        var current = new List<DisplayProvider> { DisplayProvider.Cursor };
        Expect(ProviderSelection.TryToggle(current, DisplayProvider.Claude, out var next),
            "adding a second provider must succeed");
        Expect(Spell(next) == "claude,cursor", $"added out of canonical order: {Spell(next)}");
    }

    private static void TestToggleRemoves()
    {
        var current = new List<DisplayProvider> { DisplayProvider.Claude, DisplayProvider.Grok };
        Expect(ProviderSelection.TryToggle(current, DisplayProvider.Claude, out var next),
            "removing an occupant must succeed");
        Expect(Spell(next) == "grok", $"wrong provider removed: {Spell(next)}");
    }

    private static void TestThirdPickRefused()
    {
        var current = new List<DisplayProvider> { DisplayProvider.Claude, DisplayProvider.Codex };
        Expect(!ProviderSelection.TryToggle(current, DisplayProvider.Grok, out var next),
            "a third pick must be refused");
        Expect(Spell(next) == "claude,codex",
            $"a refused toggle must leave the selection untouched: {Spell(next)}");
    }

    private static void TestToggleOffAtCap()
    {
        // The cap gates ADDITION only — a full island must still be editable.
        var current = new List<DisplayProvider> { DisplayProvider.Antigravity, DisplayProvider.Cursor };
        Expect(ProviderSelection.TryToggle(current, DisplayProvider.Cursor, out var next),
            "turning one off while full must succeed");
        Expect(Spell(next) == "gemini", $"wrong result at the cap: {Spell(next)}");
    }

    private static void TestMigration()
    {
        Expect(Spell(ProviderSelection.Migrated(true, true)) == "claude,codex",
            "both pre-slot toggles on must migrate to both slots");
        Expect(Spell(ProviderSelection.Migrated(false, true)) == "codex",
            "a Codex-only island must migrate unchanged");
        Expect(ProviderSelection.Migrated(false, false).Count == 0,
            "an empty pre-slot island must migrate to an empty selection");
    }
}
