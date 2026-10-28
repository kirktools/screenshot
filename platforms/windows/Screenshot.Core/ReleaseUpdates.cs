using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Screenshot.Core;

public sealed record UpdateOffer(Version Version, string Tag, Uri Page, string ArchiveName, Uri Archive, Uri Checksums);
public static class ReleaseUpdates
{
    public const int MaximumArchiveBytes = 160 * 1024 * 1024;
    public const long MaximumExpandedBytes = 200L * 1024 * 1024;
    public static UpdateOffer? Parse(byte[] json, Version current, string architecture)
    {
        using var doc = JsonDocument.Parse(json); var root = doc.RootElement;
        if (root.GetProperty("draft").GetBoolean() || root.GetProperty("prerelease").GetBoolean()) return null;
        string tag = root.GetProperty("tag_name").GetString() ?? "";
        if (!Regex.IsMatch(tag, @"^v[0-9]+\.[0-9]+\.[0-9]+$")) throw new InvalidDataException("正式版标签格式无效");
        var version = Version.Parse(tag[1..]);
        if (version <= new Version(current.Major, current.Minor, Math.Max(0, current.Build))) return null;
        if (architecture is not ("x64" or "arm64")) throw new InvalidDataException("不支持的 Windows 架构");
        string archive = $"Screenshot-{version}-Windows-{architecture}.zip", checksum = $"SHA256SUMS-Windows-{architecture}.txt";
        Uri Asset(string name, int limit)
        {
            var assets = root.GetProperty("assets").EnumerateArray().Where(a => a.GetProperty("name").GetString() == name).ToArray();
            if (assets.Length != 1) throw new InvalidDataException("正式版尚无唯一、适用于此架构的 Windows 安装包或校验清单");
            var a = assets[0]; long size = a.GetProperty("size").GetInt64();
            string expected = $"https://github.com/kirktools/screenshot/releases/download/{tag}/{name}";
            if (size < 1 || size > limit || a.GetProperty("browser_download_url").GetString() != expected) throw new InvalidDataException("正式版资源地址或大小不符合安全约束");
            return new(expected);
        }
        return new(version, tag, new($"https://github.com/kirktools/screenshot/releases/tag/{tag}"), archive, Asset(archive, MaximumArchiveBytes), Asset(checksum, 65536));
    }
    public static void VerifyChecksum(byte[] archive, string manifest, string archiveName)
    {
        var hashes = new List<string>();
        foreach (string line in manifest.Split('\n'))
        {
            var match = Regex.Match(line.Trim(), @"^([A-Fa-f0-9]{64})\s+\*?(?:dist/)?([A-Za-z0-9._-]+)$");
            if (match.Success && match.Groups[2].Value == archiveName) hashes.Add(match.Groups[1].Value);
        }
        if (hashes.Count != 1 || !Convert.ToHexString(SHA256.HashData(archive)).Equals(hashes[0], StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("更新包 SHA-256 不匹配或校验值不唯一，已拒绝安装");
    }
    public static void Extract(byte[] bytes, string destination)
    {
        if (bytes.Length > MaximumArchiveBytes) throw new InvalidDataException("更新包过大");
        using var archive = new ZipArchive(new MemoryStream(bytes));
        var files = archive.Entries.Where(e => !e.FullName.EndsWith('/')).ToArray();
        string[] allowed = ["Screenshot.exe", "LICENSE.txt", "ThirdPartyNotices.txt"];
        if (files.Length != 3 || files.Select(e => e.FullName).Distinct(StringComparer.OrdinalIgnoreCase).Count() != 3 || files.Any(e => !allowed.Contains(e.FullName, StringComparer.Ordinal))) throw new InvalidDataException("安装包目录结构不符合约束，已拒绝解压");
        if (files.Sum(e => e.Length) > MaximumExpandedBytes || files.Any(e => ((e.ExternalAttributes >> 16) & 0xF000) == 0xA000)) throw new InvalidDataException("安装包超过资源上限或包含链接");
        Directory.CreateDirectory(destination);
        foreach (var entry in files)
        {
            using var source = entry.Open(); using var target = new FileStream(Path.Combine(destination, entry.FullName), FileMode.CreateNew);
            var buffer = new byte[65536]; long count = 0; int read;
            while ((read = source.Read(buffer)) > 0) { count += read; if (count > entry.Length || count > MaximumExpandedBytes) throw new InvalidDataException("解压内容超过声明大小"); target.Write(buffer, 0, read); }
            if (count != entry.Length) throw new InvalidDataException("安装包不完整");
        }
    }
}
public sealed class ReleaseClient : IDisposable
{
    readonly HttpClient http = new(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromMinutes(5) };
    static readonly string[] hosts = ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "objects-origin.githubusercontent.com"];
    public ReleaseClient() { http.DefaultRequestHeaders.UserAgent.ParseAdd("Screenshot-Windows/1.0"); }
    public async Task<byte[]> Download(Uri url, int limit, CancellationToken cancellation)
    {
        for (int redirects = 0; redirects < 6; redirects++)
        {
            if (url.Scheme != "https" || url.Port != 443 || !string.IsNullOrEmpty(url.UserInfo) || !hosts.Contains(url.Host)) throw new InvalidDataException("更新请求只允许 GitHub 官方 HTTPS 地址");
            using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancellation);
            if ((int)response.StatusCode is >= 300 and < 400)
            { var next = response.Headers.Location ?? throw new InvalidDataException("更新跳转缺少地址"); url = next.IsAbsoluteUri ? next : new Uri(url, next); continue; }
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength > limit) throw new InvalidDataException("下载超过大小上限");
            using var output = new MemoryStream(); await using var input = await response.Content.ReadAsStreamAsync(cancellation);
            var buffer = new byte[65536]; int read;
            while ((read = await input.ReadAsync(buffer, cancellation)) > 0) { if (output.Length + read > limit) throw new InvalidDataException("下载超过大小上限"); output.Write(buffer, 0, read); }
            return output.ToArray();
        }
        throw new InvalidDataException("更新跳转过多");
    }
    public void Dispose() => http.Dispose();
}
