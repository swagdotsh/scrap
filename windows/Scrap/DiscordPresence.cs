using Microsoft.UI.Dispatching;
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Scrap;

public sealed class DiscordPresence : IDisposable
{
    /// The Discord application scrap's activity is published under (discord.com/developers),
    /// set with DISCORD_APPLICATION_ID in `.env`.
    public static readonly string ApplicationId = new(AppConfiguration.Load().DiscordApplicationId.Where(char.IsAsciiDigit).ToArray());
    private static readonly string[] DiscordProcesses = ["Discord", "DiscordPTB", "DiscordCanary"];
    private static readonly TimeSpan UploadLifetime = TimeSpan.FromHours(70);

    public enum State { Off, NotConfigured, WaitingForDiscord, Connecting, Connected, Error }
    private sealed record UploadedCover(string Url, DateTimeOffset Date);

    public State Status { get; private set; } = State.Off;
    public string? ActivityError { get; private set; }
    public DiscordTrackInfo? Info { get; private set; }
    public bool IsPlaying { get; private set; }
    public DateTimeOffset? StartedAt { get; private set; }
    public string? AppName { get; private set; }
    public DiscordPresenceSettings Settings { get; private set; }
    /// Raised on the UI thread when the status or the shown track changes.
    public event Action? Changed;

    private readonly LastFmClient client;
    private readonly DispatcherQueue queue;
    private readonly DiscordIpcConnection connection = new();
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(15) };
    private readonly DispatcherQueueTimer sendTimer;
    private readonly Dictionary<string, (Uri? SongLink, Uri? AppleMusic)> linkCache = [];
    private readonly Dictionary<string, Uri> coverCache = [];
    private string? connectedUser, errorMessage;
    private string? trackKey;
    private PlayingTrack? rawTrack;
    private IRandomAccessStreamReference? thumbnail;
    private CancellationTokenSource? lookups;
    private string? lastSent;
    private bool sentOnce;
    private DateTimeOffset lastSentAt = DateTimeOffset.MinValue, lastAttempt = DateTimeOffset.MinValue;
    private TimeSpan retryDelay = TimeSpan.FromSeconds(5);
    private bool disposed;

    public DiscordPresence(LastFmClient client, DispatcherQueue queue)
    {
        this.client = client;
        this.queue = queue;
        Settings = LocalStore.Load("discord.json", new DiscordPresenceSettings());
        sendTimer = queue.CreateTimer();
        sendTimer.IsRepeating = false;
        sendTimer.Tick += (_, _) => Send();
        connection.OnEvent = e => queue.TryEnqueue(() => Handle(e));
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Scrap-Windows/" + typeof(DiscordPresence).Assembly.GetName().Version?.ToString(3));
        RefreshStatus();
    }

    public string StatusDescription => ActivityError ?? Status switch
    {
        State.Off => "Off",
        State.NotConfigured => "No Discord application ID is set in this build. Add DISCORD_APPLICATION_ID to .env and rebuild.",
        State.WaitingForDiscord => "Waiting for Discord. Open the Discord app to show your activity.",
        State.Connecting => "Connecting to Discord…",
        State.Connected => connectedUser != null ? $"Connected to Discord as {connectedUser}." : "Connected to Discord.",
        _ => errorMessage ?? "Discord closed the connection."
    };

    /// Called by the main window about once a second.
    public void Update(PlayingTrack? track, bool playing, double position, IRandomAccessStreamReference? cover)
    {
        if (disposed) return;
        thumbnail = cover;
        if (track == null)
        {
            if (Info != null) { Info = null; trackKey = null; rawTrack = null; StartedAt = null; lookups?.Cancel(); Changed?.Invoke(); }
            IsPlaying = false;
            Tick();
            return;
        }
        var key = string.Join('\u001F', track.Artist, track.Title, track.Album, track.OriginalArtist, track.OriginalTitle, track.OriginalAlbum);
        if (key != trackKey)
        {
            trackKey = key;
            rawTrack = track;
            StartedAt = null;
            var display = DisplayTrack(track);
            Info = new DiscordTrackInfo(display, "Apple Music", coverCache.GetValueOrDefault(CoverKey(display, key)),
                linkCache.GetValueOrDefault(key).SongLink, linkCache.GetValueOrDefault(key).AppleMusic, DiscordLinks.SpotifyUrl(display));
            StartLookups(display, key);
            Changed?.Invoke();
        }
        if (playing)
        {
            var candidate = DateTimeOffset.Now.AddSeconds(-Math.Max(0, position));
            if (StartedAt is not { } started || Math.Abs((started - candidate).TotalSeconds) > 2) StartedAt = candidate;
        }
        if (IsPlaying != playing) { IsPlaying = playing; Changed?.Invoke(); }
        Tick();
    }

    public void Apply(DiscordPresenceSettings settings)
    {
        var previous = Settings;
        if (settings == previous) return;
        Settings = settings;
        try { LocalStore.Save("discord.json", settings); } catch { }
        if (rawTrack is { } raw && trackKey is { } key && Info != null)
        {
            var display = DisplayTrack(raw);
            var changed = display != Info.Track || settings.CoverSource != previous.CoverSource;
            if (changed) Info = Info with { Track = display, CoverUrl = coverCache.GetValueOrDefault(CoverKey(display, key)), SpotifyUrl = DiscordLinks.SpotifyUrl(display) };
            if (changed || settings.Enabled && !previous.Enabled) StartLookups(display, key);
        }
        if (settings.Enabled != previous.Enabled)
        {
            if (!settings.Enabled) { connection.Disconnect(); lastSent = null; sentOnce = false; sendTimer.Stop(); }
            lastAttempt = DateTimeOffset.MinValue;
            retryDelay = TimeSpan.FromSeconds(5);
            ActivityError = null;
            Status = State.Off;
            RefreshStatus();
        }
        Changed?.Invoke();
        Tick();
    }

    public async Task FetchAppNameAsync()
    {
        if (AppName != null || ApplicationId.Length == 0) return;
        try
        {
            var json = JsonNode.Parse(await http.GetStringAsync($"https://discord.com/api/v10/applications/{ApplicationId}/rpc"));
            if (json?["name"]?.ToString() is { Length: > 0 } name) { AppName = name; Changed?.Invoke(); }
        }
        catch { }
    }

    /// The activity for the current song, or null when nothing should be shown.
    public DiscordActivity? CurrentActivity => Info == null ? null : DiscordActivity.Build(Info, Settings, IsPlaying, StartedAt);

    private PlayingTrack DisplayTrack(PlayingTrack track) => Settings.UseScrobbleCleanup
        ? new PlayingTrack(track.Title, track.Artist, track.Album, track.Duration)
        : new PlayingTrack(track.OriginalTitle ?? track.Title, track.OriginalArtist ?? track.Artist, track.OriginalAlbum ?? track.Album, track.Duration);

    // Connection

    private void Tick()
    {
        if (!Settings.Enabled || ApplicationId.Length == 0) return;
        switch (Status)
        {
            case State.Connected:
                ScheduleSend();
                break;
            case State.Connecting:
                if (DateTimeOffset.UtcNow - lastAttempt > TimeSpan.FromSeconds(10)) { connection.Disconnect(); SetStatus(State.WaitingForDiscord); }
                break;
            default:
                if (DateTimeOffset.UtcNow - lastAttempt < retryDelay) return;
                lastAttempt = DateTimeOffset.UtcNow;
                if (!IsDiscordRunning()) { if (Status != State.Error) SetStatus(State.WaitingForDiscord); return; }
                SetStatus(State.Connecting);
                _ = connection.ConnectAsync(ApplicationId);
                break;
        }
    }

    private static bool IsDiscordRunning()
    {
        foreach (var name in DiscordProcesses)
        {
            var processes = Process.GetProcessesByName(name);
            var running = processes.Length > 0;
            foreach (var process in processes) process.Dispose();
            if (running) return true;
        }
        return false;
    }

    private void SetStatus(State status)
    {
        if (Status == status) return;
        Status = status;
        Changed?.Invoke();
    }

    private void RefreshStatus()
    {
        if (!Settings.Enabled) Status = State.Off;
        else if (ApplicationId.Length == 0) Status = State.NotConfigured;
        else if (Status != State.Connected) Status = State.WaitingForDiscord;
    }

    private void Handle(DiscordIpcConnection.Event e)
    {
        if (disposed) return;
        switch (e)
        {
            case DiscordIpcConnection.Ready ready:
                retryDelay = TimeSpan.FromSeconds(5);
                lastSent = null; sentOnce = false;
                ActivityError = null;
                connectedUser = ready.Username;
                Status = State.Connected;
                Changed?.Invoke();
                ScheduleSend();
                break;
            case DiscordIpcConnection.Closed closed:
                lastSent = null; sentOnce = false;
                sendTimer.Stop();
                if (!Settings.Enabled) { SetStatus(State.Off); return; }
                if (closed.Reason != null)
                {
                    errorMessage = "Discord closed the connection: " + closed.Reason;
                    retryDelay = TimeSpan.FromSeconds(30);
                    Status = State.Error;
                    Changed?.Invoke();
                }
                else
                {
                    retryDelay = TimeSpan.FromSeconds(5);
                    SetStatus(State.WaitingForDiscord);
                }
                break;
            case DiscordIpcConnection.Error error:
                ActivityError = "Discord: " + error.Message;
                Changed?.Invoke();
                break;
        }
    }

    // Sending

    private string? CurrentPayload() => CurrentActivity?.Payload().ToJsonString();

    /// Discord allows about five activity updates per 20 seconds, so updates are spaced out and coalesced.
    private void ScheduleSend()
    {
        if (sentOnce && lastSent == CurrentPayload()) { sendTimer.Stop(); return; }
        if (sendTimer.IsRunning) return;
        var wait = TimeSpan.FromSeconds(4) - (DateTimeOffset.UtcNow - lastSentAt);
        sendTimer.Interval = wait > TimeSpan.Zero ? wait : TimeSpan.FromMilliseconds(1);
        sendTimer.Start();
    }

    private void Send()
    {
        if (Status != State.Connected || !Settings.Enabled || disposed) return;
        var activity = CurrentActivity;
        var payload = activity?.Payload();
        var json = payload?.ToJsonString();
        if (sentOnce && json == lastSent) return;
        _ = connection.SetActivityAsync(payload);
        lastSent = json; sentOnce = true;
        lastSentAt = DateTimeOffset.UtcNow;
    }

    // Lookups

    /// last.fm covers are shared per album; Apple Music artwork can differ per track.
    private string CoverKey(PlayingTrack track, string key) =>
        Settings.CoverSource == DiscordCoverSource.MusicApp ? "app\u001F" + key : (track.Artist + "\u001F" + track.Album).ToLowerInvariant();

    private void StartLookups(PlayingTrack track, string key)
    {
        lookups?.Cancel();
        // Covers and links are only looked up while Rich Presence is on; turning it on looks them up then.
        if (!Settings.Enabled) return;
        var coverKey = CoverKey(track, key);
        var useMusicApp = Settings.CoverSource == DiscordCoverSource.MusicApp;
        var needsCover = !coverCache.ContainsKey(coverKey);
        var needsLinks = !linkCache.ContainsKey(key);
        if (!needsCover && !needsLinks) return;
        var cancel = (lookups = new CancellationTokenSource()).Token;
        _ = LookUpAsync(track, key, coverKey, useMusicApp, needsCover, needsLinks, cancel);
    }

    private async Task LookUpAsync(PlayingTrack track, string key, string coverKey, bool useMusicApp, bool needsCover, bool needsLinks, CancellationToken cancel)
    {
        try
        {
            if (needsCover)
            {
                Uri? cover = null;
                if (useMusicApp) cover = await MusicAppCoverAsync(key, cancel);
                if (cover == null && !cancel.IsCancellationRequested) cover = await LastFmCoverAsync(track, cancel);
                if (cover == null || cancel.IsCancellationRequested) return;
                coverCache[coverKey] = cover;
                if (trackKey == key && Info != null) { Info = Info with { CoverUrl = cover }; Changed?.Invoke(); Tick(); }
            }
            if (needsLinks)
            {
                var links = await MusicLinksAsync(track, cancel);
                if (cancel.IsCancellationRequested) return;
                linkCache[key] = links;
                if (trackKey == key && Info != null) { Info = Info with { SongLinkUrl = links.SongLink, AppleMusicUrl = links.AppleMusic }; Changed?.Invoke(); Tick(); }
            }
        }
        catch { }
    }

    /// Discord can only show images from a public link, so Apple Music's artwork is uploaded to Litterbox
    /// (it expires after 72 hours).
    private async Task<Uri?> MusicAppCoverAsync(string key, CancellationToken cancel)
    {
        // Windows can report the new song before its artwork, so give the thumbnail a moment to catch up.
        await Task.Delay(TimeSpan.FromSeconds(2), cancel);
        if (trackKey != key || thumbnail is not { } source) return null;
        var jpeg = await CoverJpegAsync(source);
        return jpeg == null || cancel.IsCancellationRequested ? null : await UploadedCoverUrlAsync(jpeg, cancel);
    }

    /// Re-encodes artwork as a JPEG no larger than 512 px so uploads stay small.
    private static async Task<byte[]?> CoverJpegAsync(IRandomAccessStreamReference source, uint maxPixels = 512)
    {
        try
        {
            using var input = await source.OpenReadAsync();
            if (input.Size == 0) return null;
            var decoder = await BitmapDecoder.CreateAsync(input);
            var scale = Math.Min(1, (double)maxPixels / Math.Max(decoder.OrientedPixelWidth, decoder.OrientedPixelHeight));
            var width = (uint)Math.Max(1, Math.Round(decoder.OrientedPixelWidth * scale));
            var height = (uint)Math.Max(1, Math.Round(decoder.OrientedPixelHeight * scale));
            var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore,
                new BitmapTransform { ScaledWidth = width, ScaledHeight = height, InterpolationMode = BitmapInterpolationMode.Fant },
                ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
            using var output = new InMemoryRandomAccessStream();
            var options = new BitmapPropertySet { ["ImageQuality"] = new BitmapTypedValue(0.85, Windows.Foundation.PropertyType.Single) };
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, output, options);
            encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, width, height, 96, 96, pixels.DetachPixelData());
            await encoder.FlushAsync();
            var bytes = new byte[output.Size];
            using var reader = new DataReader(output.GetInputStreamAt(0));
            await reader.LoadAsync((uint)output.Size);
            reader.ReadBytes(bytes);
            return bytes;
        }
        catch { return null; }
    }

    /// Uploads each distinct image once and reuses the link until shortly before Litterbox expires it.
    private async Task<Uri?> UploadedCoverUrlAsync(byte[] jpeg, CancellationToken cancel)
    {
        var hash = Convert.ToHexString(SHA256.HashData(jpeg)).ToLowerInvariant();
        var saved = LocalStore.Load("discord-uploaded-covers.json", new Dictionary<string, UploadedCover>());
        if (saved.TryGetValue(hash, out var entry) && DateTimeOffset.UtcNow - entry.Date < UploadLifetime && Uri.TryCreate(entry.Url, UriKind.Absolute, out var cached))
            return cached;
        using var form = new MultipartFormDataContent();
        form.Add(new StringContent("fileupload"), "reqtype");
        form.Add(new StringContent("72h"), "time");
        var file = new ByteArrayContent(jpeg);
        file.Headers.ContentType = new("image/jpeg");
        form.Add(file, "fileToUpload", "cover.jpg");
        using var response = await http.PostAsync("https://litterbox.catbox.moe/resources/internals/api.php", form, cancel);
        var text = (await response.Content.ReadAsStringAsync(cancel)).Trim();
        if (!response.IsSuccessStatusCode || !Uri.TryCreate(text, UriKind.Absolute, out var url) || url.Scheme != "https" ||
            !url.Host.EndsWith("catbox.moe", StringComparison.OrdinalIgnoreCase) || cancel.IsCancellationRequested) return null;
        saved = saved.Where(p => DateTimeOffset.UtcNow - p.Value.Date < UploadLifetime).ToDictionary();
        saved[hash] = new(url.AbsoluteUri, DateTimeOffset.UtcNow);
        try { LocalStore.Save("discord-uploaded-covers.json", saved); } catch { }
        return url;
    }

    private async Task<Uri?> LastFmCoverAsync(PlayingTrack track, CancellationToken cancel)
    {
        if (!client.Configured) return null;
        var candidates = new List<Uri>();
        if (track.Album.Length > 0)
            try { candidates = MusicPresentation.ImageUrls((await client.RequestAsync(new() { ["method"] = "album.getInfo", ["artist"] = track.Artist, ["album"] = track.Album }))["album"]?["image"]).ToList(); }
            catch { }
        if (candidates.Count == 0)
            try { candidates = MusicPresentation.ImageUrls((await client.RequestAsync(new() { ["method"] = "track.getInfo", ["artist"] = track.Artist, ["track"] = track.Title }))["track"]?["album"]?["image"]).ToList(); }
            catch { }
        // Prefer a still image that actually loads; Discord fetches the URL itself. last.fm lists the same
        // file at several sizes, so each distinct image is only checked once.
        var checkedFiles = new HashSet<string>();
        Uri? animated = null;
        foreach (var url in candidates)
        {
            if (!checkedFiles.Add(url.Segments.LastOrDefault() ?? url.AbsoluteUri)) continue;
            if (checkedFiles.Count > 4 || cancel.IsCancellationRequested) break;
            if (await FetchImageAsync(url, cancel) is not { } data || !DiscordLinks.IsImage(data)) continue;
            if (!DiscordLinks.IsAnimated(data)) return url;
            animated ??= url;
        }
        // Some albums only have an animated cover; Discord gets its first frame as a JPEG instead.
        if (animated != null && !cancel.IsCancellationRequested)
        {
            var frozen = DiscordLinks.FrozenCoverUrl(animated);
            if (await FetchImageAsync(frozen, cancel) is { } data && DiscordLinks.IsImage(data)) return frozen;
        }
        return animated ?? candidates.FirstOrDefault();
    }

    private async Task<byte[]?> FetchImageAsync(Uri url, CancellationToken cancel)
    {
        try
        {
            using var response = await http.GetAsync(url, cancel);
            return response.IsSuccessStatusCode ? await response.Content.ReadAsByteArrayAsync(cancel) : null;
        }
        catch { return null; }
    }

    /// Looks the song up in Apple's public catalog search for its Apple Music page and song.link ID.
    private async Task<(Uri? SongLink, Uri? AppleMusic)> MusicLinksAsync(PlayingTrack track, CancellationToken cancel)
    {
        try
        {
            var country = RegionInfo.CurrentRegion.TwoLetterISORegionName;
            var json = JsonNode.Parse(await http.GetStringAsync(DiscordLinks.ITunesSearchUrl(track, country.Length == 2 ? country : "US"), cancel));
            if (json?["results"] is not JsonArray results || DiscordLinks.BestITunesMatch(results, track) is not { } match) return (null, null);
            var songLink = long.TryParse(match["trackId"]?.ToString(), out var id) ? DiscordLinks.SongLinkUrl(id) : null;
            return (songLink, DiscordLinks.AppleMusicUrl(match));
        }
        catch { return (null, null); }
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        lookups?.Cancel();
        sendTimer.Stop();
        connection.Dispose();
        http.Dispose();
    }
}
