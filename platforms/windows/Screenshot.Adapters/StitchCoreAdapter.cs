namespace Screenshot.Adapters;

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

// 适配层只负责数据封送；匹配与恢复规则均执行 Sources/StitchCore 的原始实现。
public static class SharedStitchCore { public static void Validate() { _ = StitchNative.Version(); } }
public sealed class StitchMatcher
{
    public double Difference(GrayFrame a, GrayFrame b)
    {
        double result = StitchNative.Difference(a.Pixels, a.Pixels.Length, a.Width, a.Height, a.SourceWidth, b.Pixels, b.Pixels.Length, b.Width, b.Height, b.SourceWidth);
        if (result < 0) throw new ArgumentException("共享核心拒绝了无效亮度帧");
        return result;
    }
    public MatchResult Match(GrayFrame a, GrayFrame b)
    {
        int kind = StitchNative.Match(a.Pixels, a.Pixels.Length, a.Width, a.Height, a.SourceWidth, b.Pixels, b.Pixels.Length, b.Width, b.Height, b.SourceWidth, out int rows);
        if (kind < 0 || kind > 6) throw new ArgumentException("共享核心拒绝了无效亮度帧");
        return new((MatchKind)kind, rows);
    }
}
public enum TrackingKind { Seed, Append, Duplicate, Recovering, Paused }
public readonly record struct TrackingResult(TrackingKind Kind, MatchResult Match);
public sealed class StitchTracker : IDisposable
{
    readonly StitchHandle handle = new(); readonly object gate = new();
    public bool HasUnmatchedFrame { get { lock (gate) return StitchNative.Unmatched(handle) switch { 0 => false, 1 => true, _ => throw new ObjectDisposedException(nameof(StitchTracker)) }; } }
    public void Reset(GrayFrame? frame = null)
    {
        lock (gate) {
        if (StitchNative.Reset(handle, frame?.Pixels, frame?.Pixels.Length ?? 0, frame?.Width ?? 0, frame?.Height ?? 0, frame?.SourceWidth ?? 0) != 0) throw new ArgumentException("共享核心拒绝了锚点");
        }
    }
    public TrackingResult Consume(GrayFrame frame, double time)
    {
        lock (gate) {
        int kind = StitchNative.Consume(handle, frame.Pixels, frame.Pixels.Length, frame.Width, frame.Height, frame.SourceWidth, time, out int match, out int rows);
        if (kind < 0 || kind > 4 || match < 0 || match > 6) throw new ArgumentException("共享核心拒绝了亮度帧或时间");
        return new((TrackingKind)kind, new((MatchKind)match, rows));
        }
    }
    public void Dispose() => handle.Dispose();
}
