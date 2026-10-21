namespace Scrap;

public sealed record MetadataCleanup(bool FirstArtistOnly = false, bool RemoveAlbumSuffixes = false, string[]? PreservedArtists = null, bool RemoveAppleMusicEdition = false, bool RemoveFeaturedArtists = false)
{
    public static MetadataCleanup Defaults => new(false, false, ["Earth, Wind & Fire"]);
    public string[] ArtistsToPreserve => (PreservedArtists ?? ["Earth, Wind & Fire"])
        .Where(name => !string.IsNullOrWhiteSpace(name)).Select(name => name.Trim()).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();

    public PlayingTrack Apply(PlayingTrack track, string source)
    {
        var isAppleMusic = source.Contains("AppleMusic", StringComparison.OrdinalIgnoreCase);
        var artist = track.Artist;
        if (isAppleMusic && FirstArtistOnly && !ArtistsToPreserve.Contains(artist, StringComparer.OrdinalIgnoreCase))
        {
            foreach (var marker in new[] { " & ", " feat. ", " feat ", " ft. ", " ft ", ", ", " / ", " x " })
            {
                var boundary = artist.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
                if (boundary > 0) { artist = artist[..boundary].Trim(); break; }
            }
        }
        var album = track.Album;
        if (isAppleMusic && RemoveAlbumSuffixes)
        {
            const string editionSuffix = " (Apple Music Edition)";
            if (RemoveAppleMusicEdition && album.EndsWith(editionSuffix, StringComparison.Ordinal))
                album = album[..^editionSuffix.Length];
            album = System.Text.RegularExpressions.Regex.Replace(album,
                @"\s*(?:[-–—:]\s*(?:single|ep|deluxe(?: edition)?|expanded edition|bonus tracks?|remaster(?:ed)?(?: \d{4})?|anniversary edition|commentary|soundtrack)|\s*\((?:deluxe(?: edition)?|expanded edition|bonus tracks?|remaster(?:ed)?(?: \d{4})?|\d{4} remaster|anniversary edition|soundtrack)[^)]*\))\s*$",
                "", System.Text.RegularExpressions.RegexOptions.IgnoreCase).Trim();
        }
        var title = RemoveFeaturedArtists ? RemovingFeaturedArtists(track.Title) : track.Title;
        return track with { Title = title, Artist = artist, Album = album, OriginalTitle = track.Title, OriginalArtist = track.Artist, OriginalAlbum = track.Album };
    }

    public static string RemovingFeaturedArtists(string title)
    {
        var cleaned = System.Text.RegularExpressions.Regex.Replace(title, @"\s*[(\[](?:feat\.?|ft\.?|featuring|with)\s[^)\]]*[)\]]", "",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase).Trim();
        return cleaned.Length == 0 ? title : cleaned;
    }

    public static string PreviewArtist(string artist, MetadataCleanup settings) => settings.Apply(new PlayingTrack("", artist, "", null), "AppleMusic").Artist;
    public static string PreviewAlbum(string album, MetadataCleanup settings) => settings.Apply(new PlayingTrack("", "", album, null), "AppleMusic").Album;
    public static string PreviewTitle(string title, MetadataCleanup settings) => settings.Apply(new PlayingTrack(title, "", "", null), "AppleMusic").Title;
}
