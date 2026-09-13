using Microsoft.Win32;

namespace Scrap;

public static class WindowsStartup
{
    private const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "Scrap";

    public static StartupSetting Create() => new(Read, Write,
        Environment.ProcessPath ?? throw new InvalidOperationException("Could not locate Scrap's executable."));

    private static string? Read()
    {
        using var key = Registry.CurrentUser.OpenSubKey(Key);
        return key?.GetValue(Name) as string;
    }

    private static void Write(string? command)
    {
        if (command == null)
        {
            using var key = Registry.CurrentUser.OpenSubKey(Key, true);
            key?.DeleteValue(Name, false);
        }
        else
        {
            using var key = Registry.CurrentUser.CreateSubKey(Key);
            key.SetValue(Name, command, RegistryValueKind.String);
        }
    }
}
