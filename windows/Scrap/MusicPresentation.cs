using System.Net;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Scrap;

public static class MusicPresentation
{
    public static Uri ArtistUrl(string artist) => new("https://www.last.fm/music/" + Uri.EscapeDataString(artist));
    public static Uri TrackUrl(string artist, string track) => new(ArtistUrl(artist).AbsoluteUri + "/_/" + Uri.EscapeDataString(track));
    public static Uri AlbumUrl(string artist, string album) => new(ArtistUrl(artist).AbsoluteUri + "/" + Uri.EscapeDataString(album));
    public static Uri UserUrl(string user) => new("https://www.last.fm/user/" + Uri.EscapeDataString(user));
    public static Uri TagUrl(string tag) => new("https://www.last.fm/tag/" + Uri.EscapeDataString(tag));
    public static Uri ChartUrl(string kind, JsonNode row)
    {
        var name = row["name"]?.ToString() ?? "";
        var artist = row["artist"]?["name"]?.ToString() ?? row["artist"]?["#text"]?.ToString() ?? "";
        return kind switch { "artists" => ArtistUrl(name), "albums" => AlbumUrl(artist, name), _ => TrackUrl(artist, name) };
    }
    public static long? Count(JsonNode? value) => long.TryParse(value?.ToString(), out var count) && count >= 0 ? count : null;
    public static string ListeningSummary(PlayingTrack track, long? artistCount, long? trackCount)
    {
        if (artistCount == null || trackCount == null) return "Listening history unavailable.";
        if (artistCount == 0) return $"You've never scrobbled {track.Artist} before.";
        if (trackCount == 0) return $"You've scrobbled {track.Artist} {artistCount:N0} times, but not this track.";
        return $"You've scrobbled {track.Artist} {artistCount:N0} times and {track.Title} {trackCount:N0} times.";
    }
    public static string Biography(string html) => WebUtility.HtmlDecode(Regex.Replace(
        Regex.Replace(html, "<a\\b[^>]*>.*?</a>", "", RegexOptions.Singleline | RegexOptions.IgnoreCase), "<[^>]+>", "")).Trim();

    public static Uri? ImageUrl(JsonNode? images)
    {
        if (images is not JsonArray rows) return null;
        foreach (var row in rows.Reverse())
            if (Uri.TryCreate(row?["#text"]?.ToString(), UriKind.Absolute, out var uri) && uri.Scheme == "https" && !uri.AbsolutePath.Contains("2a96cbd8b46e442fc41c2b86b821562f")) return uri;
        return null;
    }
}
