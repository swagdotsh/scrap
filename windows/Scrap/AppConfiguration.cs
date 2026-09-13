namespace Scrap;

public sealed record AppConfiguration(string ApiKey, string SharedSecret)
{
    public static AppConfiguration Load()
    {
        var path = Path.Combine(AppContext.BaseDirectory, ".env");
        return Parse(File.Exists(path) ? File.ReadAllText(path) : "");
    }

    public static AppConfiguration Parse(string contents)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var raw in contents.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var separator = line.IndexOf('=');
            if (separator < 1) continue;
            var value = line[(separator + 1)..].Trim();
            if (value.Length >= 2 && (value[0] == '"' && value[^1] == '"' || value[0] == '\'' && value[^1] == '\''))
                value = value[1..^1];
            values[line[..separator].Trim()] = value;
        }
        return new(values.GetValueOrDefault("LASTFM_API_KEY", ""), values.GetValueOrDefault("LASTFM_SHARED_SECRET", ""));
    }
}
