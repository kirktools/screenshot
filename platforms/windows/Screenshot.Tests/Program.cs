using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Screenshot.Core;
int count = 0;
void Check(bool condition, string name) { if (!condition) throw new Exception("FAIL: " + name); Console.WriteLine("PASS: " + name); count++; }
void Reject(Action action, string name) { try { action(); } catch (InvalidDataException) { Check(true, name); return; } throw new Exception("Accepted invalid input: " + name); }
GrayFrame Frame(JsonElement e) => new(e.GetProperty("width").GetInt32(), e.GetProperty("height").GetInt32(), Convert.FromBase64String(e.GetProperty("pixels").GetString()!), e.GetProperty("sourceWidth").GetInt32());
using var vectors = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "stitch-vectors.json")));
var matcher = new StitchMatcher();
foreach (var vector in vectors.RootElement.EnumerateArray())
{
    var result = matcher.Match(Frame(vector.GetProperty("previous")), Frame(vector.GetProperty("next")));
    string actual = result.Kind == MatchKind.Append ? $"append:{result.Rows}" : char.ToLowerInvariant(result.Kind.ToString()[0]) + result.Kind.ToString()[1..];
    Check(actual == vector.GetProperty("expected").GetString(), vector.GetProperty("name").GetString()!);
}
var first = vectors.RootElement[0]; var a = Frame(first.GetProperty("previous")); var b = Frame(first.GetProperty("next"));
var tracker = new StitchTracker(); Check(tracker.Consume(a, 0).Kind == TrackingKind.Seed, "tracker seed");
Check(tracker.Consume(b, .1).Kind == TrackingKind.Append, "tracker append");
Check(tracker.Consume(a, .2).Kind == TrackingKind.Recovering, "reverse preserves anchor");
Check(tracker.Consume(a, 1.1).Kind == TrackingKind.Paused, "sustained reverse pauses");
Check(tracker.Consume(b, 1.2).Kind == TrackingKind.Duplicate && !tracker.HasUnmatchedFrame, "return to retained anchor recovers");
tracker.Reset(a); Check(tracker.Consume(b, 1.3).Kind == TrackingKind.Append, "undo/reset retains correct anchor");
string name = "Screenshot-9.0.0-Windows-x64.zip";
byte[] Release(string archiveUrl, bool pre = false) => JsonSerializer.SerializeToUtf8Bytes(new { tag_name = "v9.0.0", draft = false, prerelease = pre, assets = new[] { new { name, size = 100, browser_download_url = archiveUrl }, new { name = "SHA256SUMS-Windows-x64.txt", size = 100, browser_download_url = "https://github.com/kirktools/screenshot/releases/download/v9.0.0/SHA256SUMS-Windows-x64.txt" } } });
Check(ReleaseUpdates.Parse(Release("https://github.com/kirktools/screenshot/releases/download/v9.0.0/" + name), new(1, 0, 0), "x64")!.Version == new Version(9, 0, 0), "official platform-specific update offer");
Check(ReleaseUpdates.Parse(Release("ignored", true), new(1, 0, 0), "x64") == null, "prerelease ignored");
Reject(() => ReleaseUpdates.Parse(Release("https://example.invalid/evil.zip"), new(1, 0, 0), "x64"), "foreign release asset refused");
byte[] Zip(string[] files)
{
    using var stream = new MemoryStream(); using (var zip = new ZipArchive(stream, ZipArchiveMode.Create, true)) foreach (var file in files) { using var target = zip.CreateEntry(file).Open(); target.Write(Encoding.UTF8.GetBytes("synthetic fixture")); }
    return stream.ToArray();
}
var valid = Zip(["Screenshot.exe", "LICENSE.txt", "ThirdPartyNotices.txt"]); string hash = Convert.ToHexString(SHA256.HashData(valid));
ReleaseUpdates.VerifyChecksum(valid, hash + "  " + name, name); Check(true, "checksum accepted");
Reject(() => ReleaseUpdates.VerifyChecksum(valid, new string('0', 64) + "  " + name, name), "tampered checksum refused");
Reject(() => ReleaseUpdates.VerifyChecksum(valid, $"{hash}  {name}\n{hash}  {name}", name), "duplicate checksum refused");
string temp = Path.Combine(Path.GetTempPath(), "screenshot-test-" + Guid.NewGuid().ToString("N"));
try
{
    ReleaseUpdates.Extract(valid, temp); Check(Directory.GetFiles(temp).Length == 3, "portable package extracted"); Directory.Delete(temp, true);
    Reject(() => ReleaseUpdates.Extract(Zip(["../Screenshot.exe", "LICENSE.txt", "ThirdPartyNotices.txt"]), temp), "ZIP traversal refused");
    Reject(() => ReleaseUpdates.Extract(Zip(["Screenshot.exe", "LICENSE.txt", "run.ps1"]), temp), "executable script in package refused");
    Reject(() => ReleaseUpdates.Extract(Zip(["Screenshot.exe", "Screenshot.exe", "LICENSE.txt"]), temp), "duplicate entry refused");
}
finally { if (Directory.Exists(temp)) Directory.Delete(temp, true); }
string install = Path.Combine(Path.GetTempPath(), "screenshot-install-" + Guid.NewGuid().ToString("N"));
string candidate = install + "-candidate";
try
{
    Directory.CreateDirectory(install); Directory.CreateDirectory(candidate);
    foreach (string file in PortableInstall.Files) { File.WriteAllText(Path.Combine(install, file), "old"); File.WriteAllText(Path.Combine(candidate, file), "new"); }
    File.WriteAllText(Path.Combine(install, "personal.txt"), "preserve");
    try { PortableInstall.Replace(install, candidate, () => throw new IOException("synthetic launch failure")); throw new Exception("rollback did not throw"); } catch (IOException) { }
    Check(PortableInstall.Files.All(file => File.ReadAllText(Path.Combine(install, file)) == "old"), "failed launch rolls back all installed files");
    PortableInstall.Replace(install, candidate, () => { });
    Check(PortableInstall.Files.All(file => File.ReadAllText(Path.Combine(install, file)) == "new"), "portable update replaces expected files");
    Check(File.ReadAllText(Path.Combine(install, "personal.txt")) == "preserve", "update preserves unrelated user files");
}
finally { Directory.Delete(install, true); Directory.Delete(candidate, true); }
Console.WriteLine($"{count} checks passed");
