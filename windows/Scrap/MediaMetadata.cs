namespace Scrap;

public static class MediaMetadata
{
    public static PlayingTrack Normalize(string source, string title, string artist, string album, double? duration)
    {
        if (source.Contains("AppleMusic", StringComparison.OrdinalIgnoreCase))
        {
            const string separator = " — ";
            if (!string.IsNullOrWhiteSpace(album) && artist.EndsWith(separator + album, StringComparison.Ordinal))
                artist = artist[..^(separator.Length + album.Length)];
            else if (string.IsNullOrWhiteSpace(album))
            {
                var boundary = artist.LastIndexOf(separator, StringComparison.Ordinal);
                if (boundary > 0 && boundary + separator.Length < artist.Length)
                {
                    album = artist[(boundary + separator.Length)..];
                    artist = artist[..boundary];
                }
            }
        }
        return new(title.Trim(), artist.Trim(), album.Trim(), duration);
    }
}
