using System.Text.Json.Nodes;

namespace Scrap;

public static class TrackLove
{
    public static bool Parse(JsonNode response) => response["track"]?["userloved"]?.ToString() switch
    {
        "1" => true,
        "0" => false,
        _ => throw new InvalidOperationException("Last.fm did not return this track's loved status.")
    };

    public static async Task ToggleAsync(Func<Task<bool>> read, Func<bool, Task> write)
    {
        // Always read before writing, including when the status changed outside Scrap.
        var loved = await read();
        await write(!loved);
    }
}
