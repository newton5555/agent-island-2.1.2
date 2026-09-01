using AgentIsland.Core;
using AgentIsland.Model;
using AgentIsland.UI;

namespace AgentIsland.Tests;

/// Pins the solo-split geometry (macOS 9ee4219): a lone visible provider
/// never narrows the bar — the full symmetric width stays (logo takes one
/// flank, the usage number the other), in both placements. SoloProvider
/// reports which side is alone; both-visible and both-hidden report null.
public static class SoloCenterLayoutTests
{
    public static void RunAll()
    {
        var visibility = ProviderVisibilityStore.Shared;
        var position = IslandPositionStore.Shared;
        var alwaysShow = AlwaysShowUsageStore.Shared;
        var model = IslandModel.Shared;

        var savedClaude = visibility.ClaudeVisible;
        var savedCodex = visibility.CodexVisible;
        var savedPlacement = position.Placement;
        var savedAlwaysShow = alwaysShow.Enabled;
        try
        {
            position.Placement = IslandPlacement.TopBar;
            alwaysShow.Enabled = false;
            visibility.ClaudeVisible = true;
            visibility.CodexVisible = true;

            Expect(model.SoloProvider is null, "two visible providers are not solo");
            Expect(model.Size.Width == 276, $"symmetric top bar must be 200+38*2, got {model.Size.Width}");

            visibility.CodexVisible = false;
            Expect(model.SoloProvider == TriggerTool.Claude, "Claude alone reports solo Claude");
            Expect(model.Size.Width == 276,
                $"solo keeps the FULL symmetric width (split, not folded), got {model.Size.Width}");
            Console.WriteLine("PASS solo keeps the symmetric bar width (split layout)");

            visibility.CodexVisible = true;
            visibility.ClaudeVisible = false;
            Expect(model.SoloProvider == TriggerTool.Codex && model.Size.Width == 276,
                "solo is side-agnostic and width-stable");
            Console.WriteLine("PASS solo is side-agnostic");

            visibility.CodexVisible = false;
            Expect(model.SoloProvider is null, "both hidden is not solo");
            Expect(model.Size.Width == 276, $"both-hidden keeps symmetric width, got {model.Size.Width}");
            Console.WriteLine("PASS both-hidden stays symmetric");

            visibility.CodexVisible = true;
            position.Placement = IslandPlacement.Floating;
            Expect(model.Size.Width == 140, $"floating solo keeps 64+38*2, got {model.Size.Width}");
            visibility.ClaudeVisible = true;
            Expect(model.Size.Width == 140, $"symmetric floating must be 64+38*2, got {model.Size.Width}");
            Console.WriteLine("PASS floating placement widths hold, solo and duo");
        }
        finally
        {
            visibility.ClaudeVisible = savedClaude;
            visibility.CodexVisible = savedCodex;
            position.Placement = savedPlacement;
            alwaysShow.Enabled = savedAlwaysShow;
        }
        Console.WriteLine("SoloCenterLayoutTests GREEN");
    }

    private static void Expect(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }
}
