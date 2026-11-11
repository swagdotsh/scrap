using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Scrap;

public enum ReportKind { Week, Month, Year }

/// A report's time span in local time. Weeks run Saturday to Friday.
public sealed record ReportPeriod(ReportKind Kind, DateTime Start, DateTime End)
{
    public static readonly ReportKind[] Kinds = [ReportKind.Week, ReportKind.Month, ReportKind.Year];

    public static ReportPeriod Containing(DateTime date, ReportKind kind)
    {
        var day = DateTime.SpecifyKind(date.Date, DateTimeKind.Unspecified);
        var start = kind switch
        {
            ReportKind.Week => day.AddDays(-(((int)day.DayOfWeek - (int)DayOfWeek.Saturday + 7) % 7)),
            ReportKind.Month => new DateTime(day.Year, day.Month, 1),
            _ => new DateTime(day.Year, 1, 1)
        };
        return new(kind, start, kind switch { ReportKind.Week => start.AddDays(7), ReportKind.Month => start.AddMonths(1), _ => start.AddYears(1) });
    }

    /// The newest period whose report is out.
    public static ReportPeriod Latest(ReportKind kind, DateTime now)
    {
        var period = Containing(now, kind);
        while (period.ReleaseDate > new DateTimeOffset(now)) period = period.Previous;
        return period;
    }

    /// Weekly reports come out on the week's Friday. Monthly and yearly reports come out on the first
    /// Friday after the period ends, at the same time as the report notifications.
    [JsonIgnore]
    public DateTimeOffset ReleaseDate => Kind == ReportKind.Week
        ? new DateTimeOffset(Start.AddDays(6))
        : ReportSchedule.Next(new DateTimeOffset(End).AddSeconds(-1));

    public bool IsReleased(DateTime now) => ReleaseDate <= new DateTimeOffset(now);
    [JsonIgnore]
    public ReportPeriod Previous => Containing(Start.AddDays(-1), Kind);
    [JsonIgnore]
    public ReportPeriod Next => Containing(End, Kind);
    [JsonIgnore]
    public DateTime LastDay => End.AddDays(-1);
    [JsonIgnore]
    public string Noun => Kind.ToString().ToLowerInvariant();

    public string Title(DateTime now) => Kind switch
    {
        ReportKind.Week when Start.Year == now.Year && LastDay.Year == now.Year => $"{Start:MMM d} – {LastDay:MMM d}",
        ReportKind.Week => $"{Start:MMM d} – {LastDay:MMM d}, {LastDay:yyyy}",
        ReportKind.Month => Start.ToString("MMMM yyyy", CultureInfo.CurrentCulture),
        _ => Start.ToString("yyyy", CultureInfo.CurrentCulture)
    };
}

public sealed record ReportItem(string Name, string Artist, long Count, Uri Url, Uri[] Images);
public sealed record ReportTag(string Name, double Weight, Uri Url);
/// The busiest day or month in a period, with what was played most then.
public sealed record ReportHighlight(DateTime Start, int Scrobbles, ReportItem? TopArtist, ReportItem? TopAlbum, ReportItem? TopTrack);
public sealed record ScrobbledPlay(string Title, string Artist, string Album, DateTimeOffset Date, Uri[] Images);

public sealed record ListeningReport(ReportPeriod Period, int Scrobbles, long PreviousScrobbles,
    ReportItem? TopArtist, ReportItem? TopAlbum, ReportItem? TopTrack, DateTimeOffset BuiltAt)
{
    public const int DiscoveryCheckLimit = 25;
    private static readonly int[] RetriedErrors = [8, 11, 16, 29];

    public IReadOnlyList<ReportItem> NewArtists { get; init; } = [];
    public IReadOnlyList<ReportItem> NewAlbums { get; init; } = [];
    public IReadOnlyList<ReportItem> NewTracks { get; init; } = [];
    public IReadOnlyList<ReportTag> TopTags { get; init; } = [];
    /// Scrobbles per hour of the day (0–23) in local time.
    public int[] Hourly { get; init; } = [];
    public ReportHighlight? BusiestDay { get; init; }
    /// Scrobbles per month (January first), for yearly reports.
    public int[] Monthly { get; init; } = [];
    public ReportHighlight? BusiestMonth { get; init; }

    /// Built after the period ended, so it won't change.
    [JsonIgnore]
    public bool IsFinal => BuiltAt >= new DateTimeOffset(Period.End);

    [JsonIgnore]
    public int? PeakHour => Hourly.Length > 0 && Hourly.Max() > 0 ? Array.IndexOf(Hourly, Hourly.Max()) : null;

    private static IEnumerable<JsonNode> Rows(JsonNode? node) => node is JsonArray array ? array.OfType<JsonNode>() : node == null ? [] : [node];
    private static string Text(JsonNode? node) => node?.ToString() ?? "";

    // Tallies

    public sealed record Ranked(string Key, int Count, ScrobbledPlay Play);

    public static string ArtistKey(string artist) => artist.ToLowerInvariant();
    public static string AlbumKey(string artist, string album) => artist.ToLowerInvariant() + "\n" + album.ToLowerInvariant();
    public static string TrackKey(string artist, string title) => artist.ToLowerInvariant() + "\n" + title.ToLowerInvariant();

    public static List<Ranked> Rank(IEnumerable<ScrobbledPlay> plays, Func<ScrobbledPlay, string> key) =>
        plays.GroupBy(key).Select(g => new Ranked(g.Key, g.Count(), g.First())).OrderByDescending(r => r.Count).ToList();

    public static (List<Ranked> Artists, List<Ranked> Albums, List<Ranked> Tracks) Rankings(IReadOnlyList<ScrobbledPlay> plays) =>
        (Rank(plays, p => ArtistKey(p.Artist)),
         Rank(plays.Where(p => p.Album.Length > 0), p => AlbumKey(p.Artist, p.Album)),
         Rank(plays, p => TrackKey(p.Artist, p.Title)));

    public static ReportItem ArtistItem(Ranked e) => new(e.Play.Artist, "", e.Count, MusicPresentation.ArtistUrl(e.Play.Artist), []);
    public static ReportItem AlbumItem(Ranked e) => new(e.Play.Album, e.Play.Artist, e.Count, MusicPresentation.AlbumUrl(e.Play.Artist, e.Play.Album), e.Play.Images);
    public static ReportItem TrackItem(Ranked e) => new(e.Play.Title, e.Play.Artist, e.Count, MusicPresentation.TrackUrl(e.Play.Artist, e.Play.Title), e.Play.Images);

    public static int[] HourlyCounts(IEnumerable<ScrobbledPlay> plays)
    {
        var hours = new int[24];
        foreach (var play in plays) hours[play.Date.ToLocalTime().Hour]++;
        return hours;
    }

    public static int[] MonthlyCounts(IEnumerable<ScrobbledPlay> plays)
    {
        var months = new int[12];
        foreach (var play in plays) months[play.Date.ToLocalTime().Month - 1]++;
        return months;
    }

    /// The day or month with the most scrobbles (the earliest one on a tie) and its top artist, album and track.
    public static ReportHighlight? Busiest(IEnumerable<ScrobbledPlay> plays, bool byMonth)
    {
        var best = plays.GroupBy(p =>
            {
                var local = DateTime.SpecifyKind(p.Date.ToLocalTime().DateTime, DateTimeKind.Unspecified);
                return byMonth ? new DateTime(local.Year, local.Month, 1) : local.Date;
            })
            .OrderByDescending(g => g.Count()).ThenBy(g => g.Key).FirstOrDefault();
        if (best == null) return null;
        var (artists, albums, tracks) = Rankings(best.ToList());
        return new(best.Key, best.Count(), artists.Select(ArtistItem).FirstOrDefault(), albums.Select(AlbumItem).FirstOrDefault(), tracks.Select(TrackItem).FirstOrDefault());
    }

    private static readonly HashSet<string> IgnoredTags = ["seen live", "favorites", "favourites", "favorite", "favourite", "albums i own",
        "under 2000 listeners", "spotify", "my top artists", "all"];

    /// Combines the top artists' last.fm tags, weighted by how much each artist was played.
    public static List<ReportTag> CombineTags(IEnumerable<(int Plays, string Artist, IReadOnlyList<(string Name, long Count)> Tags)> artistTags, int limit = 5)
    {
        var entries = artistTags.ToList();
        var artistNames = entries.Select(e => e.Artist.ToLowerInvariant()).ToHashSet();
        var weights = new Dictionary<string, (string Name, double Weight)>();
        foreach (var entry in entries)
            foreach (var tag in entry.Tags.Take(10).Where(t => t.Count > 0))
            {
                var key = tag.Name.Trim().ToLowerInvariant();
                if (key.Length == 0 || IgnoredTags.Contains(key) || artistNames.Contains(key)) continue;
                var existing = weights.GetValueOrDefault(key, (tag.Name.ToLowerInvariant(), 0));
                weights[key] = (existing.Item1, existing.Item2 + entry.Plays * (double)tag.Count / 100);
            }
        var top = weights.Values.OrderByDescending(t => t.Weight).ThenBy(t => t.Name, StringComparer.Ordinal).Take(limit).ToList();
        if (top.Count == 0 || top[0].Weight <= 0) return [];
        return top.Select(t => new ReportTag(t.Name, t.Weight / top[0].Weight, MusicPresentation.TagUrl(t.Name))).ToList();
    }

    // Building

    public static async Task<ListeningReport> BuildAsync(Func<Dictionary<string, string>, Task<JsonNode>> request, string user, ReportPeriod period,
        Action<int, int>? progress = null, CancellationToken cancel = default, DateTimeOffset? now = null)
    {
        var builtAt = now ?? DateTimeOffset.Now;
        var start = new DateTimeOffset(period.Start);
        var end = new DateTimeOffset(period.End);
        var previous = await ScrobbleCountAsync(request, user, period.Previous);
        var plays = (await PlaysAsync(request, user, start, end < builtAt ? end : builtAt, progress, cancel))
            .Where(p => p.Date >= start && p.Date < end).ToList();
        var (artists, albums, tracks) = Rankings(plays);
        var report = new ListeningReport(period, plays.Count, previous,
            artists.Select(ArtistItem).FirstOrDefault(), albums.Select(AlbumItem).FirstOrDefault(), tracks.Select(TrackItem).FirstOrDefault(), builtAt)
        {
            Hourly = HourlyCounts(plays),
            BusiestDay = period.Kind == ReportKind.Week ? null : Busiest(plays, false),
            Monthly = period.Kind == ReportKind.Year ? MonthlyCounts(plays) : [],
            BusiestMonth = period.Kind == ReportKind.Year ? Busiest(plays, true) : null
        };
        if (plays.Count == 0) return report;
        var tags = await TopTagsAsync(request, artists.Take(10).ToList());

        // An item is new if all of the user's plays of it happened since the period started.
        var since = await ChartCountsAsync(request, user, start, builtAt);
        async Task<List<ReportItem>> New(List<Ranked> candidates, Dictionary<string, long> totals, Func<ScrobbledPlay, Dictionary<string, string>> query, Func<JsonNode, JsonNode?> userCount, Func<Ranked, ReportItem> item)
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
                        return total != null && total <= Math.Max(totals.GetValueOrDefault(candidate.Key), candidate.Count);
                    }
                    catch { return false; }
                }));
                result.AddRange(batch.Where((_, i) => checks[i]).Select(item));
            }
            return result;
        }
        return report with
        {
            TopTags = tags,
            NewArtists = await New(artists, since.Artists, p => new() { ["method"] = "artist.getInfo", ["artist"] = p.Artist }, j => j["artist"]?["stats"], ArtistItem),
            NewAlbums = await New(albums, since.Albums, p => new() { ["method"] = "album.getInfo", ["artist"] = p.Artist, ["album"] = p.Album }, j => j["album"], AlbumItem),
            NewTracks = await New(tracks, since.Tracks, p => new() { ["method"] = "track.getInfo", ["artist"] = p.Artist, ["track"] = p.Title }, j => j["track"], TrackItem)
        };
    }

    private static async Task<List<ReportTag>> TopTagsAsync(Func<Dictionary<string, string>, Task<JsonNode>> request, List<Ranked> artists)
    {
        var results = await Task.WhenAll(artists.Select(async entry =>
        {
            IReadOnlyList<(string, long)> tags = [];
            try
            {
                var json = await request(new() { ["method"] = "artist.getTopTags", ["artist"] = entry.Play.Artist });
                tags = Rows(json["toptags"]?["tag"])
                    .Select(row => (Text(row["name"]), MusicPresentation.Count(row["count"]) ?? 0)).Where(t => t.Item1.Length > 0).ToList();
            }
            catch { }
            return (entry.Count, entry.Play.Artist, tags);
        }));
        return CombineTags(results.OrderByDescending(r => r.Count));
    }

    /// Play counts from `start` until now, from last.fm's charts (each capped at 1,000 entries).
    private static async Task<(Dictionary<string, long> Artists, Dictionary<string, long> Albums, Dictionary<string, long> Tracks)> ChartCountsAsync(
        Func<Dictionary<string, string>, Task<JsonNode>> request, string user, DateTimeOffset start, DateTimeOffset now)
    {
        async Task<Dictionary<string, long>> Counts(string method, string root, string row, Func<JsonNode, string, string> key)
        {
            var counts = new Dictionary<string, long>();
            try
            {
                var json = await request(new() { ["method"] = method, ["user"] = user, ["from"] = start.ToUnixTimeSeconds().ToString(), ["to"] = now.ToUnixTimeSeconds().ToString() });
                foreach (var item in Rows(json[root]?[row]))
                {
                    var name = Text(item["name"]);
                    if (name.Length == 0 || MusicPresentation.Count(item["playcount"]) is not { } plays) continue;
                    var k = key(item, name);
                    counts[k] = counts.GetValueOrDefault(k) + plays;
                }
            }
            catch { }
            return counts;
        }
        static string ArtistName(JsonNode item) => Text(item["artist"]?["#text"]);
        return (await Counts("user.getWeeklyArtistChart", "weeklyartistchart", "artist", (_, name) => ArtistKey(name)),
                await Counts("user.getWeeklyAlbumChart", "weeklyalbumchart", "album", (item, name) => AlbumKey(ArtistName(item), name)),
                await Counts("user.getWeeklyTrackChart", "weeklytrackchart", "track", (item, name) => TrackKey(ArtistName(item), name)));
    }

    public static IEnumerable<ScrobbledPlay> ParsePlays(JsonNode? tracks)
    {
        foreach (var row in Rows(tracks))
        {
            var title = row["name"]?.ToString() ?? "";
            if (title.Length == 0 || MusicPresentation.Count(row["date"]?["uts"]) is not { } uts) continue;
            yield return new(title, row["artist"]?["#text"]?.ToString() ?? "", row["album"]?["#text"]?.ToString() ?? "",
                DateTimeOffset.FromUnixTimeSeconds(uts), MusicPresentation.ImageUrls(row["image"]).ToArray());
        }
    }

    /// Every scrobble between two dates. Pages are fetched a few at a time so long periods stay quick.
    public static async Task<List<ScrobbledPlay>> PlaysAsync(Func<Dictionary<string, string>, Task<JsonNode>> request, string user,
        DateTimeOffset from, DateTimeOffset to, Action<int, int>? progress = null, CancellationToken cancel = default)
    {
        async Task<(List<ScrobbledPlay> Plays, int TotalPages)> Page(int number)
        {
            var args = new Dictionary<string, string> { ["method"] = "user.getRecentTracks", ["user"] = user, ["limit"] = "200", ["page"] = number.ToString(),
                ["from"] = from.ToUnixTimeSeconds().ToString(), ["to"] = to.ToUnixTimeSeconds().ToString() };
            for (var attempt = 1; ; attempt++)
            {
                cancel.ThrowIfCancellationRequested();
                try
                {
                    var json = await request(args);
                    return (ParsePlays(json["recenttracks"]?["track"]).ToList(), (int)Math.Max(1, MusicPresentation.Count(json["recenttracks"]?["@attr"]?["totalPages"]) ?? 1));
                }
                // Retry rate limits and temporary failures a couple of times before giving up.
                catch (Exception e) when (attempt < 3 && (e is HttpRequestException or TaskCanceledException || e is LastFmException failure && RetriedErrors.Contains(failure.Code)))
                {
                    await Task.Delay(TimeSpan.FromSeconds(attempt), cancel);
                }
            }
        }
        var first = await Page(1);
        var total = first.TotalPages;
        var done = 1;
        progress?.Invoke(done, total);
        var pages = new List<ScrobbledPlay>[total];
        pages[0] = first.Plays;
        using var gate = new SemaphoreSlim(3, 3);
        await Task.WhenAll(Enumerable.Range(2, total - 1).Select(async number =>
        {
            await gate.WaitAsync(cancel);
            try { pages[number - 1] = (await Page(number)).Plays; }
            finally { gate.Release(); }
            progress?.Invoke(Interlocked.Increment(ref done), total);
        }));
        // New scrobbles can shift pages while they load, so drop any repeats.
        var seen = new HashSet<string>();
        return pages.SelectMany(p => p).Where(p => seen.Add($"{p.Date.ToUnixTimeSeconds()}\n{p.Artist}\n{p.Title}")).ToList();
    }

    private static async Task<long> ScrobbleCountAsync(Func<Dictionary<string, string>, Task<JsonNode>> request, string user, ReportPeriod period)
    {
        var json = await request(new() { ["method"] = "user.getRecentTracks", ["user"] = user, ["limit"] = "1",
            ["from"] = new DateTimeOffset(period.Start).ToUnixTimeSeconds().ToString(), ["to"] = (new DateTimeOffset(period.End).ToUnixTimeSeconds() - 1).ToString() });
        return MusicPresentation.Count(json["recenttracks"]?["@attr"]?["total"]) ?? 0;
    }
}

/// Keeps the four most recent weekly reports on disk, per last.fm account.
public static class ReportStore
{
    public const int KeptWeeks = 4;
    public static readonly string DefaultFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Scrap", "Reports");

    private static string Prefix(string username) =>
        new string(username.ToLowerInvariant().Where(c => char.IsLetterOrDigit(c) || c is '_' or '-').ToArray()) + "-week-";

    private static string FilePath(string folder, string username, ReportPeriod period) =>
        Path.Combine(folder, Prefix(username) + new DateTimeOffset(period.Start).ToUnixTimeSeconds() + ".json");

    private static DateTime Oldest(DateTime now) => ReportPeriod.Latest(ReportKind.Week, now).Start.AddDays(-7 * (KeptWeeks - 1));

    public static bool IsStored(ReportPeriod period, DateTime now) => period.Kind == ReportKind.Week && period.Start >= Oldest(now);

    public static ListeningReport? Load(ReportPeriod period, string username, DateTime now, string? folder = null)
    {
        var path = FilePath(folder ?? DefaultFolder, username, period);
        if (!IsStored(period, now) || !File.Exists(path)) return null;
        try { return JsonSerializer.Deserialize<ListeningReport>(File.ReadAllText(path)) is { } report && report.Period == period ? report : null; }
        catch { return null; }
    }

    public static void Save(ListeningReport report, string username, DateTime now, string? folder = null)
    {
        folder ??= DefaultFolder;
        if (!IsStored(report.Period, now)) return;
        Directory.CreateDirectory(folder);
        var path = FilePath(folder, username, report.Period);
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(report));
        File.Move(path + ".tmp", path, true);
        var prefix = Prefix(username);
        var oldest = new DateTimeOffset(Oldest(now)).ToUnixTimeSeconds();
        foreach (var file in Directory.GetFiles(folder, prefix + "*.json"))
            if (long.TryParse(Path.GetFileNameWithoutExtension(file)[prefix.Length..], out var stamp) && stamp < oldest)
                File.Delete(file);
    }
}
