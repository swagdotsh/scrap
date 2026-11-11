namespace Scrap;

/// A last.fm API error, with its error code (for example 29 when rate limited).
public sealed class LastFmException(int code, string message) : InvalidOperationException(message)
{
    public int Code { get; } = code;
}
