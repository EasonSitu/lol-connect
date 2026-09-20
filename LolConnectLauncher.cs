using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class LolConnectLauncher
{
    private static string FindRuntime()
    {
        string installed = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe");
        if (File.Exists(installed)) return installed;
        string paths = (Environment.GetEnvironmentVariable("PATH") ?? "") + ";" +
            (Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.User) ?? "");
        foreach (string item in paths.Split(';'))
        {
            try
            {
                string path = Path.Combine(Environment.ExpandEnvironmentVariables(item.Trim().Trim('"')), "pwsh.exe");
                if (Path.IsPathRooted(path) && File.Exists(path)) return path;
            }
            catch (ArgumentException) { }
        }
        // Optional existing local runtime; never downloaded or installed by this launcher.
        string bundled = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".cache", "codex-runtimes", "codex-primary-runtime", "dependencies", "native", "powershell", "pwsh.exe");
        return File.Exists(bundled) ? bundled : null;
    }

    [STAThread]
    private static int Main(string[] args)
    {
        bool check = args.Length == 1 && args[0] == "--check";
        string folder = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(folder, "lol-guide.ps1");
        if (!File.Exists(script))
        {
            if (!check) MessageBox.Show("请先解压整个工具包，再打开本程序。不要只复制 EXE：它需要同一文件夹中的程序文件。", "LOL 连接诊断助手");
            return 2;
        }
        string runtime = FindRuntime();
        if (runtime == null)
        {
            if (!check) MessageBox.Show("首次使用需要安装 PowerShell 7.2 或更新版本。安装后重新打开本程序。\n\n基础诊断不需要代理节点、Clash 或 Python。使用方法见同目录 README.md。", "LOL 连接诊断助手");
            return 3;
        }
        if (check) return 0;
        try
        {
            ProcessStartInfo start = new ProcessStartInfo(runtime);
            start.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"";
            start.WorkingDirectory = folder;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.WindowStyle = ProcessWindowStyle.Hidden;
            Process.Start(start);
            return 0;
        }
        catch (Exception)
        {
            MessageBox.Show("启动未完成。请尝试同目录的 Start.cmd，并确认文件已完整解压、PowerShell 7 已安装。", "LOL 连接诊断助手");
            return 4;
        }
    }
}
