using System.Runtime.CompilerServices;
[assembly: InternalsVisibleTo("Screenshot.Tests")]
namespace Screenshot.Core;
// 只替换安装清单中的文件；启动失败恢复旧文件，保留用户其他内容。
public static class PortableInstall
{
    public static readonly string[] Files = ["Screenshot.exe", "LICENSE.txt", "ThirdPartyNotices.txt"];
    public static string Replace(string install, string candidate, Action launch) => Replace(install, candidate, launch, (source, target) => File.Copy(source, target));
    internal static string Replace(string install, string candidate, Action launch, Action<string, string> copy)
    {
        if (Files.Any(n => !File.Exists(Path.Combine(candidate, n)) || Directory.Exists(Path.Combine(install, n)))) throw new InvalidDataException("更新缺少必要文件");
        if ((File.GetAttributes(install) & FileAttributes.ReparsePoint) != 0 || Files.Any(n => File.Exists(Path.Combine(install, n)) && (File.GetAttributes(Path.Combine(install, n)) & FileAttributes.ReparsePoint) != 0)) throw new InvalidDataException("安装位置不能为链接");
        string backup = Path.Combine(install, ".backup-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(backup);
        List<string> moved = [], installed = [];
        try
        {
            foreach (string n in Files)
            {
                string target = Path.Combine(install, n);
                if (File.Exists(target)) { File.Move(target, Path.Combine(backup, n)); moved.Add(n); }
                installed.Add(n); copy(Path.Combine(candidate, n), target);
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
