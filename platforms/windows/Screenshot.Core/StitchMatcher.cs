namespace Screenshot.Core;

public sealed record GrayFrame
{
    public int Width { get; }
    public int Height { get; }
    public int SourceWidth { get; }
    public byte[] Pixels { get; }
    public GrayFrame(int width, int height, byte[] pixels, int? sourceWidth = null)
    {
        if (width <= 0 || height <= 0 || pixels.Length != checked(width * height)) throw new ArgumentException("无效亮度帧");
        Width = width; Height = height; SourceWidth = sourceWidth ?? width; Pixels = pixels;
    }
}
public enum MatchKind { Duplicate, Append, Reverse, IncompatibleSize, InsufficientOverlap, Ambiguous, ChangedContent }
public readonly record struct MatchResult(MatchKind Kind, int Rows = 0);

// 与 Swift StitchCore 相同的垂直平移语义；共享固定测试向量是跨平台兼容性契约。
public sealed class StitchMatcher
{
    public double Difference(GrayFrame a, GrayFrame b) => Compatible(a, b) ? Error(a, b, 0, Enumerable.Range(0, a.Height)) : 255;
    static bool Compatible(GrayFrame a, GrayFrame b) => a.Width == b.Width && a.Height == b.Height && a.SourceWidth == b.SourceWidth;
    public MatchResult Match(GrayFrame a, GrayFrame b)
    {
        if (!Compatible(a, b)) return new(MatchKind.IncompatibleSize);
        if (a.Height < 80 || a.Width < 16) return new(MatchKind.InsufficientOverlap);
        if (Difference(a, b) < .6 && a.Pixels.Zip(b.Pixels).Count(p => Math.Abs(p.First - p.Second) > 3) <= Math.Max(1, a.Pixels.Length / 10000)) return new(MatchKind.Duplicate);
        int limit = (int)(a.Height * .78);
        var rows = InformativeRows(a);
        var coarse = Enumerable.Range(-limit, 2 * limit + 1).Where(d => d != 0).Select(d => (Shift: d, Score: Error(a, b, d, rows))).OrderBy(p => p.Score).ThenBy(p => p.Shift).ToArray();
        if (coarse[0].Score >= 12) return new(MatchKind.InsufficientOverlap);
        var candidates = new Dictionary<int, double>();
        foreach (var seed in coarse.Take(24))
            for (int d = Math.Max(-limit, seed.Shift - 1); d <= Math.Min(limit, seed.Shift + 1); d++)
                if (d != 0 && !candidates.ContainsKey(d)) candidates[d] = Error(a, b, d, Enumerable.Range(Math.Max(d, 0), a.Height - Math.Abs(d)));
        var ranked = candidates.OrderBy(p => p.Value).ThenBy(p => p.Key).ToArray();
        var best = ranked[0];
        if (best.Value >= 3) return new(MatchKind.InsufficientOverlap);
        if (ranked.Any(p => Math.Abs(p.Key - best.Key) > 4 && p.Value <= best.Value * 1.15 + .0001)) return new(MatchKind.Ambiguous);
        int shift = best.Key, overlap = a.Height - Math.Abs(shift), aStart = Math.Max(shift, 0), bStart = Math.Max(-shift, 0);
        for (int band = 0; band < 6; band++)
        {
            double sum = 0, signal = 0, excess = 0; int count = 0;
            for (int y = overlap * band / 6; y < overlap * (band + 1) / 6; y++) for (int x = 0; x < a.Width; x++)
            {
                int ai = (y + aStart) * a.Width + x, bi = (y + bStart) * b.Width + x;
                int delta = Math.Abs(a.Pixels[ai] - b.Pixels[bi]); sum += delta; excess += Math.Max(0, delta - 2);
                if (x > 0) signal += Math.Max(Math.Abs(a.Pixels[ai] - a.Pixels[ai - 1]), Math.Abs(b.Pixels[bi] - b.Pixels[bi - 1]));
                count++;
            }
            if (count > 0 && (sum / count > 5 || excess > signal * .3)) return new(MatchKind.ChangedContent);
        }
        return shift > 0 ? new(MatchKind.Append, shift) : new(MatchKind.Reverse);
    }
    static int[] InformativeRows(GrayFrame f)
    {
        List<int> result = []; int size = Math.Max(1, f.Height / 32);
        for (int start = 0; start < f.Height; start += size)
        {
            var ranked = Enumerable.Range(start, Math.Min(size, f.Height - start)).Select(y =>
            {
                int energy = 0; for (int x = 1; x < f.Width; x++) energy += Math.Abs(f.Pixels[y * f.Width + x] - f.Pixels[y * f.Width + x - 1]);
                return (Y: y, Energy: energy);
            });
            result.AddRange(ranked.OrderByDescending(p => p.Energy).ThenBy(p => p.Y).Take(2).Select(p => p.Y));
        }
        return result.ToArray();
    }
    static double Error(GrayFrame a, GrayFrame b, int shift, IEnumerable<int> rows)
    {
        long total = 0, count = 0;
        foreach (int y in rows) if (y - shift >= 0 && y - shift < b.Height) for (int x = 0; x < a.Width; x++)
        { total += Math.Abs(a.Pixels[y * a.Width + x] - b.Pixels[(y - shift) * b.Width + x]); count++; }
        return count > 0 ? (double)total / count : 255;
    }
}
public enum TrackingKind { Seed, Append, Duplicate, Recovering, Paused }
public readonly record struct TrackingResult(TrackingKind Kind, MatchResult Match);
public sealed class StitchTracker
{
    GrayFrame? anchor; double? failureSince; MatchResult lastFailure;
    readonly StitchMatcher matcher = new();
    public bool HasUnmatchedFrame { get; private set; }
    public void Reset(GrayFrame? frame = null) { anchor = frame; failureSince = null; HasUnmatchedFrame = false; }
    public TrackingResult Consume(GrayFrame frame, double time)
    {
        if (anchor is null) { anchor = frame; return new(TrackingKind.Seed, default); }
        var result = matcher.Match(anchor, frame);
        if (result.Kind is MatchKind.Append or MatchKind.Duplicate)
        {
            if (result.Kind == MatchKind.Append) anchor = frame;
            failureSince = null; HasUnmatchedFrame = false;
            return new(result.Kind == MatchKind.Append ? TrackingKind.Append : TrackingKind.Duplicate, result);
        }
        HasUnmatchedFrame = true; lastFailure = result; failureSince ??= time;
        return new(result.Kind == MatchKind.IncompatibleSize || time - failureSince >= .8 ? TrackingKind.Paused : TrackingKind.Recovering, result);
    }
}
