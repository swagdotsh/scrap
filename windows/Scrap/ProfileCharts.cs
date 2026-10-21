using System.Collections.Concurrent;
using System.Text.Json.Nodes;

namespace Scrap;

public sealed record ChartPeriod(string Key, string Title)
{
    public static readonly ChartPeriod[] All = [new("7day", "Last 7 days"), new("1month", "Last 30 days"), new("12month", "Last 365 days"), new("overall", "All time")];
    public static ChartPeriod From(string? key) => All.FirstOrDefault(p => p.Key == key) ?? All[0];
}

public sealed record ChartEntry(string Name, string Artist, long Count, Uri Url, Uri[] Images);

public static class ProfileCharts
{
    public static readonly string[] Kinds = ["artists", "albums", "tracks"];
    private static readonly ConcurrentDictionary<string, Uri[]> trackArtwork = new();

    public static string Title(string kind) => kind switch { "artists" => "Top artists", "albums" => "Top albums", _ => "Top tracks" };

    public static async Task<List<ChartEntry>> LoadAsync(Func<Dictionary<string, string>, Task<JsonNode>> request, string user, string kind, ChartPeriod period, int limit = 5)
    {
        var json = await request(new() { ["method"] = "user.getTop" + char.ToUpperInvariant(kind[0]) + kind[1..], ["user"] = user, ["period"] = period.Key, ["limit"] = limit.ToString() });
        var entries = new List<ChartEntry>();
        foreach (var row in Rows(json["top" + kind]?[kind[..^1]]).Take(limit))
        {
            var name = row["name"]?.ToString() ?? "";
            if (name.Length == 0) continue;
            var artist = row["artist"]?["name"]?.ToString() ?? row["artist"]?["#text"]?.ToString() ?? "";
            var images = MusicPresentation.ImageUrls(row["image"]).ToArray();
            if (kind == "tracks" && images.Length == 0 && limit <= 10) images = await TrackArtworkAsync(request, artist, name);
            var url = MusicPresentation.ChartUrl(kind, row);
            if (entries.All(e => e.Url != url))
                entries.Add(new(name, artist, MusicPresentation.Count(row["playcount"]) ?? 0, url, images));
        }
        return entries;
    }

    public static async Task<Uri[]> TrackArtworkAsync(Func<Dictionary<string, string>, Task<JsonNode>> request, string artist, string track)
    {
        var key = artist.ToLowerInvariant() + "\n" + track.ToLowerInvariant();
        if (trackArtwork.TryGetValue(key, out var cached)) return cached;
        try
        {
            var json = await request(new() { ["method"] = "track.getInfo", ["artist"] = artist, ["track"] = track });
            return trackArtwork[key] = MusicPresentation.ImageUrls(json["track"]?["album"]?["image"]).ToArray();
        }
        catch { return []; }
    }

    private static IEnumerable<JsonNode> Rows(JsonNode? node) => node is JsonArray array ? array.OfType<JsonNode>() : node == null ? [] : [node];
}
