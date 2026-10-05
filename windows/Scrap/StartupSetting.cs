namespace Scrap;

public sealed class StartupSetting(Func<string?> read, Action<string?> write, string executable, string arguments = "")
{
    public bool Enabled => string.Equals(read(), Command(), StringComparison.OrdinalIgnoreCase);

    public void SetEnabled(bool enabled) => write(enabled ? Command() : null);

    private string Command()
    {
        if (string.IsNullOrWhiteSpace(executable) || executable.Contains('"') || executable.Contains('\r') || executable.Contains('\n'))
            throw new InvalidOperationException("Scrap's executable path is invalid.");
        var command = $"\"{executable}\"{(arguments.Length == 0 ? "" : " " + arguments)}";
        if (command.Length > 260) throw new InvalidOperationException("Move Scrap to a shorter path before enabling startup.");
        return command;
    }
}
