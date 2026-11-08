// runhidden.exe - windowless launcher for scheduled tasks and other console jobs.
//
// Usage:  runhidden.exe <program> [args...]
//
// Windows Terminal is the default terminal on Windows 11, so a console program (pwsh, powershell,
// cmd, python...) started by Task Scheduler gets a new console and Windows Terminal shows it as a
// window; "-WindowStyle Hidden" only hides it after it has already appeared. This launcher is a
// GUI-subsystem exe (no console of its own) that starts the program with CREATE_NO_WINDOW: the
// program still gets a console (stdout, Ctrl events and console children all work) but that console
// never has a window and is never handed to Windows Terminal. It waits for the program and returns
// its exit code, so the task's "Last Run Result" stays meaningful. The rest of the command line is
// passed through untouched.
using System;
using System.Runtime.InteropServices;

static class RunHidden
{
    const uint CREATE_NO_WINDOW = 0x08000000;
    const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    const int STARTF_USESHOWWINDOW = 0x00000001;
    const short SW_HIDE = 0;
    const uint INFINITE = 0xFFFFFFFF;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcessW(string app, System.Text.StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit,
        uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    // Everything after our own executable on the raw command line, quoting preserved.
    static string Rest(string cl)
    {
        int i = 0;
        while (i < cl.Length && char.IsWhiteSpace(cl[i])) i++;
        if (i < cl.Length && cl[i] == '"')
        {
            int j = cl.IndexOf('"', i + 1);
            i = j < 0 ? cl.Length : j + 1;
        }
        else
        {
            while (i < cl.Length && !char.IsWhiteSpace(cl[i])) i++;
        }
        return cl.Substring(i).Trim();
    }

    static int Main()
    {
        string cmd = Rest(Environment.CommandLine);
        if (cmd.Length == 0) return 87; // ERROR_INVALID_PARAMETER

        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        si.dwFlags = STARTF_USESHOWWINDOW;
        si.wShowWindow = SW_HIDE;
        PROCESS_INFORMATION pi;
        if (!CreateProcessW(null, new System.Text.StringBuilder(cmd), IntPtr.Zero, IntPtr.Zero, false,
                CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, IntPtr.Zero, null, ref si, out pi))
            return Marshal.GetLastWin32Error();

        CloseHandle(pi.hThread);
        WaitForSingleObject(pi.hProcess, INFINITE);
        uint code;
        GetExitCodeProcess(pi.hProcess, out code);
        CloseHandle(pi.hProcess);
        return unchecked((int)code);
    }
}
