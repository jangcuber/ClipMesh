using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;

namespace ClipMesh;

static class InstanceControl {
    const string PipeName = "ClipMesh-Desktop-Control-v1";
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string? className, string title);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    public static bool Request(string command, int timeout = 1200) {
        try {
            using var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
            pipe.Connect(timeout); pipe.ReadMode = PipeTransmissionMode.Byte;
            using var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
            writer.WriteLine(command);
            // The acknowledgement is bounded; an unhealthy existing app cannot hang a second launch.
            using var deadline = new CancellationTokenSource(timeout);
            using var reader = new StreamReader(pipe, Encoding.UTF8, leaveOpen: true);
            return reader.ReadLineAsync(deadline.Token).AsTask().GetAwaiter().GetResult() == "ok";
        } catch { return false; }
    }
    public static void ActivateExisting() {
        if (Request("show")) return;
        // Older releases have no control pipe but already expose this main window.
        var window = FindWindow(null, "ClipMesh · Account-free clipboard sync");
        if (window != IntPtr.Zero) { ShowWindow(window, 9); SetForegroundWindow(window); }
        else MessageBox.Show("ClipMesh is starting or not responding. Wait a moment and open it again. If an update failed, run the repaired installer.", "ClipMesh");
    }
    public static async Task Serve(MeshForm form, CancellationToken stopping) {
        while (!stopping.IsCancellationRequested) {
            try {
                using var pipe = new NamedPipeServerStream(PipeName, PipeDirection.InOut, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(stopping);
                using var reader = new StreamReader(pipe, Encoding.UTF8, leaveOpen: true);
                using var requestDeadline = CancellationTokenSource.CreateLinkedTokenSource(stopping);
                requestDeadline.CancelAfter(1500);
                var command = await reader.ReadLineAsync(requestDeadline.Token);
                if (command is not ("show" or "shutdown")) continue;
                if (form.IsDisposed || !form.IsHandleCreated) continue;
                form.BeginInvoke(() => { if (command == "show") form.ShowSettings(); else form.ExitForUpdate(); });
                using var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
                await writer.WriteLineAsync("ok");
            } catch (OperationCanceledException) { }
            catch (IOException) { }
            catch (InvalidOperationException) { }
        }
    }
}

/// Runs from the installer's temporary NEW payload, before overwriting any installed executable.
static class UpdatePreparation {
    public static int Run(string[] args) {
        try {
            int option = Array.IndexOf(args, "--install-dir");
            if (option < 0 || option + 1 >= args.Length || !Path.IsPathFullyQualified(args[option + 1])) return 2;
            string directory = Path.GetFullPath(args[option + 1]);
            string app = Path.Combine(directory, "ClipMesh.exe"), core = Path.Combine(directory, "clipmesh-core.exe");
            // Shutdown is scoped below to exact executable paths and this interactive session.
            // The user-only pipe is useful only when this same installation is running.
            if (HasProcess(app)) InstanceControl.Request("shutdown", 800);
            StopExact(app, graceful: true);
            StopExact(core, graceful: false);
            // Also stop legacy orphan cores. Never rely on a process-name-wide taskkill.
            foreach (string file in new[] { app, core }) {
                if (!File.Exists(file) || string.Equals(Environment.ProcessPath, file, StringComparison.OrdinalIgnoreCase)) continue;
                // During uninstall this helper itself runs from the installed app; its own
                // executable lock disappears when ExecWait returns, before deletion starts.
                using var unlocked = new FileStream(file, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
            }
            return 0;
        } catch {
            // No credentials, config keys or clipboard contents are read by this helper.
            Console.Error.WriteLine("ClipMesh update preparation failed: an installed process or file is still in use. Close ClipMesh and retry.");
            return 1;
        }
    }
    static bool Matches(Process process, string path) {
        if (process.Id == Environment.ProcessId || process.SessionId != Process.GetCurrentProcess().SessionId) return false;
        try { return string.Equals(process.MainModule?.FileName, path, StringComparison.OrdinalIgnoreCase); }
        catch (InvalidOperationException) { return false; } // Already exited.
        // Access-denied inspection fails the update instead of guessing which process to kill.
    }
    static bool HasProcess(string path) {
        foreach (var process in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(path))) {
            using (process) { if (Matches(process, path)) return true; }
        }
        return false;
    }
    static void StopExact(string path, bool graceful) {
        foreach (var process in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(path))) {
            using (process) {
                if (!Matches(process, path) || process.HasExited) continue;
                if (graceful) { process.CloseMainWindow(); if (process.WaitForExit(2000)) continue; }
                try { process.Kill(); } catch (InvalidOperationException) { }
                if (!process.WaitForExit(5000)) throw new IOException("Process did not stop");
            }
        }
        if (HasProcess(path)) throw new IOException("Installed process restarted during update");
    }
}
