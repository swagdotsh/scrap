using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Text.Json.Nodes;

namespace Scrap;

public sealed partial class MainWindow
{
    private readonly Dictionary<string, WeeklyReport> reports = new(StringComparer.Ordinal);
    private readonly Dictionary<string, ChartGalleryWindow> galleries = new(StringComparer.Ordinal);
    private readonly SemaphoreSlim galleryArtworkLock = new(6, 6);
    private ChartPeriod chartPeriod = ChartPeriod.All[0];
    private string recentSignature = "";

    private Task<JsonNode> Request(Dictionary<string, string> args) => client.RequestAsync(args);

    private async Task LoadPageAsync()
    {
        var version = ++revision;
        var selected = page;
        if (selected != "recent" || recentSignature.Length == 0) ResultsPanel.Children.Clear();
        if (selected != "recent") recentSignature = "";
        if (selected == "playing") { await LoadDetailsAsync(version); return; }
        if (selected == "settings") return;
        if (!client.Connected) { ResultsPanel.Children.Clear(); recentSignature = ""; AddRow("Connect last.fm", "Sign in below to see your activity."); return; }
        var user = client.Username!;
        bool Active() => version == revision && !closed && page == selected;
        switch (selected)
        {
            case "recent": await LoadRecentAsync(user, Active); break;
            case "friends": await LoadFriendsAsync(user, Active); break;
            case "reports": await LoadReportAsync(user, Active); break;
            default: await LoadProfileAsync(user, Active); break;
        }
        if (Active() && ResultsPanel.Children.Count == 0) AddRow("Nothing here yet", "Your last.fm activity will appear here.");
    }

    private async Task LoadRecentAsync(string user, Func<bool> active)
    {
        var json = await Request(new() { ["method"] = "user.getRecentTracks", ["user"] = user, ["limit"] = "50" });
        if (!active()) return;
        var rows = LastFmClient.Rows(json["recenttracks"]?["track"]).ToList();
        static bool NowPlaying(JsonNode row) => LastFmClient.Text(row["@attr"]?["nowplaying"]) == "true";
        var local = deviceIsPlaying ? current : null;
        var signature = local?.Title + "\n" + local?.Artist + "\n" + string.Join("\n", rows.Select(r =>
            LastFmClient.Text(r["name"]) + "|" + LastFmClient.Text(r["artist"]?["#text"]) + "|" + LastFmClient.Text(r["date"]?["uts"])));
        if (signature == recentSignature && ResultsPanel.Children.Count > 0) return;
        recentSignature = signature;
        ResultsPanel.Children.Clear();
        if (local != null)
            AddRow(local.OriginalTitle ?? local.Title, $"{local.Artist}\nNow playing", destination: MusicPresentation.TrackUrl(local.Artist, local.Title), highlighted: true, source: AlbumArtwork.Source);
        else if (rows.FirstOrDefault(NowPlaying) is { } remote)
        {
            var title = LastFmClient.Text(remote["name"]); var artist = LastFmClient.Text(remote["artist"]?["#text"]);
            AddRow(title, $"{artist}\nNow playing · on another device, according to last.fm", MusicPresentation.ImageUrls(remote["image"]), MusicPresentation.TrackUrl(artist, title), true);
        }
        foreach (var row in rows.Where(r => !NowPlaying(r)))
        {
            var title = LastFmClient.Text(row["name"]);
            var artist = LastFmClient.Text(row["artist"]?["#text"]);
            AddRow(title, $"{artist} · {LastFmClient.Text(row["album"]?["#text"])}\n{LastFmClient.Text(row["date"]?["#text"])}", MusicPresentation.ImageUrls(row["image"]), MusicPresentation.TrackUrl(artist, title));
        }
    }

    private async Task LoadFriendsAsync(string user, Func<bool> active)
    {
        var friends = new List<JsonNode>();
        var totalPages = 1;
        for (var number = 1; number <= totalPages; number++)
        {
            var json = await Request(new() { ["method"] = "user.getFriends", ["user"] = user, ["limit"] = "50", ["page"] = number.ToString() });
            if (!active()) return;
            if (number == 1) totalPages = (int)Math.Max(1, MusicPresentation.Count(json["friends"]?["@attr"]?["totalPages"]) ?? 1);
            friends.AddRange(LastFmClient.Rows(json["friends"]?["user"]));
        }
        var unique = friends.Where(f => LastFmClient.Text(f["name"]).Length > 0).DistinctBy(f => LastFmClient.Text(f["name"]), StringComparer.OrdinalIgnoreCase).ToList();
        using var gate = new SemaphoreSlim(6, 6);
        var latest = await Task.WhenAll(unique.Select(async friend =>
        {
            await gate.WaitAsync();
            try
            {
                var json = await Request(new() { ["method"] = "user.getRecentTracks", ["user"] = LastFmClient.Text(friend["name"]), ["limit"] = "1" });
                return LastFmClient.Rows(json["recenttracks"]?["track"]).FirstOrDefault();
            }
            catch { return null; }
            finally { gate.Release(); }
        }));
        if (!active()) return;
        for (var i = 0; i < unique.Count; i++)
        {
            var name = LastFmClient.Text(unique[i]["name"]);
            var track = latest[i] ?? LastFmClient.Rows(unique[i]["recenttrack"] ?? unique[i]["recenttracks"]?["track"]).FirstOrDefault();
            AddRow(name, MusicPresentation.FriendActivity(track, DateTimeOffset.UtcNow), MusicPresentation.ImageUrls(unique[i]["image"]), MusicPresentation.UserUrl(name));
        }
    }

    private async Task LoadProfileAsync(string user, Func<bool> active)
    {
        var info = await Request(new() { ["method"] = "user.getInfo", ["user"] = user });
        if (!active()) return;
        AddRow(LastFmClient.Text(info["user"]?["name"]), $"{LastFmClient.Text(info["user"]?["playcount"])} scrobbles · {LastFmClient.Text(info["user"]?["artist_count"])} artists", MusicPresentation.ImageUrls(info["user"]?["image"]), MusicPresentation.UserUrl(user));
        var periodChoice = new ComboBox { HorizontalAlignment = HorizontalAlignment.Right, ItemsSource = ChartPeriod.All.Select(p => p.Title).ToList(), SelectedIndex = Array.IndexOf(ChartPeriod.All, chartPeriod) };
        AutomationPropertiesName(periodChoice, "Chart period");
        periodChoice.SelectionChanged += async (_, _) =>
        {
            if (periodChoice.SelectedIndex < 0) return;
            chartPeriod = ChartPeriod.All[periodChoice.SelectedIndex];
            try { LocalStore.Save("profile-chart-period.json", chartPeriod.Key); } catch (Exception ex) { ShowError(ex); }
            await RunAsync(LoadPageAsync);
        };
        var header = new Grid { Margin = new Thickness(0, 8, 0, 0) };
        header.Children.Add(new TextBlock { Text = "Most played", FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        header.Children.Add(periodChoice);
        ResultsPanel.Children.Add(header);
        var loading = AddText("Loading charts…", secondary: true);
        var period = chartPeriod;
        var charts = await Task.WhenAll(ProfileCharts.Kinds.Select(kind => ProfileCharts.LoadAsync(Request, user, kind, period)));
        if (!active()) return;
        ResultsPanel.Children.Remove(loading);
        for (var k = 0; k < ProfileCharts.Kinds.Length; k++)
        {
            var kind = ProfileCharts.Kinds[k];
            var heading = new Grid();
            heading.Children.Add(new TextBlock { Text = ProfileCharts.Title(kind), FontSize = 17, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
            if (charts[k].Count > 0)
            {
                var more = new HyperlinkButton { Content = "See more", HorizontalAlignment = HorizontalAlignment.Right };
                ToolTipService.SetToolTip(more, $"Show your top 50 {kind} for {period.Title.ToLowerInvariant()}");
                more.Click += (_, _) => OpenGallery(kind);
                heading.Children.Add(more);
            }
            ResultsPanel.Children.Add(heading);
            if (charts[k].Count == 0) AddText("Nothing scrobbled in this period.", secondary: true);
            for (var i = 0; i < charts[k].Count; i++)
            {
                var entry = charts[k][i];
                var plays = $"{entry.Count:N0} plays";
                AddRow($"{i + 1}. {entry.Name}", kind == "artists" ? plays : $"{entry.Artist} · {plays}", entry.Images, entry.Url, portrait: kind == "artists" ? entry.Name : null);
            }
        }
    }

    private static void AutomationPropertiesName(DependencyObject element, string name) => Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(element, name);

    private async Task LoadReportAsync(string user, Func<bool> active)
    {
        var (start, end) = WeeklyReport.LatestWeek(DateTime.Now);
        var key = user.ToLowerInvariant() + "|" + start.ToString("yyyy-MM-dd");
        AddText($"{start:MMM d} – {end.AddDays(-1):MMM d}", 20, true);
        AddText("Next report " + WeeklyReport.NextReportDate(end).ToString("dddd, MMMM d"), secondary: true);
        if (!reports.TryGetValue(key, out var report))
        {
            var loading = AddText("Building your report…", secondary: true);
            try { report = await WeeklyReport.BuildAsync(Request, user, start, end); }
            catch (Exception e)
            {
                if (!active()) return;
                ResultsPanel.Children.Remove(loading);
                AddText("Couldn’t build your report. " + e.Message).Foreground = (Brush)Application.Current.Resources["SystemFillColorCriticalBrush"];
                return;
            }
            if (!active()) return;
            reports[key] = report;
            ResultsPanel.Children.Remove(loading);
        }
        var total = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        total.Children.Add(new TextBlock { Text = report.Scrobbles.ToString("N0"), FontSize = 36, FontWeight = Microsoft.UI.Text.FontWeights.Bold });
        total.Children.Add(new TextBlock { Text = "scrobbles", VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 8), Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] });
        if (report.PreviousScrobbles > 0)
        {
            var change = (double)(report.Scrobbles - report.PreviousScrobbles) / report.PreviousScrobbles;
            total.Children.Add(new TextBlock
            {
                Text = (change >= 0 ? "↗ " : "↘ ") + change.ToString("P0"), FontSize = 18, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(8, 0, 0, 8),
                Foreground = (Brush)Application.Current.Resources[change >= 0 ? "SystemFillColorSuccessBrush" : "SystemFillColorCriticalBrush"]
            });
        }
        ResultsPanel.Children.Add(total);
        AddText($"Previous week: {report.PreviousScrobbles:N0}", secondary: true);
        AddText("Top of the week", 17, true);
        if (report.TopArtist is { } artist) ReportRow(artist, "Top artist", true);
        if (report.TopAlbum is { } album) ReportRow(album, "Top album · " + album.Artist);
        if (report.TopTrack is { } track) ReportRow(track, "Top track · " + track.Artist);
        if (report.TopArtist == null) AddText("No scrobbles this week.", secondary: true);
        DiscoverySection("New artists", report.NewArtists, true);
        DiscoverySection("New albums", report.NewAlbums);
        DiscoverySection("New tracks", report.NewTracks);
        AddText($"Checks your {WeeklyReport.DiscoveryCheckLimit} most-played artists, albums and tracks of the week.", 12, secondary: true);
    }

    private void DiscoverySection(string title, IReadOnlyList<ReportItem> items, bool artists = false)
    {
        AddText(items.Count == 0 ? title : $"{title} ({items.Count})", 17, true);
        if (items.Count == 0) AddText("Nothing new this week.", secondary: true);
        foreach (var item in items) ReportRow(item, artists ? null : item.Artist, artists);
    }

    private void ReportRow(ReportItem item, string? subtitle, bool artist = false)
    {
        var plays = $"{item.Count:N0} play{(item.Count == 1 ? "" : "s")}";
        AddRow(item.Name, string.IsNullOrEmpty(subtitle) ? plays : $"{subtitle}\n{plays}", item.Images, item.Url, portrait: artist ? item.Name : null);
    }

    private TextBlock AddText(string text, double size = 14, bool bold = false, bool secondary = false)
    {
        var block = new TextBlock { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, FontWeight = bold ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal };
        if (secondary) block.Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        ResultsPanel.Children.Add(block);
        return block;
    }

    private void AddRow(string title, string detail, IEnumerable<Uri>? images = null, Uri? destination = null, bool highlighted = false, string? portrait = null, ImageSource? source = null)
    {
        var stack = new StackPanel { Spacing = 4 };
        stack.Children.Add(new TextBlock { Text = title, FontSize = 17, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        if (detail.Length > 0) stack.Children.Add(new TextBlock { Text = detail, Opacity = .9, TextWrapping = TextWrapping.Wrap, Foreground = (Brush)Application.Current.Resources[highlighted ? "AccentTextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush"], FontWeight = highlighted ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal });
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var candidates = images?.ToArray() ?? [];
        if (candidates.Length > 0 || portrait != null || source != null)
        {
            var cover = new Image { Width = 56, Height = 56, Stretch = Stretch.UniformToFill, Source = source };
            row.Children.Add(cover);
            var viewRevision = revision;
            var viewPage = page;
            bool Active() => !closed && revision == viewRevision && page == viewPage;
            if (portrait != null) _ = LoadPortraitAsync(cover, portrait, Active);
            else if (candidates.Length > 0) _ = LoadStillArtworkAsync(cover, candidates, Active);
        }
        Grid.SetColumn(stack, 1); row.Children.Add(stack);
        FrameworkElement content = row;
        if (destination != null)
            content = new HyperlinkButton { Content = row, NavigateUri = destination, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Foreground = (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"], Padding = new Thickness(0) };
        ResultsPanel.Children.Add(new Border { Child = content, Padding = new Thickness(16), CornerRadius = new CornerRadius(10), Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"], BorderBrush = highlighted ? (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"] : (Brush)Application.Current.Resources["ControlStrokeColorDefaultBrush"], BorderThickness = new Thickness(highlighted ? 2 : 1) });
    }

    private async Task LoadPortraitAsync(Image image, string artist, Func<bool> active)
    {
        try { var uri = await PortraitAsync(artist, active); if (active() && uri != null) image.Source = new BitmapImage(uri); }
        catch { }
    }

    private void OpenGallery(string kind)
    {
        if (!galleries.TryGetValue(kind, out var window) || window.IsClosed)
            galleries[kind] = window = new ChartGalleryWindow(kind,
                period => client.Username is { } user ? ProfileCharts.LoadAsync(Request, user, kind, period, 50) : Task.FromResult(new List<ChartEntry>()),
                (image, entry, active) => GalleryArtworkAsync(kind, image, entry, active));
        _ = window.ShowAsync(chartPeriod, RootGrid.ActualTheme);
    }

    private async Task GalleryArtworkAsync(string kind, Image image, ChartEntry entry, Func<bool> active)
    {
        if (kind == "artists") { await LoadPortraitAsync(image, entry.Name, active); return; }
        var urls = entry.Images;
        if (urls.Length == 0 && kind == "tracks")
        {
            await galleryArtworkLock.WaitAsync();
            try { if (active()) urls = await ProfileCharts.TrackArtworkAsync(Request, entry.Artist, entry.Name); }
            finally { galleryArtworkLock.Release(); }
        }
        if (urls.Length > 0 && active()) await LoadStillArtworkAsync(image, urls, active);
    }
}
