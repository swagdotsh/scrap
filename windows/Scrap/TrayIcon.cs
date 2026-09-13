using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Scrap;
public sealed class TrayIcon : IDisposable
{
    private const uint CallbackMessage = 0x8001;
    private readonly nint window;
    private readonly SubclassProc callback;
    private readonly Action open, quit, settings, requestMenu;
    private readonly nint icon;
    private readonly uint taskbarCreated = RegisterWindowMessage("TaskbarCreated");
    private NotifyIconData data;
    private bool disposed;
    public bool Available { get; private set; }

    public TrayIcon(nint window, Action open, Action quit, Action settings, Action requestMenu)
    {
        this.window = window; this.open = open; this.quit = quit;
        this.settings = settings; this.requestMenu = requestMenu;
        callback = WindowProc;
        icon = LoadImage(0, Path.Combine(AppContext.BaseDirectory, "Assets", "Scrap.ico"), 1,
            GetSystemMetrics(49), GetSystemMetrics(50), 0x10);
        if (icon == 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not load the Scrap tray icon.");
        data = new NotifyIconData
        {
            Size = (uint)Marshal.SizeOf<NotifyIconData>(), Window = window, Id = 1,
            Flags = 1 | 2 | 4, CallbackMessage = CallbackMessage,
            Icon = icon, Tip = "Scrap", Info = "", InfoTitle = ""
        };
        if (!SetWindowSubclass(window, callback, 1, 0)) { DestroyIcon(icon); throw new Win32Exception("Could not attach the Scrap tray icon."); }
        Available = Shell_NotifyIcon(0, ref data);
        if (!Available)
        {
            RemoveWindowSubclass(window, callback, 1);
            DestroyIcon(icon);
            throw new Win32Exception("Could not create the Scrap tray icon.");
        }
    }

    private nint WindowProc(nint hwnd, uint message, nuint wParam, nint lParam, nuint id, nuint reference)
    {
        if (message == taskbarCreated)
        {
            Available = Shell_NotifyIcon(0, ref data);
            if (!Available) open();
        }
        if (message == CallbackMessage)
        {
            var notification = (uint)(long)lParam;
            if (notification is 0x202 or 0x203 or 0x400 or 0x401 or 0x405) open();
            else if (notification is 0x205 or 0x7B) requestMenu();
            return 0;
        }
        return DefSubclassProc(hwnd, message, wParam, lParam);
    }

    public void NotifyHidden()
    {
        if (!Available || disposed) return;
        var notification = data;
        notification.Flags = 0x10;
        notification.InfoTitle = "Scrap is in the tray";
        notification.Info = "Scrap is still running. Click its tray icon to reopen it, or right-click and choose Quit Scrap to exit.";
        notification.InfoFlags = 1;
        Shell_NotifyIcon(1, ref notification);
    }

    public void ShowMenu(string loveLabel, Action? toggleLove)
    {
        if (disposed) return;
        var menu = CreatePopupMenu();
        if (menu == 0) return;
        uint selected;
        try
        {
            AppendMenu(menu, 0, 1, "Open Scrap");
            AppendMenu(menu, 0, 3, "Settings");
            AppendMenu(menu, toggleLove == null ? 1u : 0u, 4, loveLabel);
            AppendMenu(menu, 0x800, 0, "");
            AppendMenu(menu, 0, 2, "Quit Scrap");
            GetCursorPos(out var point);
            SetForegroundWindow(window);
            selected = TrackPopupMenu(menu, 0x100 | 0x2, point.X, point.Y, 0, window, 0);
            PostMessage(window, 0, 0, 0);
        }
        finally { DestroyMenu(menu); }
        if (selected == 1) open();
        else if (selected == 2) quit();
        else if (selected == 3) settings();
        else if (selected == 4) toggleLove?.Invoke();
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        Shell_NotifyIcon(2, ref data);
        RemoveWindowSubclass(window, callback, 1);
        Available = false;
        DestroyIcon(icon);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint Size;
        public nint Window;
        public uint Id, Flags, CallbackMessage;
        public nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint Version;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags;
        public Guid Guid;
        public nint BalloonIcon;
    }
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate nint SubclassProc(nint hwnd, uint message, nuint wParam, nint lParam, nuint id, nuint reference);
    [DllImport("comctl32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowSubclass(nint hwnd, SubclassProc callback, nuint id, nuint reference);
    [DllImport("comctl32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool RemoveWindowSubclass(nint hwnd, SubclassProc callback, nuint id);
    [DllImport("comctl32.dll")] private static extern nint DefSubclassProc(nint hwnd, uint message, nuint wParam, nint lParam);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Shell_NotifyIcon(uint message, ref NotifyIconData data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessage(string message);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern nint LoadImage(nint instance, string name, uint type, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyIcon(nint icon);
    [DllImport("user32.dll")] private static extern nint CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AppendMenu(nint menu, uint flags, nuint id, string text);
    [DllImport("user32.dll")] private static extern uint TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint hwnd, nint rect);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyMenu(nint menu);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PostMessage(nint hwnd, uint message, nuint wParam, nint lParam);
}
