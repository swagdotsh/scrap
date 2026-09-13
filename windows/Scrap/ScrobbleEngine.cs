namespace Scrap;

public sealed record PlayingTrack(string Title, string Artist, string Album, double? Duration);
public sealed record Submission(PlayingTrack Track, long Timestamp, string Username);
public sealed class ScrobbleEngine
{
    public PlayingTrack? Track { get; private set; }
    public double PlayedSeconds { get; private set; }
    public bool Submitted { get; private set; }
    private DateTimeOffset? lastUpdate, startedAt;
    private bool wasPlaying, sentNowPlaying;
    public event Action<PlayingTrack>? NowPlaying;
    public event Action<PlayingTrack, DateTimeOffset>? Scrobble;

    public void Suspend() { wasPlaying = false; lastUpdate = null; }
    public void Reset() { Suspend(); Track = null; PlayedSeconds = 0; Submitted = false; startedAt = null; sentNowPlaying = false; }

    public void Update(PlayingTrack? track, bool playing, DateTimeOffset now, bool restarted = false)
    {
        if (wasPlaying && lastUpdate is { } last)
        {
            var elapsed = (now - last).TotalSeconds;
            if (elapsed is >= 0 and <= 3) PlayedSeconds += elapsed;
            if (!Submitted && Track?.Duration is > 30 && startedAt is { } start && PlayedSeconds >= Math.Min(240, Track.Duration.Value / 2))
            {
                Scrobble?.Invoke(Track, start);
                Submitted = true;
            }
        }
        if (track?.Title != Track?.Title || track?.Artist != Track?.Artist || track?.Album != Track?.Album || restarted)
        {
            PlayedSeconds = 0; Submitted = false; startedAt = null; sentNowPlaying = false;
        }
        Track = track;
        if (track != null && playing)
        {
            startedAt ??= now;
            if (!sentNowPlaying) { NowPlaying?.Invoke(track); sentNowPlaying = true; }
        }
        wasPlaying = playing && track != null;
        lastUpdate = now;
    }
}
