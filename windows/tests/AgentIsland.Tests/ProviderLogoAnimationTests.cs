using System;
using System.Windows;
using AgentIsland.Core;
using AgentIsland.UI;

namespace AgentIsland.Tests;

public static class ProviderLogoAnimationTests
{
    private static void Expect(bool condition, string message)
    {
        if (!condition)
        {
            Console.WriteLine($"FAIL: {message}");
            Environment.Exit(1);
        }
    }

    public static void RunAll()
    {
        Console.WriteLine("--- ProviderLogoAnimationTests ---");
        if (System.Threading.Thread.CurrentThread.GetApartmentState() != System.Threading.ApartmentState.STA)
        {
            Exception? error = null;
            var thread = new System.Threading.Thread(() =>
            {
                try
                {
                    RunInternal();
                }
                catch (Exception ex)
                {
                    error = ex;
                }
            });
            thread.SetApartmentState(System.Threading.ApartmentState.STA);
            thread.Start();
            thread.Join();
            if (error is not null) throw error;
            return;
        }
        RunInternal();
    }

    private static void RunInternal()
    {
        if (Application.Current is null) _ = new Application();
        TestAntigravityWorkingDoesNotSpin();
        TestAntigravityWorkingActivatesWave();
        TestAntigravityWorkingRendersPixelChangesBetweenFrames();
        TestClaudeAndCodexContinueSpin();
        TestAntigravityStateTransitionsAndCleanup();
        TestToolSwitchWhileWorking();
        Console.WriteLine("ProviderLogoAnimationTests GREEN");
    }

    private static void TestAntigravityWorkingDoesNotSpin()
    {
        var logo = new ProviderLogo { Tool = TriggerTool.Antigravity };
        logo.SetState(ActivityState.Working);

        Expect(!logo.IsSpinActive, "Antigravity Working state must NOT have spin animation active");
        Expect(Math.Abs(logo.CurrentAngle) < 0.001, "Antigravity Working state angle must remain 0");
        Console.WriteLine("PASS antigravity working does not rotate mark");
    }

    private static void TestAntigravityWorkingActivatesWave()
    {
        var logo = new ProviderLogo { Tool = TriggerTool.Antigravity };
        logo.SetState(ActivityState.Working);

        Expect(logo.IsAntigravityWaveActive, "Antigravity Working state must activate wave animation");
        Expect(logo.AntigravityWaveVisibility == Visibility.Visible, "Antigravity wave host must be visible during working");
        Expect(logo.AntigravityStaticVisibility == Visibility.Collapsed, "Antigravity static face must be collapsed during working");
        Console.WriteLine("PASS antigravity working activates four-color liquid wave");
    }

    private static void TestAntigravityWorkingRendersPixelChangesBetweenFrames()
    {
        var logo = new ProviderLogo { Tool = TriggerTool.Antigravity };
        logo.SetState(ActivityState.Working);

        var window = new Window
        {
            Width = 100,
            Height = 100,
            Content = logo,
            ShowActivated = false,
        };
        window.Show();

        System.Windows.Threading.Dispatcher.CurrentDispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.Render);

        var rtb1 = new System.Windows.Media.Imaging.RenderTargetBitmap(100, 100, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
        rtb1.Render(logo);
        var pix1 = new byte[100 * 100 * 4];
        rtb1.CopyPixels(pix1, 400, 0);

        var start = DateTime.UtcNow;
        while ((DateTime.UtcNow - start).TotalMilliseconds < 350)
        {
            System.Windows.Threading.Dispatcher.CurrentDispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.Render);
            System.Threading.Thread.Sleep(20);
        }

        var rtb2 = new System.Windows.Media.Imaging.RenderTargetBitmap(100, 100, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
        rtb2.Render(logo);
        var pix2 = new byte[100 * 100 * 4];
        rtb2.CopyPixels(pix2, 400, 0);

        window.Close();

        var changedPixels = 0;
        var maxDelta = 0;
        for (var i = 0; i < pix1.Length / 4; i++)
        {
            var idx = i * 4;
            var bDiff = Math.Abs((int)pix1[idx] - (int)pix2[idx]);
            var gDiff = Math.Abs((int)pix1[idx + 1] - (int)pix2[idx + 1]);
            var rDiff = Math.Abs((int)pix1[idx + 2] - (int)pix2[idx + 2]);
            var delta = bDiff + gDiff + rDiff;
            if (delta > 15)
            {
                changedPixels++;
                if (delta > maxDelta) maxDelta = delta;
            }
        }

        Expect(changedPixels > 50, $"Working animation must produce visible pixel changes across frames (got {changedPixels} changed pixels)");
        Expect(maxDelta > 100, $"Color delta between frames must be perceptible (got max delta {maxDelta})");
        Console.WriteLine($"PASS antigravity working renders real pixel changes across frames ({changedPixels} changed pixels, max delta {maxDelta})");
    }

    private static void TestClaudeAndCodexContinueSpin()
    {
        var claude = new ProviderLogo { Tool = TriggerTool.Claude };
        claude.SetState(ActivityState.Working);
        Expect(claude.IsSpinActive, "Claude Working state must have spin animation active");
        Expect(!claude.IsAntigravityWaveActive, "Claude must not have Antigravity wave active");

        var codex = new ProviderLogo { Tool = TriggerTool.Codex };
        codex.SetState(ActivityState.Working);
        Expect(codex.IsSpinActive, "Codex Working state must have spin animation active");
        Expect(!codex.IsAntigravityWaveActive, "Codex must not have Antigravity wave active");
        Console.WriteLine("PASS claude and codex continue 360-degree spin");
    }

    private static void TestAntigravityStateTransitionsAndCleanup()
    {
        var logo = new ProviderLogo { Tool = TriggerTool.Antigravity };
        logo.SetState(ActivityState.Working);
        Expect(logo.IsAntigravityWaveActive, "Precondition: wave active in Working");

        // Transition to Idle
        logo.SetState(ActivityState.Idle);
        Expect(!logo.IsAntigravityWaveActive, "Idle state must deactivate wave animation");
        Expect(logo.AntigravityWaveVisibility == Visibility.Collapsed, "Idle state must collapse wave host");
        Expect(logo.AntigravityStaticVisibility == Visibility.Visible, "Idle state must show static mark");
        Expect(!logo.IsSpinActive, "Idle state must not spin");

        // Transition to NeedsYou (YourTurn / attention)
        logo.SetState(ActivityState.Working);
        logo.SetState(ActivityState.NeedsYou);
        Expect(!logo.IsAntigravityWaveActive, "NeedsYou state must deactivate wave animation");
        Expect(logo.AntigravityWaveVisibility == Visibility.Collapsed, "NeedsYou state must collapse wave host");
        Expect(logo.AntigravityStaticVisibility == Visibility.Visible, "NeedsYou state must show static mark");

        // Transition to Stalled / RateLimited
        logo.SetState(ActivityState.Working);
        logo.SetState(ActivityState.Stalled);
        Expect(!logo.IsAntigravityWaveActive, "Stalled state must deactivate wave animation");
        Expect(logo.AntigravityWaveVisibility == Visibility.Collapsed, "Stalled state must collapse wave host");
        Expect(logo.AntigravityStaticVisibility == Visibility.Visible, "Stalled state must show static mark");

        // Transition to AuthRequired
        logo.SetState(ActivityState.Working);
        logo.SetState(ActivityState.AuthRequired);
        Expect(!logo.IsAntigravityWaveActive, "AuthRequired state must deactivate wave animation");
        Expect(logo.AntigravityWaveVisibility == Visibility.Collapsed, "AuthRequired state must collapse wave host");
        Expect(logo.AntigravityStaticVisibility == Visibility.Visible, "AuthRequired state must show static mark");

        Console.WriteLine("PASS antigravity state transitions cleanly stop wave without leaks");
    }

    private static void TestToolSwitchWhileWorking()
    {
        var logo = new ProviderLogo { Tool = TriggerTool.Claude };
        logo.SetState(ActivityState.Working);
        Expect(logo.IsSpinActive, "Claude starts with spin");

        // Switch tool to Antigravity while in Working state
        logo.Tool = TriggerTool.Antigravity;
        Expect(!logo.IsSpinActive, "Switching to Antigravity while working stops spin");
        Expect(logo.IsAntigravityWaveActive, "Switching to Antigravity while working starts wave");

        // Switch tool back to Claude while in Working state
        logo.Tool = TriggerTool.Claude;
        Expect(!logo.IsAntigravityWaveActive, "Switching to Claude stops Antigravity wave");
        Expect(logo.IsSpinActive, "Switching to Claude resumes spin");

        logo.SetState(ActivityState.Idle);
        Expect(!logo.IsSpinActive && !logo.IsAntigravityWaveActive, "Idle stops all animations");
        Console.WriteLine("PASS tool switching while working cross-animates properly");
    }
}