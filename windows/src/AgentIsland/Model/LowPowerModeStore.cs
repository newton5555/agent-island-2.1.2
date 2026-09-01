using System.ComponentModel;
using System.Runtime.InteropServices;
using AgentIsland.Core;

namespace AgentIsland.Model;

/// Visual mode: Vivid (false, the default) keeps the ambient glow and orbit
/// sweep always on in the chosen glow color; Calm (true) is fully clean —
/// no ambient light at all, only approaching-limit amber/red and the
/// attention pulse remain. The class keeps its historical name because the
/// persisted key does: an explicit choice must survive every rename (old
/// Low Power ON reads as Calm, OFF as Vivid).
public sealed class LowPowerModeStore : INotifyPropertyChanged
{
    private const string Key = "AgentIsland.lowPowerMode";

    public static LowPowerModeStore Shared { get; } = new();

    private bool _enabled;
    private bool _systemLowPower;

    public event PropertyChangedEventHandler? PropertyChanged;

    private LowPowerModeStore()
    {
        // Vivid unless the user explicitly chose Calm: a missing key means
        // "never touched" and lands on the default, so read presence (null)
        // rather than a bool default. (The default flipped to Vivid with the
        // 1.7 design review — the glow IS the product's face.)
        _enabled = Preferences.Get<bool?>(Key) ?? false;
        _systemLowPower = ReadSystemLowPower();
        Microsoft.Win32.SystemEvents.PowerModeChanged += (_, _) =>
        {
            var now = ReadSystemLowPower();
            if (now == _systemLowPower) return;
            _systemLowPower = now;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(EffectiveEnabled)));
        };
    }

    /// The user's picker choice: true = Calm, false = Vivid.
    public bool Enabled
    {
        get => _enabled;
        set
        {
            if (_enabled == value) return;
            _enabled = value;
            Preferences.Set(Key, value);
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Enabled)));
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(EffectiveEnabled)));
        }
    }

    /// What render gating should read: the system battery saver forces Calm
    /// without touching the stored choice, so Vivid returns when it lifts —
    /// the same convention macOS Low Power Mode follows.
    public bool EffectiveEnabled => _enabled || _systemLowPower;

    // Windows battery saver ("energy saver"): SYSTEM_POWER_STATUS's
    // SystemStatusFlag is 1 while it's on.
    [StructLayout(LayoutKind.Sequential)]
    private struct SYSTEM_POWER_STATUS
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll")]
    private static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);

    private static bool ReadSystemLowPower()
    {
        try
        {
            return GetSystemPowerStatus(out var status) && status.SystemStatusFlag == 1;
        }
        catch
        {
            return false;
        }
    }
}
