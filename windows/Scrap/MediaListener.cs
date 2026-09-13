using Windows.Media.Control;

namespace Scrap;

public sealed class MediaListener
{
    private GlobalSystemMediaTransportControlsSessionManager? manager;
    private string? previousSource;
    private double previousPosition;
    private PlayingTrack? previousTrack;
    public bool AppleMusicOnly { get; set; } = true;
    public string Source { get; private set; } = "Apple Music";
    public Windows.Storage.Streams.IRandomAccessStreamReference? Thumbnail { get; private set; }

    public async Task<(PlayingTrack? Track, bool Playing, bool Restarted)> ReadAsync()
    {
        manager ??= await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
        var sessions = manager.GetSessions();
        var session = AppleMusicOnly
            ? sessions.FirstOrDefault(s => s.SourceAppUserModelId.Contains("AppleMusic", StringComparison.OrdinalIgnoreCase))
            : manager.GetCurrentSession();
        if (session == null) { previousTrack = null; previousSource = null; Thumbnail = null; return (null, false, false); }
        var metadata = await session.TryGetMediaPropertiesAsync();
        var timeline = session.GetTimelineProperties();
        var duration = (timeline.EndTime - timeline.StartTime).TotalSeconds;
        var position = (timeline.Position - timeline.StartTime).TotalSeconds;
        Source = session.SourceAppUserModelId;
        if (string.IsNullOrWhiteSpace(metadata.Title) || string.IsNullOrWhiteSpace(metadata.Artist))
        { previousTrack = null; return (null, false, false); }
        Thumbnail = metadata.Thumbnail;
        var track = MediaMetadata.Normalize(Source, metadata.Title, metadata.Artist, metadata.AlbumTitle, duration > 0 ? duration : null);
        var same = previousTrack?.Title == track.Title && previousTrack?.Artist == track.Artist && previousTrack?.Album == track.Album;
        var restarted = previousSource != null && previousSource != Source || same && duration > 0 && previousPosition >= duration - 3 && position < 3;
        previousTrack = track; previousPosition = position; previousSource = Source;
        return (track, session.GetPlaybackInfo().PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing, restarted);
    }
}
