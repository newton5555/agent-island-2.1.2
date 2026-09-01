using System.Globalization;
using System.IO;
using AgentIsland.Core;

namespace AgentIsland.Tests;

/// 1:1 port of the macOS SessionTurnStateTests — the behavioral contract for
/// turn detection, delivery keys, and the desktop bookkeeping grace.
public static class SessionTurnStateTests
{
    public static void RunAll()
    {
        var tests = new (string Name, Action Test)[]
        {
            ("claude user after assistant suppresses stale alarm", TestClaudeUserAfterAssistantIsNotNeedsYou),
            ("claude metadata does not change turn key", TestClaudeMetadataAfterAssistantKeepsAssistantTurnKey),
            ("codex user after complete suppresses stale alarm", TestCodexUserAfterTaskCompleteIsNotNeedsYou),
            ("codex start after complete suppresses stale alarm", TestCodexTaskStartedAfterTaskCompleteIsNotNeedsYou),
            ("codex complete still triggers needs-you", TestCodexTaskCompleteIsNeedsYou),
            ("metadata-touched old claude transcript is idle", TestMetadataTouchedOldClaudeTranscriptIsIdle),
            ("fresh claude end_turn is immediately needs-you", TestFreshClaudeEndTurnIsImmediatelyNeedsYou),
            ("newer claude desktop activity suppresses old end_turn", TestClaudeDesktopNewerActivitySuppressesOldEndTurn),
            ("desktop bookkeeping write does not suppress fresh end_turn", TestDesktopBookkeepingWriteDoesNotSuppressFreshEndTurn),
            ("desktop activity well after end_turn still suppresses", TestDesktopActivityWellAfterEndTurnStillSuppresses),
            ("claude streaming assistant is working", TestClaudeStreamingAssistantIsWorking),
        };

        foreach (var (name, test) in tests)
        {
            test();
            Console.WriteLine($"PASS {name}");
        }
        Console.WriteLine("SessionTurnStateTests GREEN");
    }

    private static void Expect(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    private static void TestClaudeUserAfterAssistantIsNotNeedsYou()
    {
        var expected = Date("2026-07-02T01:15:42.000Z");
        var lines = new[]
        {
            """{"type":"assistant","uuid":"a1","timestamp":"2026-06-25T16:27:50.585Z","message":{"stop_reason":"end_turn"}}""",
            """{"type":"custom-title","sessionId":"s1"}""",
            """{"type":"user","uuid":"u2","timestamp":"2026-07-02T01:15:42.000Z","message":{"role":"user","content":"next turn"}}""",
        };
        var state = SessionTurnState.Claude(lines);
        Expect(!state.IsDone, "new user turn after assistant must suppress stale needs-you");
        Expect(state.Key == "u2", "latest user event should become the turn key");
        Expect(state.ActivityDate == expected, "latest user event should carry its timestamp");
    }

    private static void TestClaudeMetadataAfterAssistantKeepsAssistantTurnKey()
    {
        var expected = Date("2026-06-25T16:27:50.585Z");
        var lines = new[]
        {
            """{"type":"assistant","uuid":"a1","timestamp":"2026-06-25T16:27:50.585Z","message":{"stop_reason":"end_turn"}}""",
            """{"type":"mode","sessionId":"s1"}""",
            """{"type":"custom-title","sessionId":"s1"}""",
        };
        var state = SessionTurnState.Claude(lines);
        Expect(state.IsDone, "metadata after assistant should not hide a completed turn");
        Expect(state.Key == "a1", "metadata writes should not create a new delivery key");
        Expect(state.ActivityDate == expected, "metadata writes should not change semantic activity time");
    }

    private static void TestCodexUserAfterTaskCompleteIsNotNeedsYou()
    {
        var expected = Date("2026-07-02T01:15:42.000Z");
        var lines = new[]
        {
            """{"timestamp":"2026-07-02T01:14:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}""",
            """{"timestamp":"2026-07-02T01:15:42.000Z","type":"event_msg","payload":{"type":"user_message","turn_id":"t2","message":"next"}}""",
        };
        var state = SessionTurnState.Codex(lines);
        Expect(!state.IsDone, "new codex user message after task complete must suppress stale needs-you");
        Expect(state.Key == "t2", "latest codex user event should become the turn key");
        Expect(state.ActivityDate == expected, "latest codex user event should carry its timestamp");
    }

    private static void TestCodexTaskStartedAfterTaskCompleteIsNotNeedsYou()
    {
        var lines = new[]
        {
            """{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}""",
            """{"type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}""",
        };
        var state = SessionTurnState.Codex(lines);
        Expect(!state.IsDone, "new codex task start after completion must suppress stale needs-you");
        Expect(state.Key == "t2", "latest codex task start should become the turn key");
    }

    private static void TestCodexTaskCompleteIsNeedsYou()
    {
        var lines = new[]
        {
            """{"timestamp":"2026-07-02T01:14:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}""",
            """{"timestamp":"2026-07-02T01:15:42.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}""",
        };
        var state = SessionTurnState.Codex(lines);
        Expect(state.IsDone, "codex task complete should be needs-you");
        Expect(state.Key == "t1", "completed codex task should keep its turn id");
    }

    private static void TestMetadataTouchedOldClaudeTranscriptIsIdle()
    {
        var old = Date("2026-06-25T16:27:50.585Z");
        var now = Date("2026-07-02T01:15:42.000Z");
        var tmp = WriteTranscript(new[]
        {
            """{"type":"assistant","uuid":"a1","timestamp":"2026-06-25T16:27:50.585Z","message":{"stop_reason":"end_turn"}}""",
            """{"type":"custom-title","sessionId":"s1"}""",
            """{"type":"mode","sessionId":"s1"}""",
        }, modified: now);
        try
        {
            var state = SessionScanner.SessionState(
                tmp, now, EmptyLastWorking, null, SessionTurnState.Claude);
            Expect(state.Status == ActivityState.Idle,
                "metadata-only file writes must not resurrect old completed Claude turns");
            Expect(state.Modified == old, "semantic modified time should come from the last real turn");
        }
        finally
        {
            File.Delete(tmp);
        }
    }

    private static void TestFreshClaudeEndTurnIsImmediatelyNeedsYou()
    {
        var now = Date("2026-07-02T01:15:42.000Z");
        var tmp = WriteTranscript(new[]
        {
            """{"type":"user","uuid":"u1","timestamp":"2026-07-02T01:15:00.000Z","message":{"role":"user","content":"run"}}""",
            """{"type":"assistant","uuid":"a1","timestamp":"2026-07-02T01:15:41.000Z","message":{"stop_reason":"end_turn"}}""",
        }, modified: now);
        try
        {
            var state = SessionScanner.SessionState(
                tmp, now, EmptyLastWorking, null, SessionTurnState.Claude);
            Expect(state.Status == ActivityState.NeedsYou,
                "fresh Claude end_turn should immediately become needs-you");
        }
        finally
        {
            File.Delete(tmp);
        }
    }

    private static void TestClaudeDesktopNewerActivitySuppressesOldEndTurn()
    {
        var old = Date("2026-06-25T16:27:50.585Z");
        var desktopActivity = Date("2026-07-02T01:15:42.000Z");
        var now = Date("2026-07-02T01:15:44.000Z");
        var tmp = WriteTranscript(new[]
        {
            """{"type":"assistant","uuid":"a1","timestamp":"2026-06-25T16:27:50.585Z","message":{"stop_reason":"end_turn"}}""",
            """{"type":"mode","sessionId":"s1"}""",
        }, modified: now);
        try
        {
            var state = SessionScanner.SessionState(
                tmp, now, EmptyLastWorking, desktopActivity, SessionTurnState.Claude);
            Expect(state.Status == ActivityState.Working,
                "newer Claude Desktop activity should suppress stale end_turn and show running");
            Expect(state.Modified == desktopActivity,
                "newer desktop activity should drive the effective state time");
            Expect(old < state.Modified, "test fixture must keep transcript older than desktop activity");
        }
        finally
        {
            File.Delete(tmp);
        }
    }

    private static void TestDesktopBookkeepingWriteDoesNotSuppressFreshEndTurn()
    {
        // Desktop stamps lastActivityAt ~2-4s after the final assistant event
        // as turn-completion bookkeeping. That write must not eat the alarm.
        var turnDone = Date("2026-07-02T01:15:41.000Z");
        var bookkeeping = turnDone.AddSeconds(3);
        var now = Date("2026-07-02T01:15:48.000Z");
        var tmp = WriteTranscript(new[]
        {
            """{"type":"user","uuid":"u1","timestamp":"2026-07-02T01:15:00.000Z","message":{"role":"user","content":"run"}}""",
            """{"type":"assistant","uuid":"a1","timestamp":"2026-07-02T01:15:41.000Z","message":{"stop_reason":"end_turn"}}""",
        }, modified: now);
        try
        {
            var state = SessionScanner.SessionState(
                tmp, now, EmptyLastWorking, bookkeeping, SessionTurnState.Claude);
            Expect(state.Status == ActivityState.NeedsYou,
                "desktop bookkeeping write seconds after end_turn must not suppress needs-you");
        }
        finally
        {
            File.Delete(tmp);
        }
    }

    private static void TestDesktopActivityWellAfterEndTurnStillSuppresses()
    {
        // Past the bookkeeping grace the user genuinely came back — suppress.
        var turnDone = Date("2026-07-02T01:15:41.000Z");
        var userReturned = turnDone.AddSeconds(120);
        var now = Date("2026-07-02T01:17:45.000Z");
        var tmp = WriteTranscript(new[]
        {
            """{"type":"user","uuid":"u1","timestamp":"2026-07-02T01:15:00.000Z","message":{"role":"user","content":"run"}}""",
            """{"type":"assistant","uuid":"a1","timestamp":"2026-07-02T01:15:41.000Z","message":{"stop_reason":"end_turn"}}""",
        }, modified: now);
        try
        {
            var state = SessionScanner.SessionState(
                tmp, now, EmptyLastWorking, userReturned, SessionTurnState.Claude);
            Expect(state.Status == ActivityState.Working,
                "desktop activity well after end_turn means the user is back — suppress the alarm");
        }
        finally
        {
            File.Delete(tmp);
        }
    }

    private static void TestClaudeStreamingAssistantIsWorking()
    {
        var now = Date("2026-07-02T01:15:44.000Z");
        var tmp = WriteTranscript(new[]
        {
            """{"type":"user","uuid":"u1","timestamp":"2026-07-02T01:15:00.000Z","message":{"role":"user","content":"run"}}""",
            """{"type":"assistant","uuid":"a1","timestamp":"2026-07-02T01:15:42.000Z","message":{"stop_reason":null}}""",
        }, modified: now);
        try
        {
            var state = SessionScanner.SessionState(
                tmp, now, EmptyLastWorking, null, SessionTurnState.Claude);
            Expect(state.Status == ActivityState.Working,
                "Claude assistant output without end_turn should stay running");
        }
        finally
        {
            File.Delete(tmp);
        }
    }

    private static readonly IReadOnlyDictionary<string, DateTimeOffset> EmptyLastWorking =
        new Dictionary<string, DateTimeOffset>();

    private static string WriteTranscript(string[] lines, DateTimeOffset modified)
    {
        var tmp = Path.Combine(
            Path.GetTempPath(),
            $"agent-island-session-state-{Guid.NewGuid()}.jsonl");
        File.WriteAllText(tmp, string.Join("\n", lines));
        File.SetLastWriteTimeUtc(tmp, modified.UtcDateTime);
        return tmp;
    }

    private static DateTimeOffset Date(string raw) =>
        DateTimeOffset.Parse(raw, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);
}
