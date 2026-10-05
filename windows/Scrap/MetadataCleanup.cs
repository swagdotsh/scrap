namespace Scrap;

public sealed record MetadataCleanup(bool FirstArtistOnly = false, bool RemoveAlbumSuffixes = false, string[]? PreservedArtists = null)
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
            album = System.Text.RegularExpressions.Regex.Replace(album,
                @"\s*(?:[-–—:]\s*(?:single|ep|deluxe(?: edition)?|expanded edition|bonus tracks?|remaster(?:ed)?(?: \d{4})?|anniversary edition|commentary|soundtrack)|\s*\((?:deluxe(?: edition)?|expanded edition|bonus tracks?|remaster(?:ed)?(?: \d{4})?|\d{4} remaster|anniversary edition|soundtrack)[^)]*\))\s*$",
                "", System.Text.RegularExpressions.RegexOptions.IgnoreCase).Trim();
        }
        return track with { Artist = artist, Album = album, OriginalArtist = track.Artist, OriginalAlbum = track.Album };
    }

    public static string PreviewArtist(string artist, MetadataCleanup settings) => settings.Apply(new PlayingTrack("", artist, "", null), "AppleMusic").Artist;
    public static string PreviewAlbum(string album, MetadataCleanup settings) => settings.Apply(new PlayingTrack("", "", album, null), "AppleMusic").Album;
}
