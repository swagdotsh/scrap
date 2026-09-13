using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace Scrap;

public sealed class LastFmClient : IDisposable
{
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(20) };
    private readonly SemaphoreSlim sendLock = new(1, 1);
    private string apiKey = "", sharedSecret = "", sessionKey = "";
    private List<Submission> queue = [];
    public string? Username { get; private set; }
    public string? PendingToken { get; private set; }
    public bool Configured => apiKey.Length > 0 && sharedSecret.Length > 0;
    public bool Connected => Configured && sessionKey.Length > 0 && Username != null;
    public bool Paused { get; set; }
    public int PendingCount => queue.Count;
    public string Status { get; private set; } = "Connect your Last.fm account to start scrobbling.";
    public event Action? AccountChanged;

    public void Initialize()
    {
        var configuration = AppConfiguration.Load();
        apiKey = configuration.ApiKey;
        sharedSecret = configuration.SharedSecret;
        var session = LocalStore.Credential("Scrap.LastFm.Session");
        if (session is { } saved) { Username = saved.User; sessionKey = saved.Secret; }
        queue = LocalStore.Load<List<Submission>>("pending.json", []);
        if (Connected) Status = $"Connected as {Username}.";
        else if (!Configured) Status = "Add Last.fm credentials to .env and rebuild Scrap.";
    }

    public async Task<Uri> BeginAuthAsync()
    {
        var result = await RequestAsync(new() { ["method"] = "auth.getToken" });
        PendingToken = Text(result["token"]);
        if (PendingToken.Length == 0) throw new InvalidOperationException("Last.fm returned no token.");
        return new Uri($"https://www.last.fm/api/auth/?api_key={Uri.EscapeDataString(apiKey)}&token={Uri.EscapeDataString(PendingToken)}");
    }

    public async Task CompleteAuthAsync()
    {
        if (PendingToken == null) throw new InvalidOperationException("Connect Last.fm first.");
        var result = await RequestAsync(new() { ["method"] = "auth.getSession", ["token"] = PendingToken });
        var key = Text(result["session"]?["key"]);
        var user = Text(result["session"]?["name"]);
        if (key.Length == 0 || user.Length == 0) throw new InvalidOperationException("Last.fm returned no session.");
        LocalStore.SaveCredential("Scrap.LastFm.Session", user, key);
        sessionKey = key; Username = user; PendingToken = null;
        Status = $"Connected as {user}.";
        AccountChanged?.Invoke();
    }

    public void SignOut()
    {
        LocalStore.ClearCredential("Scrap.LastFm.Session");
        sessionKey = ""; Username = null; PendingToken = null;
        Status = "Signed out.";
        AccountChanged?.Invoke();
    }

    public void Enqueue(PlayingTrack track, DateTimeOffset startedAt)
    {
        if (!Connected || Paused) return;
        var next = new List<Submission>(queue) { new(track, startedAt.ToUnixTimeSeconds(), Username!) };
        LocalStore.Save("pending.json", next);
        queue = next;
    }

    public async Task NowPlayingAsync(PlayingTrack track)
    {
        if (!Connected || Paused) return;
        var args = Metadata(track, "track.updateNowPlaying");
        await RequestAsync(args, true);
    }

    public async Task RetryAsync()
    {
        if (!Connected || Paused || !await sendLock.WaitAsync(0)) return;
        try
        {
            while (Connected && !Paused)
            {
                var item = queue.FirstOrDefault(s => s.Username == Username);
                if (item == null) return;
                var args = Metadata(item.Track, "track.scrobble");
                args["timestamp"] = item.Timestamp.ToString(CultureInfo.InvariantCulture);
                var result = await RequestAsync(args, true);
                if (result["scrobbles"]?["@attr"]?["accepted"] == null)
                    throw new InvalidOperationException("Unexpected response; scrobble retained for retry.");
                var next = new List<Submission>(queue);
                next.Remove(item);
                LocalStore.Save("pending.json", next);
                queue = next;
                Status = Text(result["scrobbles"]?["@attr"]?["accepted"]) == "1"
                    ? $"Scrobbled {item.Track.Title}." : $"Last.fm ignored {item.Track.Title}.";
            }
        }
        finally { sendLock.Release(); }
    }

    public async Task<bool> IsLovedAsync(PlayingTrack track)
    {
        if (!Connected) throw new InvalidOperationException("Connect Last.fm first.");
        var result = await RequestAsync(new() { ["method"] = "track.getInfo", ["artist"] = track.Artist, ["track"] = track.Title, ["username"] = Username! });
        return TrackLove.Parse(result);
    }

    public async Task LoveAsync(PlayingTrack track, bool loved)
    {
        if (!Connected) throw new InvalidOperationException("Connect Last.fm first.");
        await RequestAsync(Metadata(track, loved ? "track.love" : "track.unlove"), true);
        Status = loved ? $"Loved {track.Title}." : $"Unloved {track.Title}.";
    }

    private Dictionary<string, string> Metadata(PlayingTrack track, string method)
    {
        var args = new Dictionary<string, string> { ["method"] = method, ["track"] = track.Title, ["artist"] = track.Artist, ["album"] = track.Album, ["sk"] = sessionKey };
        if (track.Duration is > 0) args["duration"] = ((int)track.Duration.Value).ToString(CultureInfo.InvariantCulture);
        return args;
    }

    public async Task<JsonNode> RequestAsync(Dictionary<string, string> args, bool post = false)
    {
        if (!Configured) throw new InvalidOperationException("Add your Last.fm API key and shared secret to .env and rebuild Scrap.");
        args = new(args) { ["api_key"] = apiKey };
        var signature = string.Concat(args.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => p.Key + p.Value)) + sharedSecret;
        args["api_sig"] = Convert.ToHexString(MD5.HashData(Encoding.UTF8.GetBytes(signature))).ToLowerInvariant();
        args["format"] = "json";
        using var form = new FormUrlEncodedContent(args);
        using var request = new HttpRequestMessage(post ? HttpMethod.Post : HttpMethod.Get,
            "https://ws.audioscrobbler.com/2.0/" + (post ? "" : "?" + await form.ReadAsStringAsync()));
        if (post) request.Content = form;
        using var response = await http.SendAsync(request);
        var json = JsonNode.Parse(await response.Content.ReadAsStringAsync()) ?? throw new InvalidOperationException("Empty Last.fm response.");
        if (json["error"] != null)
        {
            if (Text(json["error"]) == "9") SignOut();
            throw new InvalidOperationException(Text(json["message"]));
        }
        response.EnsureSuccessStatusCode();
        return json;
    }

    public static string Text(JsonNode? node) => node?.ToString() ?? "";
    public static IEnumerable<JsonNode> Rows(JsonNode? node) => node is JsonArray array ? array.OfType<JsonNode>() : node == null ? [] : [node];
    public void Dispose() => http.Dispose();
}
