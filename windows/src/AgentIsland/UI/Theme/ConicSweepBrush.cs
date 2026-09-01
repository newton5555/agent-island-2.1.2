using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace AgentIsland.UI.Theme;

/// The island's rotating edge shimmer (LoadingSweep on macOS) needs an
/// angular gradient, which WPF doesn't have — so the comet is baked into a
/// bitmap once per tint and spun with a RelativeTransform. Gradient stops
/// mirror the SwiftUI ones: clear → clear@0.55 → tint@0.78 → white@0.92 →
/// clear@1.0.
public static class ConicSweepBrush
{
    private const int Size = 320;

    private static readonly Dictionary<Color, BitmapSource> Cache = new();

    public static ImageBrush Make(Color tint, RotateTransform rotate)
    {
        if (!Cache.TryGetValue(tint, out var bitmap))
        {
            bitmap = Render(tint);
            Cache[tint] = bitmap;
        }
        return new ImageBrush(bitmap)
        {
            Stretch = Stretch.Fill,
            RelativeTransform = rotate,
        };
    }

    private static BitmapSource Render(Color tint)
    {
        var stops = new (double T, Color Color)[]
        {
            (0.00, Color.FromArgb(0, tint.R, tint.G, tint.B)),
            (0.55, Color.FromArgb(0, tint.R, tint.G, tint.B)),
            (0.78, tint),
            (0.92, Color.FromArgb(242, 0xFF, 0xFF, 0xFF)),
            (1.00, Color.FromArgb(0, tint.R, tint.G, tint.B)),
        };

        var pixels = new uint[Size * Size];
        const double center = (Size - 1) / 2.0;
        for (var y = 0; y < Size; y++)
        {
            for (var x = 0; x < Size; x++)
            {
                // Screen coords (y down): atan2 grows clockwise from the
                // +x axis — the same convention as AngularGradient.
                var angle = Math.Atan2(y - center, x - center);
                var t = angle / (2 * Math.PI);
                if (t < 0) t += 1;
                pixels[y * Size + x] = Premultiplied(Interpolate(stops, t));
            }
        }

        var bitmap = new WriteableBitmap(Size, Size, 96, 96, PixelFormats.Pbgra32, null);
        bitmap.WritePixels(new Int32Rect(0, 0, Size, Size), pixels, Size * 4, 0);
        bitmap.Freeze();
        return bitmap;
    }

    private static Color Interpolate((double T, Color Color)[] stops, double t)
    {
        for (var i = 1; i < stops.Length; i++)
        {
            if (t > stops[i].T) continue;
            var (t0, c0) = stops[i - 1];
            var (t1, c1) = stops[i];
            var f = t1 <= t0 ? 0 : (t - t0) / (t1 - t0);
            return Color.FromArgb(
                (byte)(c0.A + (c1.A - c0.A) * f),
                (byte)(c0.R + (c1.R - c0.R) * f),
                (byte)(c0.G + (c1.G - c0.G) * f),
                (byte)(c0.B + (c1.B - c0.B) * f));
        }
        return stops[^1].Color;
    }

    private static uint Premultiplied(Color c)
    {
        var a = c.A / 255.0;
        return ((uint)c.A << 24)
            | ((uint)(c.R * a) << 16)
            | ((uint)(c.G * a) << 8)
            | (uint)(c.B * a);
    }
}
