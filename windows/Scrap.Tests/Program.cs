using Scrap;
using System.Text.Json.Nodes;

var start = DateTimeOffset.FromUnixTimeSeconds(1000);
var track = new PlayingTrack("A&B + C", "Artist", "Album", 60);
var passed = 0;
void Test(string name, Action action) { action(); Console.WriteLine("PASS " + name); passed++; }
void Equal<T>(T expected, T actual) { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new Exception($"Expected {expected}; got {actual}"); }

Test("Pauses do not count; repeat is a new submission", () =>
{
    var engine = new ScrobbleEngine();
    var submissions = new List<DateTimeOffset>();
    engine.Scrobble += (_, timestamp) => submissions.Add(timestamp);
    for (var i = 0; i <= 15; i++) engine.Update(track, true, start.AddSeconds(i));
    engine.Update(track, false, start.AddSeconds(16));
    engine.Update(track, true, start.AddSeconds(100));
    Equal(16d, engine.PlayedSeconds);
    for (var i = 101; i <= 114; i++) engine.Update(track, true, start.AddSeconds(i));
    Equal(1, submissions.Count); Equal(start, submissions[0]);
    engine.Update(track, true, start.AddSeconds(115), true);
    for (var i = 116; i <= 145; i++) engine.Update(track, true, start.AddSeconds(i));
    Equal(2, submissions.Count); Equal(start.AddSeconds(115), submissions[1]);
});
Test("Sleep, unknown duration, and short tracks never qualify", () =>
{
    var engine = new ScrobbleEngine(); var count = 0;
    engine.Scrobble += (_, _) => count++;
    engine.Update(track, true, start);
    engine.Update(track, true, start.AddSeconds(600));
    Equal(0d, engine.PlayedSeconds);
    for (var i = 601; i <= 660; i++) engine.Update(track with { Title = "Short", Duration = 30 }, true, start.AddSeconds(i));
    for (var i = 661; i <= 1200; i++) engine.Update(track with { Title = "Unknown", Duration = null }, true, start.AddSeconds(i));
    Equal(0, count);
});
Test("Now playing fires only once and only when playing", () =>
{
    var engine = new ScrobbleEngine(); var count = 0;
    engine.NowPlaying += _ => count++;
    engine.Update(track, false, start); Equal(0, count);
    engine.Update(track, true, start.AddSeconds(1));
    engine.Update(track, true, start.AddSeconds(2)); Equal(1, count);
});
Test("Disabling scrobbling excludes time immediately", () =>
{
    var engine = new ScrobbleEngine();
    engine.Update(track, true, start);
    engine.Update(track, true, start.AddSeconds(1));
    engine.Suspend();
    engine.Update(track, false, start.AddSeconds(2));
    engine.Update(track, true, start.AddSeconds(60));
    engine.Update(track, true, start.AddSeconds(61)); Equal(2d, engine.PlayedSeconds);
});
Test("Four-minute cap; duration changes do not reset listening", () =>
{
    var engine = new ScrobbleEngine(); var count = 0;
    engine.Scrobble += (_, _) => count++;
    for (var i = 0; i <= 300; i++) engine.Update(track with { Duration = 1000 + i % 2 }, true, start.AddSeconds(i));
    Equal(1, count);
});
Test("Switching tracks preserves timestamp; reset clears account state", () =>
{
    var engine = new ScrobbleEngine(); var count = 0;
    engine.Scrobble += (_, _) => count++;
    for (var i = 0; i < 30; i++) engine.Update(track, true, start.AddSeconds(i));
    engine.Update(track with { Title = "Next" }, true, start.AddSeconds(30));
    Equal(1, count); Equal(0d, engine.PlayedSeconds);
    engine.Reset(); Equal<PlayingTrack?>(null, engine.Track); Equal(false, engine.Submitted);
});
Test("Environment credentials support comments, quotes, whitespace, and equals", () =>
{
    var config = AppConfiguration.Parse("# ignored\r\n LASTFM_API_KEY = 'abc=123'\r\nLASTFM_SHARED_SECRET=\"secret\"\r\n");
    Equal("abc=123", config.ApiKey); Equal("secret", config.SharedSecret);
    Equal(new AppConfiguration("", ""), AppConfiguration.Parse("# no credentials\ninvalid"));
    Equal("", config.DiscordApplicationId);
    Equal("1234567890", AppConfiguration.Parse("DISCORD_APPLICATION_ID=1234567890").DiscordApplicationId);
});
Test("Apple Music separates artist and album before scrobbling", () =>
{
    var normalized = MediaMetadata.Normalize("AppleInc.AppleMusicWin!App", "Search & Rescue", "Drake — Search & Rescue - Single", "", 270);
    Equal("Drake", normalized.Artist); Equal("Search & Rescue - Single", normalized.Album); Equal("Search & Rescue", normalized.Title);
    var engine = new ScrobbleEngine(); PlayingTrack? submitted = null;
    engine.Scrobble += (song, _) => submitted = song;
    for (var i = 0; i <= 135; i++) engine.Update(normalized, true, start.AddSeconds(i));
    Equal(normalized, submitted);
});
Test("Metadata normalization preserves other players and explicit albums", () =>
{
    Equal("Drake — Album", MediaMetadata.Normalize("Spotify", "Song", "Drake — Album", "", 60).Artist);
    Equal("Artist — Name", MediaMetadata.Normalize("AppleMusic", "Song", "Artist — Name — Album", "Album", 60).Artist);
    Equal("Artist — Name", MediaMetadata.Normalize("AppleMusic", "Song", "Artist — Name", "Different album", 60).Artist);
    Equal("AC/DC", MediaMetadata.Normalize("AppleMusic", "Song", "AC/DC", "Album", 60).Artist);
});
Test("Biography and artwork parsing reject unsafe or placeholder images", () =>
{
    Equal("A & B.", MusicPresentation.Biography("A &amp; B. <a href='https://last.fm'>Read more</a>"));
    var rows = System.Text.Json.Nodes.JsonNode.Parse("[{\"#text\":\"https://example.com/cover.jpg\"},{\"#text\":\"https://example.com/2a96cbd8b46e442fc41c2b86b821562f.png\"},{\"#text\":\"file:///private\"}]");
    Equal("https://example.com/cover.jpg", MusicPresentation.ImageUrl(rows)?.AbsoluteUri);
});
Test("Listening summary distinguishes zero from missing counts", () =>
{
    var song = new PlayingTrack("Search & Rescue", "Drake", "Album", 60);
    Equal("You've scrobbled Drake 12 times and Search & Rescue 3 times.", MusicPresentation.ListeningSummary(song, 12, 3));
    Equal("You've never scrobbled Drake before.", MusicPresentation.ListeningSummary(song, 0, 0));
    Equal("You've scrobbled Drake 12 times, but not this track.", MusicPresentation.ListeningSummary(song, 12, 0));
    Equal("Listening history unavailable.", MusicPresentation.ListeningSummary(song, null, 3));
});
Test("Last.fm links preserve special characters and chart destination types", () =>
{
    Equal("https://www.last.fm/music/AC%2FDC/_/A%26B%20%2B%20C", MusicPresentation.TrackUrl("AC/DC", "A&B + C").AbsoluteUri);
    var row = System.Text.Json.Nodes.JsonNode.Parse("{\"name\":\"Album\",\"artist\":{\"name\":\"Drake\"}}")!;
    Equal("https://www.last.fm/music/Drake/Album", MusicPresentation.ChartUrl("albums", row).AbsoluteUri);
    Equal("https://www.last.fm/music/Drake/_/Album", MusicPresentation.ChartUrl("tracks", row).AbsoluteUri);
    Equal("https://www.last.fm/user/friend", MusicPresentation.UserUrl("friend").AbsoluteUri);
});
Test("Loved status accepts Last.fm values and fails closed when missing", () =>
{
    Equal(true, TrackLove.Parse(System.Text.Json.Nodes.JsonNode.Parse("{\"track\":{\"userloved\":\"1\"}}")!));
    Equal(false, TrackLove.Parse(System.Text.Json.Nodes.JsonNode.Parse("{\"track\":{\"userloved\":0}}")!));
    try { TrackLove.Parse(System.Text.Json.Nodes.JsonNode.Parse("{\"track\":{}}")!); throw new Exception("Missing status was accepted"); }
    catch (InvalidOperationException) { }
});
Test("Tray toggle rechecks current love state before choosing love or unlove", () =>
{
    foreach (var loved in new[] { false, true })
    {
        var read = false; bool? written = null;
        TrackLove.ToggleAsync(() => { read = true; return Task.FromResult(loved); }, value => { Equal(true, read); written = value; return Task.CompletedTask; }).GetAwaiter().GetResult();
        Equal<bool?>(!loved, written);
    }
    var writes = 0;
    try { TrackLove.ToggleAsync(() => Task.FromException<bool>(new InvalidOperationException("Offline")), _ => { writes++; return Task.CompletedTask; }).GetAwaiter().GetResult(); }
    catch (InvalidOperationException) { }
    Equal(0, writes);
});
Test("Startup setting persists a quoted executable and removes it when disabled", () =>
{
    string? saved = null;
    var setting = new StartupSetting(() => saved, value => saved = value, @"C:\My Apps\Scrap\Scrap.exe");
    Equal(false, setting.Enabled);
    setting.SetEnabled(true);
    Equal("\"C:\\My Apps\\Scrap\\Scrap.exe\"", saved);
    Equal(true, new StartupSetting(() => saved, value => saved = value, @"C:\My Apps\Scrap\Scrap.exe").Enabled);
    setting.SetEnabled(false); Equal<string?>(null, saved); Equal(false, setting.Enabled);
});
Test("Startup rejects invalid paths and does not mask a failed save", () =>
{
    foreach (var path in new[] { "", "bad\"path.exe", "bad\npath.exe", new string('x', 261) })
    {
        var writes = 0;
        var setting = new StartupSetting(() => null, _ => writes++, path);
        try { setting.SetEnabled(true); throw new Exception("Invalid path was accepted"); }
        catch (InvalidOperationException) { }
        Equal(0, writes);
    }
    var denied = new StartupSetting(() => null, _ => throw new UnauthorizedAccessException(), @"C:\Scrap\Scrap.exe");
    try { denied.SetEnabled(true); throw new Exception("Write failure was hidden"); }
    catch (UnauthorizedAccessException) { }
    Equal(false, denied.Enabled);
});
Test("Apple Music Edition cleanup requires both settings and only removes a suffix", () =>
{
    foreach (var parent in new[] { false, true })
    foreach (var edition in new[] { false, true })
    {
        var settings = new MetadataCleanup(RemoveAlbumSuffixes: parent, RemoveAppleMusicEdition: edition);
        var original = track with { Album = "Pink Heartz (Apple Music Edition)" };
        Equal(parent && edition ? "Pink Heartz" : original.Album, settings.Apply(original, "AppleMusic").Album);
        Equal(original.Album, settings.Apply(original, "Spotify").Album);
        Equal("Album (Apple Music Edition) Deluxe", settings.Apply(track with { Album = "Album (Apple Music Edition) Deluxe" }, "AppleMusic").Album);
    }
    var both = new MetadataCleanup(RemoveAlbumSuffixes: true, RemoveAppleMusicEdition: true);
    Equal("Album", both.Apply(track with { Album = "Album - EP (Apple Music Edition)" }, "AppleMusic").Album);
    Equal("Pink Heartz (Apple Music Edition)", MetadataCleanup.Defaults.Apply(track with { Album = "Pink Heartz (Apple Music Edition)" }, "AppleMusic").Album);
});
Test("Artwork candidates preserve preferred order and remove duplicates", () =>
{
    var rows = System.Text.Json.Nodes.JsonNode.Parse("""[{"#text":"https://example.com/small"},{"#text":"https://example.com/large"},{"#text":"https://example.com/large"},{"#text":"http://example.com/insecure"}]""");
    Equal("https://example.com/large,https://example.com/small", string.Join(",", MusicPresentation.ImageUrls(rows)));
});
Test("Updater accepts old and compatible Windows release tags", () =>
{
    foreach (var tag in new[] { "v1.1-windows", "windows-v1.1", "windows-1.1", "v1.1" })
        Equal(new Version(1, 1), UpdateRelease.ParseVersion(tag));
    Equal<Version?>(null, UpdateRelease.ParseVersion("nonsense"));
});
Test("Updater ignores drafts, prereleases, and releases without a Windows ZIP and selects newest Windows", () =>
{
    var win = """[{"name":"scrap-windows.zip"}]""";
    var releases = System.Text.Json.Nodes.JsonNode.Parse($$$"""[{"tag_name":"v1.1-windows","assets":{{{win}}}},{"tag_name":"v1.7","target_commitish":"main","assets":[{"name":"scrap.dmg"},{"name":"scrap-1.7.0-windows.zip"}]},{"tag_name":"v9.0","assets":[{"name":"scrap.dmg"},{"name":"windows-notes.txt"},{"name":"scrap-windows-x64.zip.sha256"}]},{"tag_name":"windows-v9.0","draft":true,"assets":{{{win}}}},{"tag_name":"windows-v8.0","prerelease":true,"assets":{{{win}}}}]""")!.AsArray();
    var latest = UpdateRelease.Latest(releases);
    Equal("v1.7", latest?["tag_name"]?.ToString());
    Equal("scrap-1.7.0-windows.zip", UpdateRelease.WindowsAsset(latest)?["name"]?.ToString());
    Equal<System.Text.Json.Nodes.JsonNode?>(null, UpdateRelease.WindowsAsset(System.Text.Json.Nodes.JsonNode.Parse("""{"assets":[{"name":"Scrap-Windows-v1.1.0-x64.zip"}]}""")));
});
Test("Updater verifies archive bytes and rejects malformed or changed digests", () =>
{
    var bytes = System.Text.Encoding.UTF8.GetBytes("release");
    var hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes));
    Equal(true, UpdateRelease.Verify(bytes, "sha256:" + hash));
    Equal(false, UpdateRelease.Verify([1, 2, 3], "sha256:" + hash));
    foreach (var digest in new[] { "", "sha256:xyz", "sha256:" + new string('z', 64), "sha512:" + hash }) Equal(false, UpdateRelease.Verify(bytes, digest));
});
Test("Updater installs and preserves credentials, and rolls back if launch fails", () =>
{
    foreach (var failLaunch in new[] { false, true })
    {
        var root = Path.Combine(Path.GetTempPath(), "Scrap-update-test-" + Guid.NewGuid().ToString("N"));
        var install = Path.Combine(root, "installed app's folder");
        var stage = Path.Combine(root, "stage");
        Directory.CreateDirectory(install); Directory.CreateDirectory(stage);
        File.WriteAllText(Path.Combine(install, "Scrap.exe"), "old");
        File.WriteAllText(Path.Combine(install, ".env"), "existing credentials");
        File.WriteAllText(Path.Combine(stage, "Scrap.exe"), "new");
        var archive = Path.Combine(root, "update.zip"); File.WriteAllText(archive, "fixture");
        var script = Path.Combine(root, "install.ps1");
        var stub = "function Start-Process { param($FilePath, $ArgumentList) if (-not (Test-Path -LiteralPath $FilePath)) { throw 'Missing app' }; ";
        if (failLaunch) stub += "if ([IO.File]::ReadAllText($FilePath) -eq 'new') { throw 'Simulated launch failure' }; ";
        stub += "}\n";
        File.WriteAllText(script, stub + UpdateInstaller.Script(install, stage, stage, archive, int.MaxValue, true));
        var info = new System.Diagnostics.ProcessStartInfo("powershell.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var arg in new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script }) info.ArgumentList.Add(arg);
        using var process = System.Diagnostics.Process.Start(info)!;
        var output = process.StandardOutput.ReadToEnd(); var error = process.StandardError.ReadToEnd();
        process.WaitForExit();
        if (failLaunch) Equal(true, process.ExitCode != 0);
        else if (process.ExitCode != 0) throw new Exception(output + error);
        Equal(failLaunch ? "old" : "new", File.ReadAllText(Path.Combine(install, "Scrap.exe")));
        Equal("existing credentials", File.ReadAllText(Path.Combine(install, ".env")));
        Equal(failLaunch, File.Exists(archive));
        if (!root.StartsWith(Path.Combine(Path.GetTempPath(), "Scrap-update-test-"), StringComparison.OrdinalIgnoreCase)) throw new Exception("Invalid test path");
        Directory.Delete(root, true);
    }
});
Test("Featured artists can be removed from titles", () =>
{
    Equal("Wants and Needs", MetadataCleanup.RemovingFeaturedArtists("Wants and Needs (feat. Lil Baby)"));
    Equal("Rich Flex", MetadataCleanup.RemovingFeaturedArtists("Rich Flex (with 21 Savage)"));
    Equal("Song (Remix)", MetadataCleanup.RemovingFeaturedArtists("Song [Ft. Someone] (Remix)"));
    Equal("Without Me", MetadataCleanup.RemovingFeaturedArtists("Without Me"));
    Equal("(with you)", MetadataCleanup.RemovingFeaturedArtists("(with you)"));
    var song = new PlayingTrack("Laugh Now Cry Later (feat. Lil Durk)", "Drake", "", null);
    Equal(song.Title, MetadataCleanup.Defaults.Apply(song, "AppleMusic").Title);
    var cleaned = new MetadataCleanup(RemoveFeaturedArtists: true).Apply(song, "Spotify");
    Equal("Laugh Now Cry Later", cleaned.Title); Equal(song.Title, cleaned.OriginalTitle);
});
Test("Weekly reports run Saturday to Friday and switch over on Friday", () =>
{
    ReportPeriod Week(DateTime start) => new(ReportKind.Week, start, start.AddDays(7));
    Equal(Week(new DateTime(2026, 10, 10)), ReportPeriod.Latest(ReportKind.Week, new DateTime(2026, 10, 22, 23, 59, 0)));
    Equal(Week(new DateTime(2026, 10, 17)), ReportPeriod.Latest(ReportKind.Week, new DateTime(2026, 10, 23)));
    Equal(Week(new DateTime(2026, 10, 17)), ReportPeriod.Latest(ReportKind.Week, new DateTime(2026, 10, 24, 9, 0, 0)));
    Equal(new DateTimeOffset(new DateTime(2026, 10, 30)), ReportPeriod.Latest(ReportKind.Week, new DateTime(2026, 10, 24, 9, 0, 0)).Next.ReleaseDate);
});
Test("Periods cover weeks, months and years", () =>
{
    var week = ReportPeriod.Containing(new DateTime(2026, 11, 11, 12, 0, 0), ReportKind.Week);
    Equal(DayOfWeek.Saturday, week.Start.DayOfWeek);
    Equal(new DateTime(2026, 11, 7), week.Start); Equal(new DateTime(2026, 11, 13), week.LastDay);
    var month = ReportPeriod.Containing(new DateTime(2026, 11, 11, 12, 0, 0), ReportKind.Month);
    Equal(new DateTime(2026, 11, 1), month.Start); Equal(new DateTime(2026, 12, 1), month.End);
    Equal(new DateTime(2026, 10, 1), month.Previous.Start); Equal(new DateTime(2026, 12, 1), month.Next.Start);
    var year = ReportPeriod.Containing(new DateTime(2026, 3, 1), ReportKind.Year);
    Equal(new DateTime(2026, 1, 1), year.Start); Equal("2026", year.Title(new DateTime(2026, 11, 11)));
    Equal(new DateTime(2025, 1, 1), year.Previous.Start);
});
Test("Monthly and yearly reports come out on the first Friday after", () =>
{
    var october = ReportPeriod.Containing(new DateTime(2026, 10, 15), ReportKind.Month);
    Equal(DateTimeOffset.Parse("2026-11-06T15:00:00Z"), october.ReleaseDate);
    // November 11, 2026: October's report (out Friday, November 6) is the latest; November's isn't out yet.
    Equal(october, ReportPeriod.Latest(ReportKind.Month, new DateTime(2026, 11, 11, 12, 0, 0)));
    Equal(new DateTime(2026, 9, 1), ReportPeriod.Latest(ReportKind.Month, new DateTime(2026, 11, 2, 12, 0, 0)).Start);
    Equal(new DateTime(2025, 1, 1), ReportPeriod.Latest(ReportKind.Year, new DateTime(2026, 11, 11, 12, 0, 0)).Start);
    Equal(new DateTime(2026, 10, 31), ReportPeriod.Latest(ReportKind.Week, new DateTime(2026, 11, 11, 12, 0, 0)).Start);
    Equal(new DateTime(2026, 11, 7), ReportPeriod.Latest(ReportKind.Week, new DateTime(2026, 11, 13, 12, 0, 0)).Start);
});
Test("Report tallies rank by plays then first played, and find the busiest day and month", () =>
{
    ScrobbledPlay Play(string title, string artist, string album, DateTime at) => new(title, artist, album, new DateTimeOffset(at), []);
    var plays = new List<ScrobbledPlay>
    {
        Play("A", "Yeat", "2093", new DateTime(2026, 1, 3, 9, 0, 0)),
        Play("B", "Drake", "For All The Dogs", new DateTime(2026, 1, 3, 22, 0, 0)),
        Play("A", "yeat", "2093", new DateTime(2026, 1, 4, 22, 0, 0)),
        Play("C", "Drake", "", new DateTime(2026, 2, 10, 22, 0, 0)),
    };
    var (artists, albums, tracks) = ListeningReport.Rankings(plays);
    Equal("2,2", string.Join(",", artists.Select(a => a.Count)));
    Equal("Yeat", artists[0].Play.Artist);
    Equal("2093", albums[0].Play.Album); Equal(2, albums.Count);
    Equal(2, tracks[0].Count);
    var hours = ListeningReport.HourlyCounts(plays);
    Equal(24, hours.Length); Equal(3, hours[22]); Equal(1, hours[9]);
    var months = ListeningReport.MonthlyCounts(plays);
    Equal(3, months[0]); Equal(1, months[1]);
    var day = ListeningReport.Busiest(plays, false);
    Equal<DateTime?>(new DateTime(2026, 1, 3), day?.Start); Equal<int?>(2, day?.Scrobbles);
    var month = ListeningReport.Busiest(plays, true);
    Equal<DateTime?>(new DateTime(2026, 1, 1), month?.Start);
    Equal("Yeat", month?.TopArtist?.Name); Equal("A", month?.TopTrack?.Name); Equal("2093", month?.TopAlbum?.Name);
    Equal<ReportHighlight?>(null, ListeningReport.Busiest([], false));
});
Test("Top tags are weighted by plays and skip noise", () =>
{
    var tags = ListeningReport.CombineTags([
        (10, "Yeat", [("trap", 100), ("rage", 40), ("seen live", 90), ("Yeat", 50)]),
        (5, "Drake", [("rap", 100), ("Trap", 20)]),
    ]);
    Equal("trap,rap,rage", string.Join(",", tags.Select(t => t.Name)));
    Equal(1d, tags[0].Weight);
    Equal("https://www.last.fm/tag/trap", tags[0].Url.AbsoluteUri);
    Equal(0, ListeningReport.CombineTags([]).Count);
});
Test("Reports round-trip and only the last four weeks are stored", () =>
{
    var now = new DateTime(2026, 11, 11, 12, 0, 0);
    var latest = ReportPeriod.Latest(ReportKind.Week, now);
    Equal(true, ReportStore.IsStored(latest, now));
    var period = latest;
    for (var i = 0; i < 3; i++) period = period.Previous;
    Equal(true, ReportStore.IsStored(period, now));
    Equal(false, ReportStore.IsStored(period.Previous, now));
    Equal(false, ReportStore.IsStored(ReportPeriod.Latest(ReportKind.Month, now), now));

    var folder = Path.Combine(Path.GetTempPath(), "Scrap-report-test-" + Guid.NewGuid().ToString("N"));
    try
    {
        var item = new ReportItem("Yeat", "", 3, MusicPresentation.ArtistUrl("Yeat"), []);
        var report = new ListeningReport(latest, 3, 1, item, null, null, new DateTimeOffset(latest.End)) { Hourly = new int[24], TopTags = [new("rage", 1, MusicPresentation.TagUrl("rage"))] };
        ReportStore.Save(report, "Me", now, folder);
        var decoded = ReportStore.Load(latest, "me", now, folder);
        Equal(latest, decoded?.Period); Equal("Yeat", decoded?.TopArtist?.Name); Equal<bool?>(true, decoded?.IsFinal);
        Equal("rage", decoded?.TopTags.FirstOrDefault()?.Name); Equal<int?>(24, decoded?.Hourly.Length);
        Equal<ListeningReport?>(null, ReportStore.Load(latest, "someone else", now, folder));
        // A week falls out of storage once four newer weeks are out.
        ReportStore.Save(report with { Period = period, BuiltAt = new DateTimeOffset(period.End) }, "me", now, folder);
        Equal(2, Directory.GetFiles(folder).Length);
        ReportStore.Save(report, "me", now.AddDays(7), folder);
        Equal(1, Directory.GetFiles(folder).Length);
    }
    finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
});
Test("Report notifications follow Friday 16:00 Zurich time across daylight saving", () =>
{
    Equal(DateTimeOffset.Parse("2026-10-23T14:00:00Z"), ReportSchedule.Latest(DateTimeOffset.Parse("2026-10-23T14:00:00Z")));
    Equal(DateTimeOffset.Parse("2026-10-16T14:00:00Z"), ReportSchedule.Latest(DateTimeOffset.Parse("2026-10-23T13:59:00Z")));
    Equal(DateTimeOffset.Parse("2026-10-30T15:00:00Z"), ReportSchedule.Next(DateTimeOffset.Parse("2026-10-23T14:00:00Z")));
    var utc = ReportSchedule.Description(DateTimeOffset.Parse("2026-10-31T00:00:00Z"), TimeZoneInfo.Utc);
    if (!utc.StartsWith("Weekly reports every Friday at 16:00 Central European Time, which is ") || !utc.Contains("15") || !utc.Contains("first Friday after the month or year ends")) throw new Exception(utc);
});
Test("Friend activity shows now playing, relative time, or nothing", () =>
{
    var now = DateTimeOffset.FromUnixTimeSeconds(1_000_000);
    JsonNode Track(string json) => JsonNode.Parse(json)!;
    Equal("Song · Drake\nNow playing", MusicPresentation.FriendActivity(Track("""{"name":"Song","artist":{"#text":"Drake"},"@attr":{"nowplaying":"true"}}"""), now));
    Equal("Song · Drake\n3 hours ago", MusicPresentation.FriendActivity(Track("""{"name":"Song","artist":{"#text":"Drake"},"date":{"uts":"989200"}}"""), now));
    Equal("No recent listening available", MusicPresentation.FriendActivity(null, now));
    Equal("just now", MusicPresentation.Relative(now.AddSeconds(-30), now));
    Equal("1 minute ago", MusicPresentation.Relative(now.AddMinutes(-1), now));
    Equal("yesterday", MusicPresentation.Relative(now.AddHours(-30), now));
    Equal("2 weeks ago", MusicPresentation.Relative(now.AddDays(-15), now));
});
Test("Weekly report totals the week and finds first plays using chart totals", () =>
{
    var start = new DateTime(2026, 10, 10);
    var period = new ReportPeriod(ReportKind.Week, start, start.AddDays(7));
    long At(int day) => new DateTimeOffset(start.AddDays(day).AddHours(12)).ToUnixTimeSeconds();
    string Play(string title, string artist, string album, int day) => $$$$"""{"name":"{{{{title}}}}","artist":{"#text":"{{{{artist}}}}"},"album":{"#text":"{{{{album}}}}"},"date":{"uts":"{{{{At(day)}}}}"}}""";
    var tracks = string.Join(",", Play("Song1", "A", "X", 0), Play("Song1", "A", "X", 1), Play("Song1", "A", "X", 2), Play("Song2", "B", "Y", 3), Play("Later", "C", "Z", 8),
        """{"name":"Live","artist":{"#text":"A"},"@attr":{"nowplaying":"true"}}""");
    var counts = new Dictionary<string, string> { ["A"] = "10", ["B"] = "1", ["C"] = "1", ["X"] = "3", ["Y"] = "5", ["Song1"] = "3", ["Song2"] = "7" };
    var progress = new List<string>();
    var report = ListeningReport.BuildAsync(args =>
    {
        if (args["method"].EndsWith(".getInfo") && args.GetValueOrDefault("username") != "me") throw new Exception("Missing username");
        return Task.FromResult(JsonNode.Parse(args["method"] switch
        {
            "user.getRecentTracks" when args["limit"] == "1" => """{"recenttracks":{"@attr":{"total":"2"}}}""",
            "user.getRecentTracks" => $$$$"""{"recenttracks":{"@attr":{"totalPages":"1"},"track":[{{{{tracks}}}}]}}""",
            // The chart says A was played 10 times since the week started, so A's earlier plays don't exist and A is new.
            "user.getWeeklyArtistChart" => """{"weeklyartistchart":{"artist":[{"name":"A","playcount":"10"}]}}""",
            "user.getWeeklyAlbumChart" => """{"weeklyalbumchart":{"album":{"name":"X","artist":{"#text":"A"},"playcount":"3"}}}""",
            "user.getWeeklyTrackChart" => """{"weeklytrackchart":{"track":[]}}""",
            "artist.getTopTags" => args["artist"] == "A" ? """{"toptags":{"tag":[{"name":"rage","count":"100"}]}}""" : """{"toptags":{}}""",
            "artist.getInfo" => $$$$"""{"artist":{"stats":{"userplaycount":"{{{{counts[args["artist"]]}}}}"}}}""",
            "album.getInfo" => $$$$"""{"album":{"userplaycount":"{{{{counts[args["album"]]}}}}"}}""",
            _ => $$$$"""{"track":{"userplaycount":"{{{{counts[args["track"]]}}}}"}}"""
        })!);
    }, "me", period, (done, total) => progress.Add($"{done}/{total}"), now: new DateTimeOffset(start.AddDays(9))).GetAwaiter().GetResult();
    Equal(4, report.Scrobbles); Equal(2L, report.PreviousScrobbles);
    Equal("A", report.TopArtist?.Name); Equal<long?>(3, report.TopArtist?.Count);
    Equal("X", report.TopAlbum?.Name); Equal("Song1", report.TopTrack?.Name);
    Equal("A,B", string.Join(",", report.NewArtists.Select(i => i.Name)));
    Equal("X", string.Join(",", report.NewAlbums.Select(i => i.Name)));
    Equal("Song1", string.Join(",", report.NewTracks.Select(i => i.Name)));
    Equal("rage", string.Join(",", report.TopTags.Select(t => t.Name)));
    Equal(4, report.Hourly[12]); Equal<int?>(12, report.PeakHour);
    Equal<ReportHighlight?>(null, report.BusiestDay); Equal(0, report.Monthly.Length);
    Equal(true, report.IsFinal); Equal("1/1", string.Join(",", progress));
});
Test("Scrobble pages load in parallel, retry rate limits and drop repeats", () =>
{
    var calls = new Dictionary<string, int>();
    var plays = ListeningReport.PlaysAsync(args =>
    {
        var page = args["page"];
        lock (calls) calls[page] = calls.GetValueOrDefault(page) + 1;
        if (page == "2" && calls[page] == 1) throw new LastFmException(29, "Rate limit exceeded");
        // Page 3 repeats page 1's scrobble, as happens when a new scrobble shifts the pages.
        var (title, uts) = page == "2" ? ("S2", 298) : ("S1", 299);
        return Task.FromResult(JsonNode.Parse($$$"""{"recenttracks":{"@attr":{"totalPages":"3"},"track":[{"name":"{{{title}}}","artist":{"#text":"A"},"date":{"uts":"{{{uts}}}"}}]}}""")!);
    }, "me", DateTimeOffset.FromUnixTimeSeconds(0), DateTimeOffset.FromUnixTimeSeconds(1000)).GetAwaiter().GetResult();
    Equal("S1,S2", string.Join(",", plays.Select(p => p.Title)));
    Equal(2, calls["2"]);
    var failures = 0;
    try
    {
        ListeningReport.PlaysAsync(_ => { failures++; throw new LastFmException(6, "User not found"); }, "me", DateTimeOffset.FromUnixTimeSeconds(0), DateTimeOffset.FromUnixTimeSeconds(1)).GetAwaiter().GetResult();
        throw new Exception("Error was hidden");
    }
    catch (LastFmException) { }
    Equal(1, failures);
});
Test("Profile charts use the chosen period and fetch track covers only for short charts", () =>
{
    Equal("7day", ChartPeriod.From(null).Key); Equal("overall", ChartPeriod.From("overall").Key);
    var lookups = 0; string? period = null;
    Task<JsonNode> Fake(Dictionary<string, string> args)
    {
        if (args["method"] == "track.getInfo") { lookups++; return Task.FromResult(JsonNode.Parse("""{"track":{"album":{"image":[{"#text":"https://example.com/cover.jpg"}]}}}""")!); }
        period = args["period"];
        return Task.FromResult(JsonNode.Parse("""{"toptracks":{"track":[{"name":"T","artist":{"name":"Drake"},"playcount":"9","image":[]},{"name":"T","artist":{"name":"Drake"},"playcount":"9"}]}}""")!);
    }
    var five = ProfileCharts.LoadAsync(Fake, "me", "tracks", ChartPeriod.From("1month")).GetAwaiter().GetResult();
    Equal("1month", period); Equal(1, five.Count); Equal(9L, five[0].Count);
    Equal("https://example.com/cover.jpg", five[0].Images.FirstOrDefault()?.AbsoluteUri);
    var fifty = ProfileCharts.LoadAsync(Fake, "me", "tracks", ChartPeriod.From("1month"), 50).GetAwaiter().GetResult();
    Equal(1, lookups); Equal(0, fifty[0].Images.Length);
});
var song = new PlayingTrack("Wants and Needs", "Drake", "Scary Hours 2", 192);
DiscordTrackInfo SongInfo(string? album = null, Uri? songLink = null, bool noSongLink = false) =>
    new(album == null ? song : song with { Album = album }, "Apple Music", new Uri("https://lastfm.freetls.fastly.net/i/u/300x300/a.png"),
        noSongLink ? null : songLink ?? new Uri("https://song.link/i/123"));
Test("Discord frames round-trip and wait for complete data", () =>
{
    var data = DiscordIpcConnection.Encode(DiscordIpcConnection.Opcode.Frame, new JsonObject { ["cmd"] = "SET_ACTIVITY", ["nonce"] = "1" });
    Equal("1,0,0,0", string.Join(",", data.Take(4)));
    Equal(data.Length - 8, data[4] | data[5] << 8);
    var buffer = new List<byte>(data);
    buffer.AddRange(data.Take(5));
    var frames = DiscordIpcConnection.DecodeFrames(buffer);
    Equal(1, frames.Count); Equal(1u, frames[0].Opcode); Equal("SET_ACTIVITY", frames[0].Payload["cmd"]?.ToString());
    Equal(5, buffer.Count);
    buffer.AddRange(data.Skip(5));
    Equal(1, DiscordIpcConnection.DecodeFrames(buffer).Count);
    Equal(0, buffer.Count);
});
Test("Discord templates fill tokens and hide lines with missing values", () =>
{
    Equal("by Drake", DiscordActivity.Format("by {artist}", SongInfo()));
    Equal("Wants and Needs on Apple Music", DiscordActivity.Format("{title} on {service}", SongInfo()));
    Equal("", DiscordActivity.Format("on {album}", SongInfo(album: "")));
    var activity = DiscordActivity.Build(SongInfo(album: ""), new DiscordPresenceSettings { AlbumFormat = "on {album}" }, true, null);
    Equal<string?>(null, activity?.AlbumText);
    Equal<Uri?>(null, activity?.AlbumUrl);
});
Test("Discord payload uses the listening type, timestamps and buttons", () =>
{
    var activity = DiscordActivity.Build(SongInfo(), new DiscordPresenceSettings(), true, DateTimeOffset.FromUnixTimeSeconds(1000))!;
    var payload = activity.Payload();
    Equal("2", payload["type"]?.ToString());
    Equal("1", payload["status_display_type"]?.ToString());
    Equal("Wants and Needs", payload["details"]?.ToString());
    Equal("Drake", payload["state"]?.ToString());
    Equal("1000000", payload["timestamps"]?["start"]?.ToString());
    Equal("1192000", payload["timestamps"]?["end"]?.ToString());
    Equal("Scary Hours 2", payload["assets"]?["large_text"]?.ToString());
    Equal("https://www.last.fm/music/Drake/Scary%20Hours%202", payload["assets"]?["large_url"]?.ToString());
    var buttons = payload["buttons"]!.AsArray();
    Equal("Listen on song.link,View on last.fm", string.Join(",", buttons.Select(b => b?["label"]?.ToString())));
    Equal("https://song.link/i/123", buttons[0]?["url"]?.ToString());
    Equal("Drake", activity.StatusText("scrap"));
});
Test("Discord paused behaviour and optional pieces", () =>
{
    Equal<DiscordActivity?>(null, DiscordActivity.Build(SongInfo(), new DiscordPresenceSettings(), false, DateTimeOffset.Now));
    var settings = new DiscordPresenceSettings { ShowCover = false, Paused = DiscordPausedBehavior.Keep, StatusSource = DiscordStatusSource.Details };
    var paused = DiscordActivity.Build(SongInfo(), settings, false, DateTimeOffset.Now);
    Equal<DateTimeOffset?>(null, paused?.Start);
    Equal<Uri?>(null, paused?.CoverUrl);
    Equal("Wants and Needs", paused?.StatusText("scrap"));
    Equal<DiscordStatusSource?>(DiscordStatusSource.State, DiscordActivity.Build(SongInfo(), settings with { DetailsFormat = "" }, false, null)?.StatusSource);
    var noLinks = DiscordActivity.Build(SongInfo(), new DiscordPresenceSettings { LinkNames = false, ShowTimestamps = false }, true, DateTimeOffset.Now)!.Payload();
    Equal<JsonNode?>(null, noLinks["details_url"]); Equal<JsonNode?>(null, noLinks["timestamps"]);
});
Test("Discord buttons fall back, skip duplicates and clamp labels", () =>
{
    var settings = new DiscordPresenceSettings { Button1 = DiscordButtonKind.SongLink, Button1Label = new string('x', 40), Button2 = DiscordButtonKind.LastFmTrack };
    var buttons = DiscordActivity.Build(SongInfo(noSongLink: true), settings, true, null)?.Buttons ?? [];
    Equal(1, buttons.Count);
    Equal(MusicPresentation.TrackUrl("Drake", "Wants and Needs"), buttons[0].Url);
    Equal(32, buttons[0].Label.Length);
    Equal(2, DiscordActivity.Clamp("a", 128).Length);
    Equal(128, DiscordActivity.Clamp(new string('y', 200), 128).Length);
    Equal(0, (DiscordActivity.Build(SongInfo(), settings with { Button1 = DiscordButtonKind.None, Button2 = DiscordButtonKind.None }, true, null)?.Buttons ?? []).Count);
});
Test("Discord links come from Apple's catalog, Spotify search and the image proxy", () =>
{
    var results = JsonNode.Parse("""
        [{"trackId":1,"trackName":"Wants and Needs","artistName":"Someone Else","collectionName":"Scary Hours 2"},
         {"trackId":2,"trackName":"Wants and Needs (feat. Lil Baby)","artistName":"Drake","collectionName":"Certified Lover Boy"},
         {"trackId":3,"trackName":"Wants and Needs (feat. Lil Baby)","artistName":"Drake","collectionName":"Scary Hours 2 - EP"}]
        """)!.AsArray();
    Equal("3", DiscordLinks.BestITunesMatch(results, song)?["trackId"]?.ToString());
    Equal<JsonNode?>(null, DiscordLinks.BestITunesMatch(new JsonArray(JsonNode.Parse(results[0]!.ToJsonString())), song));
    Equal("https://song.link/i/3", DiscordLinks.SongLinkUrl(3).AbsoluteUri);

    var page = DiscordLinks.AppleMusicUrl(JsonNode.Parse("""{"trackViewUrl":"https://music.apple.com/us/album/a-milli/1440742903?i=1440743148&uo=4"}"""));
    Equal("https://music.apple.com/us/album/a-milli/1440742903?i=1440743148", page?.AbsoluteUri);
    Equal("https://music.apple.com/us/album/x/1", DiscordLinks.AppleMusicUrl(JsonNode.Parse("""{"trackViewUrl":"https://music.apple.com/us/album/x/1?uo=4"}"""))?.AbsoluteUri);
    Equal<Uri?>(null, DiscordLinks.AppleMusicUrl(JsonNode.Parse("""{"trackViewUrl":"https://example.com/x"}""")));
    Equal<Uri?>(null, DiscordLinks.AppleMusicUrl(JsonNode.Parse("""{"trackViewUrl":"https://notapple.com/x"}""")));
    var apple = DiscordActivity.Build(SongInfo() with { AppleMusicUrl = page }, new DiscordPresenceSettings { Button1 = DiscordButtonKind.AppleMusic, Button2 = DiscordButtonKind.None }, true, null)?.Buttons ?? [];
    Equal("Play on Apple Music", string.Join(",", apple.Select(b => b.Label)));
    Equal(page, apple[0].Url);

    Equal("https://open.spotify.com/search/Drake%20Wants%20and%20Needs", DiscordLinks.SpotifyUrl(song with { Title = "Wants and Needs (feat. Lil Baby)" }).AbsoluteUri);
    var spotify = DiscordActivity.Build(SongInfo() with { SpotifyUrl = DiscordLinks.SpotifyUrl(song) }, new DiscordPresenceSettings { Button1 = DiscordButtonKind.Spotify }, true, null);
    Equal("Play on Spotify", spotify?.Buttons[0].Label);

    var gif = new Uri("https://lastfm-img.freetls.fastly.net/i/u/300x300/ba2944136276c89dd14db2d134762306.gif");
    var frozen = DiscordLinks.FrozenCoverUrl(gif);
    Equal("wsrv.nl", frozen.Host);
    Equal("?url=" + Uri.EscapeDataString(gif.AbsoluteUri) + "&output=jpg&n=1", frozen.Query);
    Equal(true, DiscordLinks.ITunesSearchUrl(song, "CH").AbsoluteUri.StartsWith("https://itunes.apple.com/search?term=Drake%20Wants%20and%20Needs&media=music&entity=song"));
});
Test("Animated and still covers are told apart", () =>
{
    byte[] Bytes(params object[] parts) => parts.SelectMany(p => p is string text ? System.Text.Encoding.ASCII.GetBytes(text) : (byte[])p).ToArray();
    var jpeg = Bytes(new byte[] { 0xFF, 0xD8, 0xFF, 0xE0 });
    var png = Bytes(new byte[] { 0x89, 0x50, 0x4E, 0x47 }, "....IHDR....IDAT");
    var apng = Bytes(new byte[] { 0x89, 0x50, 0x4E, 0x47 }, "....IHDR....acTL....IDAT");
    var gif = Bytes("GIF89a", new byte[] { 0x21, 0xF9, 0x04 });
    var animatedGif = Bytes("GIF89a", "NETSCAPE2.0", new byte[] { 0x21, 0xF9, 0x04, 0x21, 0xF9, 0x04 });
    var webp = Bytes("RIFF\0\0\0\0WEBPVP8X", new byte[] { 0, 0, 0, 0, 0x02 });
    foreach (var image in new[] { jpeg, png, apng, gif, animatedGif, webp }) Equal(true, DiscordLinks.IsImage(image));
    Equal(false, DiscordLinks.IsImage(Bytes("<html>")));
    Equal("False,False,True,False,True,True", string.Join(",", new[] { jpeg, png, apng, gif, animatedGif, webp }.Select(i => DiscordLinks.IsAnimated(i))));
});
Test("Discord settings round-trip with defaults for missing values", () =>
{
    var settings = new DiscordPresenceSettings { Enabled = true, StateFormat = "by {artist}", Button2 = DiscordButtonKind.Spotify };
    Equal(settings, System.Text.Json.JsonSerializer.Deserialize<DiscordPresenceSettings>(System.Text.Json.JsonSerializer.Serialize(settings)));
    var partial = System.Text.Json.JsonSerializer.Deserialize<DiscordPresenceSettings>("""{"Enabled":true}""")!;
    Equal(true, partial.Enabled); Equal("{title}", partial.DetailsFormat); Equal(DiscordButtonKind.LastFmTrack, partial.Button2);
});
Console.WriteLine($"{passed} tests passed.");
