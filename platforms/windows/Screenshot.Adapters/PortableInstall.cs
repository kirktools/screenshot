using System.Runtime.CompilerServices;
[assembly: InternalsVisibleTo("Screenshot.Tests")]
namespace Screenshot.Adapters;
// 只替换安装清单中的文件；启动失败恢复旧文件，保留用户其他内容。
public static class PortableInstall
{
    static IReadOnlyList<string> Specification(string key)
    {
        using var stream = typeof(PortableInstall).Assembly.GetManifestResourceStream("Screenshot.PackageFiles.json")!;
        using var json = System.Text.Json.JsonDocument.Parse(stream);
        return Array.AsReadOnly(json.RootElement.GetProperty(key).EnumerateArray().Select(e => e.GetString()!).ToArray());
    }
    public static IReadOnlyList<string> Files { get; } = Specification("required");
    public static IReadOnlyList<string> OptionalFiles { get; } = Specification("optional");
    public static string[] CandidateFiles(string directory) => Files.Concat(OptionalFiles.Where(n => File.Exists(Path.Combine(directory, n)))).ToArray();
    public static string Digest(string directory)
    {
        using var hash = System.Security.Cryptography.IncrementalHash.CreateHash(System.Security.Cryptography.HashAlgorithmName.SHA256);
        foreach (string name in CandidateFiles(directory).Order(StringComparer.OrdinalIgnoreCase))
        {
            string file = Path.Combine(directory, name);
            if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("更新组件不能为链接");
            hash.AppendData(System.Text.Encoding.UTF8.GetBytes(name.ToLowerInvariant() + "\0"));
            using var input = File.OpenRead(file); hash.AppendData(System.Security.Cryptography.SHA256.HashData(input));
        }
        return Convert.ToHexString(hash.GetHashAndReset());
    }
    public static string Replace(string install, string candidate, Action launch) => Replace(install, candidate, launch, (source, target) => File.Copy(source, target));
    internal static string Replace(string install, string candidate, Action launch, Action<string, string> copy)
    {
        var nextFiles = CandidateFiles(candidate);
        var allFiles = nextFiles.Concat(OptionalFiles.Where(n => File.Exists(Path.Combine(install, n)))).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (Files.Any(n => !File.Exists(Path.Combine(candidate, n))) || allFiles.Any(n => Directory.Exists(Path.Combine(install, n)))) throw new InvalidDataException("更新缺少必要文件");
        if ((File.GetAttributes(candidate) & FileAttributes.ReparsePoint) != 0 || nextFiles.Any(n => (File.GetAttributes(Path.Combine(candidate,n)) & FileAttributes.ReparsePoint) != 0) || (File.GetAttributes(install) & FileAttributes.ReparsePoint) != 0 || allFiles.Any(n => File.Exists(Path.Combine(install, n)) && (File.GetAttributes(Path.Combine(install, n)) & FileAttributes.ReparsePoint) != 0)) throw new InvalidDataException("安装位置不能为链接");
        string backup = Path.Combine(install, ".backup-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(backup);
        List<string> moved = [], installed = [];
        try
        {
            foreach (string n in allFiles)
            {
                string target = Path.Combine(install, n);
                if (File.Exists(target)) { File.Move(target, Path.Combine(backup, n)); moved.Add(n); }
                if (nextFiles.Contains(n)) { installed.Add(n); copy(Path.Combine(candidate, n), target); }
            }
            launch(); return backup;
        }
        catch
        {
            foreach (string n in installed) File.Delete(Path.Combine(install, n));
            foreach (string n in moved) File.Move(Path.Combine(backup, n), Path.Combine(install, n));
            throw;
        }
    }
}
