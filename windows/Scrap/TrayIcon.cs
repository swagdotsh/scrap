using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Scrap;
public sealed class TrayIcon : IDisposable
{
    private const uint CallbackMessage = 0x8001;
    private readonly nint window;
    private readonly SubclassProc callback;
    private readonly Action open, quit, settings, requestMenu, tagTrack, tagArtist, toggleDiscord;
    private readonly Func<bool> discordEnabled;
    private readonly nint icon, idleIcon;
    private bool scrobbling = true;
    private readonly uint taskbarCreated = RegisterWindowMessage("TaskbarCreated");
    private NotifyIconData data;
    private bool disposed;
    public bool Available { get; private set; }

    public TrayIcon(nint window, Action open, Action quit, Action settings, Action requestMenu, Action tagTrack, Action tagArtist,
        Func<bool> discordEnabled, Action toggleDiscord)
    {
        this.window = window; this.open = open; this.quit = quit;
        this.settings = settings; this.requestMenu = requestMenu; this.tagTrack = tagTrack; this.tagArtist = tagArtist;
        this.discordEnabled = discordEnabled; this.toggleDiscord = toggleDiscord;
        callback = WindowProc;
        icon = LoadIcon("Scrap.ico");
        if (icon == 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not load the scrap tray icon.");
        idleIcon = LoadIcon("ScrapIdle.ico");
        data = new NotifyIconData
        {
            Size = (uint)Marshal.SizeOf<NotifyIconData>(), Window = window, Id = 1,
            Flags = 1 | 2 | 4, CallbackMessage = CallbackMessage,
            Icon = icon, Tip = "scrap", Info = "", InfoTitle = ""
        };
        if (!SetWindowSubclass(window, callback, 1, 0)) { DestroyIcons(); throw new Win32Exception("Could not attach the scrap tray icon."); }
        Available = Shell_NotifyIcon(0, ref data);
        if (!Available)
        {
            RemoveWindowSubclass(window, callback, 1);
            DestroyIcons();
            throw new Win32Exception("Could not create the scrap tray icon.");
        }
    }

    private static nint LoadIcon(string name) =>
        LoadImage(0, Path.Combine(AppContext.BaseDirectory, "Assets", name), 1, GetSystemMetrics(49), GetSystemMetrics(50), 0x10);

    private void DestroyIcons()
    {
        DestroyIcon(icon);
        if (idleIcon != 0) DestroyIcon(idleIcon);
    }

    /// The full-colour icon while a track is being scrobbled; a greyed-out one otherwise.
    public void SetScrobbling(bool active)
    {
        if (disposed || active == scrobbling) return;
        scrobbling = active;
        data.Icon = active || idleIcon == 0 ? icon : idleIcon;
        data.Tip = active ? "scrap, scrobbling" : "scrap, not scrobbling";
        data.Flags = 2 | 4;
        if (Available) Shell_NotifyIcon(1, ref data);
        data.Flags = 1 | 2 | 4;
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
        notification.InfoTitle = "scrap is in the tray";
        notification.Info = "scrap is still running. Click its tray icon to reopen it, or right-click and choose Quit scrap to exit.";
        notification.InfoFlags = 1;
        Shell_NotifyIcon(1, ref notification);
    }

    public void ShowMenu(string loveLabel, Action? toggleLove, bool canTag, string? currentTitle, string? currentArtistAlbum)
    {
        if (disposed) return;
        var menu = CreatePopupMenu();
        if (menu == 0) return;
        uint selected;
        try
        {
            AppendMenu(menu, 1, 7, "Now playing");
            AppendMenu(menu, 1, 8, string.IsNullOrWhiteSpace(currentTitle) ? "Nothing playing" : currentTitle);
            AppendMenu(menu, 1, 9, string.IsNullOrWhiteSpace(currentArtistAlbum) ? "—" : currentArtistAlbum);
            AppendMenu(menu, 0x800, 0, "");
            AppendMenu(menu, 0, 1, "Open scrap");
            AppendMenu(menu, 0, 3, "Settings");
            AppendMenu(menu, toggleLove == null ? 1u : 0u, 4, loveLabel);
            AppendMenu(menu, canTag ? 0u : 1u, 5, "Tag track…");
            AppendMenu(menu, canTag ? 0u : 1u, 6, "Tag artist…");
            AppendMenu(menu, 0x800, 0, "");
            AppendMenu(menu, discordEnabled() ? 8u : 0u, 10, "Discord Rich Presence");
            AppendMenu(menu, 0x800, 0, "");
            AppendMenu(menu, 0, 2, "Quit scrap");
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
        else if (selected == 5) tagTrack();
        else if (selected == 6) tagArtist();
        else if (selected == 10) toggleDiscord();
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        Shell_NotifyIcon(2, ref data);
        RemoveWindowSubclass(window, callback, 1);
        Available = false;
        DestroyIcons();
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
