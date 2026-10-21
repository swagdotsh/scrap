using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace Scrap;

public sealed class Notifier : IDisposable
{
    public const int MilestoneStep = 5000;
    private readonly LastFmClient lastFm;
    private readonly Dictionary<string, int> sessionPlays = new(StringComparer.Ordinal);
    private readonly HashSet<string> checkedArtists = new(StringComparer.Ordinal);
    private bool registered;
    public event Action<string>? OpenPage;

    public bool Milestones { get; set; } = LocalStore.Load("notify-milestones.json", true);
    public bool NewArtists { get; set; } = LocalStore.Load("notify-new-artists.json", true);
    public bool WeeklyReports { get; set; } = LocalStore.Load("notify-weekly-report.json", true);

    public Notifier(LastFmClient lastFm)
    {
        this.lastFm = lastFm;
        try
        {
            if (!AppNotificationManager.IsSupported()) return;
            AppNotificationManager.Default.NotificationInvoked += (_, args) =>
            {
                if (args.Arguments.TryGetValue("page", out var page)) OpenPage?.Invoke(page);
            };
            AppNotificationManager.Default.Register();
            registered = true;
        }
        catch { registered = false; }
    }

    public void SavePreferences()
    {
        LocalStore.Save("notify-milestones.json", Milestones);
        LocalStore.Save("notify-new-artists.json", NewArtists);
        LocalStore.Save("notify-weekly-report.json", WeeklyReports);
    }

    public async Task RefreshAsync()
    {
        CheckWeeklyReport();
        await CheckMilestoneAsync();
    }

    public void CheckWeeklyReport()
    {
        var now = DateTimeOffset.UtcNow;
        var latest = ReportSchedule.Latest(now);
        var last = LocalStore.Load("last-weekly-report.json", DateTimeOffset.MinValue);
        if (last >= latest) return;
        LocalStore.Save("last-weekly-report.json", latest);
        if (last == DateTimeOffset.MinValue || !WeeklyReports || now - latest > TimeSpan.FromDays(1)) return;
        var week = WeeklyReport.LatestWeek(latest.LocalDateTime);
        Post("Your weekly report is ready", $"See your top artist, album and track for {week.Start:MMM d} – {week.End.AddDays(-1):MMM d}.", "reports");
    }

    public async Task CheckMilestoneAsync()
    {
        if (!lastFm.Connected || lastFm.Username is not { } user) return;
        try
        {
            var info = await lastFm.RequestAsync(new() { ["method"] = "user.getInfo", ["user"] = user });
            if (MusicPresentation.Count(info["user"]?["playcount"]) is not { } plays) return;
            var reached = plays / MilestoneStep * MilestoneStep;
            var milestones = LocalStore.Load("milestones.json", new Dictionary<string, long>());
            var key = user.ToLowerInvariant();
            var first = !milestones.TryGetValue(key, out var previous);
            if (!first && reached <= previous) return;
            milestones[key] = reached;
            LocalStore.Save("milestones.json", milestones);
            if (!first && Milestones && reached > 0)
                Post($"{reached:N0} scrobbles!", $"You just passed {reached:N0} scrobbles on last.fm.", "profile");
        }
        catch { }
    }

    public void DidScrobble(PlayingTrack track)
    {
        var artist = track.Artist.ToLowerInvariant();
        sessionPlays[artist] = sessionPlays.GetValueOrDefault(artist) + 1;
        if (sessionPlays.Values.Sum() % 10 == 0) _ = CheckMilestoneAsync();
        if (!NewArtists || lastFm.Username is not { } user || !checkedArtists.Add(artist)) return;
        var notified = LocalStore.Load("notified-new-artists.json", new HashSet<string>(StringComparer.Ordinal));
        if (notified.Contains(artist)) return;
        _ = CheckNewArtistAsync(track, artist, user, notified);
    }

    private async Task CheckNewArtistAsync(PlayingTrack track, string artist, string user, HashSet<string> notified)
    {
        try
        {
            var json = await lastFm.RequestAsync(new() { ["method"] = "artist.getInfo", ["artist"] = track.Artist, ["username"] = user });
            if (MusicPresentation.Count(json["artist"]?["stats"]?["userplaycount"]) is not { } total || total > sessionPlays.GetValueOrDefault(artist, 1)) return;
            notified.Add(artist);
            LocalStore.Save("notified-new-artists.json", notified);
            Post("New artist discovered", $"You scrobbled {track.Artist} for the first time.", "reports");
        }
        catch { }
    }

    private void Post(string title, string body, string page)
    {
        if (!registered) return;
        try { AppNotificationManager.Default.Show(new AppNotificationBuilder().AddArgument("page", page).AddText(title).AddText(body).BuildNotification()); }
        catch { }
    }

    public void Dispose()
    {
        if (!registered) return;
        try { AppNotificationManager.Default.Unregister(); } catch { }
        registered = false;
    }
}
