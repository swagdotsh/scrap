using System.Text.Json.Nodes;

namespace Scrap;

public sealed record ReportItem(string Name, string Artist, long Count, Uri Url, Uri[] Images);
public sealed record ScrobbledPlay(string Title, string Artist, string Album, DateTimeOffset Date, Uri[] Images);

public sealed record WeeklyReport(DateTime Start, DateTime End, int Scrobbles, long PreviousScrobbles,
    ReportItem? TopArtist, ReportItem? TopAlbum, ReportItem? TopTrack,
    IReadOnlyList<ReportItem> NewArtists, IReadOnlyList<ReportItem> NewAlbums, IReadOnlyList<ReportItem> NewTracks)
{
    public const int DiscoveryCheckLimit = 25;

    public static (DateTime Start, DateTime End) LatestWeek(DateTime now)
    {
        var start = now.Date.AddDays(-(((int)now.DayOfWeek - (int)DayOfWeek.Saturday + 7) % 7));
        if (now >= start.AddDays(6)) return (start, start.AddDays(7));
        return (start.AddDays(-7), start);
    }

    public static DateTime NextReportDate(DateTime weekEnd) => weekEnd.AddDays(6);

    public static async Task<WeeklyReport> BuildAsync(Func<Dictionary<string, string>, Task<JsonNode>> request, string user, DateTime start, DateTime end, CancellationToken cancel = default)
    {
        static string Unix(DateTime local) => new DateTimeOffset(local).ToUnixTimeSeconds().ToString();
        var plays = await PlaysAsync(request, user, Unix(start), DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString(), cancel);
        var previousJson = await request(new() { ["method"] = "user.getRecentTracks", ["user"] = user, ["limit"] = "1", ["from"] = Unix(start.AddDays(-7)), ["to"] = Unix(start) });
        var previous = MusicPresentation.Count(previousJson["recenttracks"]?["@attr"]?["total"]) ?? 0;
        var weekStart = new DateTimeOffset(start); var weekEnd = new DateTimeOffset(end);
        var inWeek = plays.Where(p => p.Date >= weekStart && p.Date < weekEnd).ToList();

        static string ArtistKey(ScrobbledPlay p) => p.Artist.ToLowerInvariant();
        static string AlbumKey(ScrobbledPlay p) => p.Artist.ToLowerInvariant() + "\n" + p.Album.ToLowerInvariant();
        static string TrackKey(ScrobbledPlay p) => p.Artist.ToLowerInvariant() + "\n" + p.Title.ToLowerInvariant();
        var artists = Rank(inWeek, ArtistKey); var albums = Rank(inWeek.Where(p => p.Album.Length > 0), AlbumKey); var tracks = Rank(inWeek, TrackKey);
        var sinceArtists = Tally(plays, ArtistKey); var sinceAlbums = Tally(plays.Where(p => p.Album.Length > 0), AlbumKey); var sinceTracks = Tally(plays, TrackKey);

        ReportItem ArtistItem(Ranked e) => new(e.Play.Artist, "", e.Count, MusicPresentation.ArtistUrl(e.Play.Artist), []);
        ReportItem AlbumItem(Ranked e) => new(e.Play.Album, e.Play.Artist, e.Count, MusicPresentation.AlbumUrl(e.Play.Artist, e.Play.Album), e.Play.Images);
        ReportItem TrackItem(Ranked e) => new(e.Play.Title, e.Play.Artist, e.Count, MusicPresentation.TrackUrl(e.Play.Artist, e.Play.Title), e.Play.Images);

        async Task<List<ReportItem>> New(List<Ranked> candidates, Dictionary<string, int> since, Func<ScrobbledPlay, Dictionary<string, string>> query, Func<JsonNode, JsonNode?> userCount, Func<Ranked, ReportItem> item)
        {
            var result = new List<ReportItem>();
            foreach (var batch in candidates.Take(DiscoveryCheckLimit).Chunk(5))
            {
                cancel.ThrowIfCancellationRequested();
                var checks = await Task.WhenAll(batch.Select(async candidate =>
                {
                    try
                    {
                        var args = query(candidate.Play); args["username"] = user;
                        var total = MusicPresentation.Count(userCount(await request(args))?["userplaycount"]);
                        return total != null && total <= since.GetValueOrDefault(candidate.Key, candidate.Count);
                    }
                    catch { return false; }
                }));
                result.AddRange(batch.Where((_, i) => checks[i]).Select(item));
            }
            return result;
        }

        return new(start, end, inWeek.Count, previous,
            artists.Select(ArtistItem).FirstOrDefault(), albums.Select(AlbumItem).FirstOrDefault(), tracks.Select(TrackItem).FirstOrDefault(),
            await New(artists, sinceArtists, p => new() { ["method"] = "artist.getInfo", ["artist"] = p.Artist }, j => j["artist"]?["stats"], ArtistItem),
            await New(albums, sinceAlbums, p => new() { ["method"] = "album.getInfo", ["artist"] = p.Artist, ["album"] = p.Album }, j => j["album"], AlbumItem),
            await New(tracks, sinceTracks, p => new() { ["method"] = "track.getInfo", ["artist"] = p.Artist, ["track"] = p.Title }, j => j["track"], TrackItem));
    }

    private sealed record Ranked(string Key, int Count, ScrobbledPlay Play);

    private static Dictionary<string, int> Tally(IEnumerable<ScrobbledPlay> plays, Func<ScrobbledPlay, string> key) =>
        plays.GroupBy(key).ToDictionary(g => g.Key, g => g.Count());

    private static List<Ranked> Rank(IEnumerable<ScrobbledPlay> plays, Func<ScrobbledPlay, string> key) =>
        plays.GroupBy(key).Select(g => new Ranked(g.Key, g.Count(), g.First())).OrderByDescending(r => r.Count).ToList();

    public static IEnumerable<ScrobbledPlay> ParsePlays(JsonNode? tracks)
    {
        var rows = tracks is JsonArray array ? array.OfType<JsonNode>() : tracks == null ? [] : [tracks];
        foreach (var row in rows)
        {
            var title = row["name"]?.ToString() ?? "";
            if (title.Length == 0 || MusicPresentation.Count(row["date"]?["uts"]) is not { } uts) continue;
            yield return new(title, row["artist"]?["#text"]?.ToString() ?? "", row["album"]?["#text"]?.ToString() ?? "",
                DateTimeOffset.FromUnixTimeSeconds(uts), MusicPresentation.ImageUrls(row["image"]).ToArray());
        }
    }

    private static async Task<List<ScrobbledPlay>> PlaysAsync(Func<Dictionary<string, string>, Task<JsonNode>> request, string user, string from, string to, CancellationToken cancel)
    {
        var plays = new List<ScrobbledPlay>();
        var totalPages = 1;
        for (var page = 1; page <= totalPages; page++)
        {
            cancel.ThrowIfCancellationRequested();
            var json = await request(new() { ["method"] = "user.getRecentTracks", ["user"] = user, ["limit"] = "200", ["page"] = page.ToString(), ["from"] = from, ["to"] = to });
            if (page == 1) totalPages = (int)Math.Max(1, MusicPresentation.Count(json["recenttracks"]?["@attr"]?["totalPages"]) ?? 1);
            plays.AddRange(ParsePlays(json["recenttracks"]?["track"]));
        }
        return plays;
    }
}
