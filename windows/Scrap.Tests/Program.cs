using Scrap;

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
Test("Updater ignores drafts, prereleases, and macOS releases and selects newest Windows", () =>
{
    var releases = System.Text.Json.Nodes.JsonNode.Parse("""[{"tag_name":"v1.1-windows","target_commitish":"windows-app-sdk"},{"tag_name":"windows-v1.2.0","target_commitish":"windows-app-sdk"},{"tag_name":"v9.0","target_commitish":"main"},{"tag_name":"windows-v9.0","target_commitish":"windows-app-sdk","draft":true},{"tag_name":"windows-v8.0","target_commitish":"windows-app-sdk","prerelease":true}]""")!.AsArray();
    Equal("windows-v1.2.0", UpdateRelease.Latest(releases)?["tag_name"]?.ToString());
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
Console.WriteLine($"{passed} tests passed.");
