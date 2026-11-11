using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;

namespace Scrap;

// Settings

public enum DiscordStatusSource { State, Details, App }
public enum DiscordButtonKind { None, SongLink, AppleMusic, Spotify, LastFmTrack, LastFmArtist, LastFmAlbum }
public enum DiscordCoverSource { LastFm, MusicApp }
public enum DiscordPausedBehavior { Clear, Keep }

public static class DiscordLabels
{
    public static readonly DiscordStatusSource[] StatusSources = [DiscordStatusSource.State, DiscordStatusSource.Details, DiscordStatusSource.App];
    public static readonly DiscordButtonKind[] ButtonKinds = Enum.GetValues<DiscordButtonKind>();

    public static string Label(DiscordStatusSource source) => source switch
    {
        DiscordStatusSource.State => "Artist line",
        DiscordStatusSource.Details => "Track line",
        _ => "App name"
    };

    /// Discord's `status_display_type`: 0 = name, 1 = state, 2 = details.
    public static int DiscordValue(DiscordStatusSource source) => source switch
    {
        DiscordStatusSource.App => 0,
        DiscordStatusSource.State => 1,
        _ => 2
    };

    public static string MenuTitle(DiscordButtonKind kind) => kind switch
    {
        DiscordButtonKind.None => "None",
        DiscordButtonKind.SongLink => "song.link",
        DiscordButtonKind.AppleMusic => "Apple Music",
        DiscordButtonKind.Spotify => "Spotify",
        DiscordButtonKind.LastFmTrack => "last.fm track page",
        DiscordButtonKind.LastFmArtist => "last.fm artist page",
        _ => "last.fm album page"
    };

    public static string DefaultLabel(DiscordButtonKind kind) => kind switch
    {
        DiscordButtonKind.None => "",
        DiscordButtonKind.SongLink => "Listen on song.link",
        DiscordButtonKind.AppleMusic => "Play on Apple Music",
        DiscordButtonKind.Spotify => "Play on Spotify",
        DiscordButtonKind.LastFmTrack => "View on last.fm",
        DiscordButtonKind.LastFmArtist => "Artist on last.fm",
        _ => "Album on last.fm"
    };
}

public sealed record DiscordPresenceSettings
{
    public const string DefaultDetailsFormat = "{title}";
    public const string DefaultStateFormat = "{artist}";
    public const string DefaultAlbumFormat = "{album}";

    public bool Enabled { get; init; }
    public string DetailsFormat { get; init; } = DefaultDetailsFormat;
    public string StateFormat { get; init; } = DefaultStateFormat;
    public string AlbumFormat { get; init; } = DefaultAlbumFormat;
    public DiscordStatusSource StatusSource { get; init; } = DiscordStatusSource.State;
    public bool ShowCover { get; init; } = true;
    public DiscordCoverSource CoverSource { get; init; } = DiscordCoverSource.LastFm;
    public bool ShowTimestamps { get; init; } = true;
    public bool LinkNames { get; init; } = true;
    public bool UseScrobbleCleanup { get; init; } = true;
    public DiscordPausedBehavior Paused { get; init; } = DiscordPausedBehavior.Clear;
    public DiscordButtonKind Button1 { get; init; } = DiscordButtonKind.SongLink;
    public string Button1Label { get; init; } = "";
    public DiscordButtonKind Button2 { get; init; } = DiscordButtonKind.LastFmTrack;
    public string Button2Label { get; init; } = "";
}

// Activity

public sealed record DiscordTrackInfo(PlayingTrack Track, string? Service, Uri? CoverUrl = null, Uri? SongLinkUrl = null, Uri? AppleMusicUrl = null, Uri? SpotifyUrl = null);

public sealed record DiscordButton(string Label, Uri Url);

public sealed record DiscordActivity
{
    public string? Details { get; init; }
    public string? State { get; init; }
    public string? AlbumText { get; init; }
    public Uri? DetailsUrl { get; init; }
    public Uri? StateUrl { get; init; }
    public Uri? AlbumUrl { get; init; }
    public Uri? CoverUrl { get; init; }
    public DiscordStatusSource StatusSource { get; init; }
    public DateTimeOffset? Start { get; init; }
    public DateTimeOffset? End { get; init; }
    public IReadOnlyList<DiscordButton> Buttons { get; init; } = [];

    /// The text shown after "Listening to" in member lists and on your profile.
    public string StatusText(string appName) => StatusSource switch
    {
        DiscordStatusSource.State => State ?? appName,
        DiscordStatusSource.Details => Details ?? appName,
        _ => appName
    };

    public JsonObject Payload()
    {
        var activity = new JsonObject { ["type"] = 2, ["status_display_type"] = DiscordLabels.DiscordValue(StatusSource) };
        if (Details != null) activity["details"] = Details;
        if (State != null) activity["state"] = State;
        if (DetailsUrl != null) activity["details_url"] = DetailsUrl.AbsoluteUri;
        if (StateUrl != null) activity["state_url"] = StateUrl.AbsoluteUri;
        var assets = new JsonObject();
        if (CoverUrl != null) assets["large_image"] = CoverUrl.AbsoluteUri;
        if (AlbumText != null) assets["large_text"] = AlbumText;
        if (AlbumUrl != null && CoverUrl != null) assets["large_url"] = AlbumUrl.AbsoluteUri;
        if (assets.Count > 0) activity["assets"] = assets;
        var timestamps = new JsonObject();
        if (Start is { } start) timestamps["start"] = start.ToUnixTimeMilliseconds();
        if (End is { } end) timestamps["end"] = end.ToUnixTimeMilliseconds();
        if (timestamps.Count > 0) activity["timestamps"] = timestamps;
        if (Buttons.Count > 0) activity["buttons"] = new JsonArray(Buttons.Select(b => (JsonNode)new JsonObject { ["label"] = b.Label, ["url"] = b.Url.AbsoluteUri }).ToArray());
        return activity;
    }

    public static DiscordActivity? Build(DiscordTrackInfo info, DiscordPresenceSettings settings, bool isPlaying, DateTimeOffset? startedAt)
    {
        if (!isPlaying && settings.Paused == DiscordPausedBehavior.Clear) return null;
        var track = info.Track;
        var details = Text(Format(settings.DetailsFormat, info));
        var state = Text(Format(settings.StateFormat, info));
        var album = Text(Format(settings.AlbumFormat, info));
        var source = settings.StatusSource;
        if (source == DiscordStatusSource.State && state == null || source == DiscordStatusSource.Details && details == null)
            source = state != null ? DiscordStatusSource.State : details != null ? DiscordStatusSource.Details : DiscordStatusSource.App;
        var activity = new DiscordActivity { Details = details, State = state, AlbumText = album, StatusSource = source };
        if (settings.LinkNames)
            activity = activity with
            {
                DetailsUrl = details != null ? MusicPresentation.TrackUrl(track.Artist, track.Title) : null,
                StateUrl = state != null ? MusicPresentation.ArtistUrl(track.Artist) : null,
                AlbumUrl = track.Album.Length > 0 ? MusicPresentation.AlbumUrl(track.Artist, track.Album) : null
            };
        if (settings.ShowCover) activity = activity with { CoverUrl = info.CoverUrl };
        if (isPlaying && settings.ShowTimestamps && startedAt is { } start)
            activity = activity with { Start = start, End = track.Duration is > 0 ? start.AddSeconds(track.Duration.Value) : null };
        var used = new HashSet<Uri>();
        var buttons = new List<DiscordButton>();
        foreach (var (kind, label) in new[] { (settings.Button1, settings.Button1Label), (settings.Button2, settings.Button2Label) })
        {
            var url = ButtonUrl(kind, info) ?? (kind == DiscordButtonKind.SongLink ? MusicPresentation.TrackUrl(track.Artist, track.Title) : null);
            if (url == null || !used.Add(url)) continue;
            var trimmed = label.Trim();
            buttons.Add(new(Clamp(trimmed.Length == 0 ? DiscordLabels.DefaultLabel(kind) : trimmed, 32), url));
        }
        return activity with { Buttons = buttons };
    }

    public static Uri? ButtonUrl(DiscordButtonKind kind, DiscordTrackInfo info) => kind switch
    {
        DiscordButtonKind.SongLink => info.SongLinkUrl,
        DiscordButtonKind.AppleMusic => info.AppleMusicUrl,
        DiscordButtonKind.Spotify => info.SpotifyUrl,
        DiscordButtonKind.LastFmTrack => MusicPresentation.TrackUrl(info.Track.Artist, info.Track.Title),
        DiscordButtonKind.LastFmArtist => MusicPresentation.ArtistUrl(info.Track.Artist),
        DiscordButtonKind.LastFmAlbum when info.Track.Album.Length > 0 => MusicPresentation.AlbumUrl(info.Track.Artist, info.Track.Album),
        _ => null
    };

    /// Fills `{title}`, `{artist}`, `{album}` and `{service}`. A line that uses a token with no value
    /// (for example `on {album}` for a song without an album) is left out entirely.
    public static string Format(string template, DiscordTrackInfo info)
    {
        var result = template;
        foreach (var (token, value) in new[] { ("{title}", info.Track.Title), ("{artist}", info.Track.Artist), ("{album}", info.Track.Album), ("{service}", info.Service ?? "") })
        {
            if (!result.Contains(token, StringComparison.Ordinal)) continue;
            if (string.IsNullOrWhiteSpace(value)) return "";
            result = result.Replace(token, value, StringComparison.Ordinal);
        }
        return result;
    }

    private static string? Text(string value)
    {
        var trimmed = value.Trim();
        return trimmed.Length == 0 ? null : Clamp(trimmed, 128);
    }

    /// Discord requires 2–128 characters for text fields and at most 32 for button labels.
    public static string Clamp(string value, int limit)
    {
        var info = new StringInfo(value);
        var result = info.LengthInTextElements > limit ? info.SubstringByTextElements(0, limit - 1) + "…" : value;
        while (new StringInfo(result).LengthInTextElements < 2) result += "⠀";
        return result;
    }
}

// Links

public static class DiscordLinks
{
    /// A Spotify search, since matching another service's song to Spotify needs Spotify API credentials.
    public static Uri SpotifyUrl(PlayingTrack track) =>
        new("https://open.spotify.com/search/" + Uri.EscapeDataString($"{track.Artist} {MetadataCleanup.RemovingFeaturedArtists(track.Title)}"));

    public static Uri SongLinkUrl(long iTunesTrackId) => new($"https://song.link/i/{iTunesTrackId}");

    /// The first frame of an animated cover as a JPEG, via the wsrv.nl image proxy.
    public static Uri FrozenCoverUrl(Uri url) => new($"https://wsrv.nl/?url={Uri.EscapeDataString(url.AbsoluteUri)}&output=jpg&n=1");

    /// Apple's public catalog search, which needs no developer account.
    public static Uri ITunesSearchUrl(PlayingTrack track, string country) =>
        new("https://itunes.apple.com/search?term=" + Uri.EscapeDataString($"{track.Artist} {MetadataCleanup.RemovingFeaturedArtists(track.Title)}") +
            "&media=music&entity=song&limit=10&country=" + Uri.EscapeDataString(country));

    /// `trackViewUrl` with tracking parameters removed, keeping `i` (the song within the album).
    public static Uri? AppleMusicUrl(JsonNode? match)
    {
        if (!Uri.TryCreate(match?["trackViewUrl"]?.ToString(), UriKind.Absolute, out var url) || url.Scheme != "https" ||
            !(url.Host == "apple.com" || url.Host.EndsWith(".apple.com", StringComparison.OrdinalIgnoreCase))) return null;
        var song = url.Query.TrimStart('?').Split('&').FirstOrDefault(p => p.StartsWith("i=", StringComparison.Ordinal));
        return new UriBuilder(url) { Query = song ?? "" }.Uri;
    }

    public static JsonNode? BestITunesMatch(JsonArray results, PlayingTrack track)
    {
        static string Normalize(string value)
        {
            var folded = MetadataCleanup.RemovingFeaturedArtists(value).Normalize(NormalizationForm.FormD);
            return new string(folded.Where(c => char.IsLetterOrDigit(c) && CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark)
                .Select(char.ToLowerInvariant).ToArray());
        }
        var title = Normalize(track.Title);
        var artist = Normalize(track.Artist);
        var album = Normalize(track.Album);
        var matches = results.OfType<JsonNode>().Where(r =>
        {
            var resultArtist = Normalize(r["artistName"]?.ToString() ?? "");
            return Normalize(r["trackName"]?.ToString() ?? "") == title && resultArtist.Length > 0 && (artist.Contains(resultArtist) || resultArtist.Contains(artist));
        }).ToList();
        return matches.FirstOrDefault(r => album.Length > 0 && Normalize(r["collectionName"]?.ToString() ?? "").StartsWith(album, StringComparison.Ordinal)) ?? matches.FirstOrDefault();
    }

    public static bool IsImage(ReadOnlySpan<byte> data) =>
        data.StartsWith((ReadOnlySpan<byte>)[0xFF, 0xD8, 0xFF]) || data.StartsWith((ReadOnlySpan<byte>)[0x89, 0x50, 0x4E, 0x47]) ||
        data.StartsWith("GIF8"u8) || data.Length >= 12 && data.StartsWith("RIFF"u8) && data[8..12].SequenceEqual("WEBP"u8);

    /// Animated GIFs, animated WebPs and APNGs; Discord only shows still covers.
    public static bool IsAnimated(ReadOnlySpan<byte> data)
    {
        if (data.StartsWith("GIF8"u8)) return data.IndexOf("NETSCAPE2.0"u8) >= 0 || Count(data, [0x21, 0xF9, 0x04]) > 1;
        if (data.Length >= 21 && data.StartsWith("RIFF"u8) && data[8..12].SequenceEqual("WEBP"u8) && data[12..16].SequenceEqual("VP8X"u8)) return (data[20] & 0x02) != 0;
        if (data.StartsWith((ReadOnlySpan<byte>)[0x89, 0x50, 0x4E, 0x47]))
        {
            var animation = data.IndexOf("acTL"u8);
            var image = data.IndexOf("IDAT"u8);
            return animation >= 0 && (image < 0 || animation < image);
        }
        return false;
    }

    private static int Count(ReadOnlySpan<byte> data, ReadOnlySpan<byte> pattern)
    {
        var count = 0;
        var offset = 0;
        while (count < 2 && data[offset..].IndexOf(pattern) is var index and >= 0)
        {
            count++;
            offset += index + 1;
        }
        return count;
    }
}
