using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Net;
using System.Text.RegularExpressions;
using Windows.System;
using Windows.ApplicationModel.DataTransfer;
using System.Text.Json.Nodes;
using System.Security.Cryptography;
using System.IO.Compression;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Net.Http.Json;

namespace Scrap;

public sealed partial class MainWindow : Window
{
    private readonly LastFmClient client = new();
    private readonly MediaListener listener = new();
    private readonly ScrobbleEngine engine = new();
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly DispatcherTimer friendsTimer = new() { Interval = TimeSpan.FromHours(1) };
    private string page = "playing";
    private bool ready, ticking, actionBusy, closed, quitting;
    private TrayIcon? tray;
    private StartupSetting? startup;
    private bool startupEnabled;
    private int revision;
    private DateTimeOffset lastRetry = DateTimeOffset.MinValue;
    private PlayingTrack? current;
    private bool deviceIsPlaying;
    private string? accountInfoOwner;
    private MetadataCleanup cleanup = MetadataCleanup.Defaults;
    private readonly bool backgroundLaunch = Environment.GetCommandLineArgs().Any(a => string.Equals(a, "--background", StringComparison.OrdinalIgnoreCase));

    public MainWindow()
    {
        InitializeComponent();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Scrap.ico"));
        AppWindow.Resize(new Windows.Graphics.SizeInt32(920, 650));
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
        }
        SystemBackdrop = new MicaBackdrop();
        InstalledVersion.Text = "Scrap " + (typeof(MainWindow).Assembly.GetName().Version?.ToString(3) ?? "1.1.0");
        engine.Scrobble += client.Enqueue;
        engine.NowPlaying += track => _ = RunAsync(() => client.NowPlayingAsync(track));
        client.AccountChanged += () => { engine.Reset(); revision++; if (ready) DispatcherQueue.TryEnqueue(() => { ClearDetails(); if (page == "playing") _ = RunAsync(LoadPageAsync); }); };
        try
        {
            client.Initialize();
            cleanup = LocalStore.Load("metadata-cleanup.json", MetadataCleanup.Defaults);
            listener.Cleanup = cleanup;
            ScrobblingSwitch.IsOn = LocalStore.Load("scrobbling-enabled.json", true);
            client.Paused = !ScrobblingSwitch.IsOn;
            FirstArtistCheck.IsChecked = cleanup.FirstArtistOnly;
            PreserveArtistsPanel.Visibility = cleanup.FirstArtistOnly ? Visibility.Visible : Visibility.Collapsed;
            AlbumSuffixCheck.IsChecked = cleanup.RemoveAlbumSuffixes;
            PreservedArtistsBox.Text = string.Join(Environment.NewLine, cleanup.ArtistsToPreserve);
            ThemeChoice.SelectedIndex = LocalStore.Load("theme.json", "System") switch { "Light" => 1, "Dark" => 2, _ => 0 };
            DailyUpdateCheck.IsChecked = LocalStore.Load("daily-update-check.json", true);
            AutoInstallUpdates.IsChecked = LocalStore.Load("auto-install-updates.json", false);
            ApplyTheme();
            RefreshCleanupPreview();
        }
        catch (Exception e) { ShowError(e); }
        try
        {
            startup = WindowsStartup.Create();
            startupEnabled = startup.Enabled;
            StartupCheck.IsChecked = startupEnabled;
        }
        catch (Exception e) { StartupCheck.IsEnabled = false; ShowError(e); }
        if (backgroundLaunch) AppWindow.Hide();
        try
        {
            tray = new TrayIcon(WinRT.Interop.WindowNative.GetWindowHandle(this),
                () => DispatcherQueue.TryEnqueue(RestoreFromTray),
                () => DispatcherQueue.TryEnqueue(() => { quitting = true; Close(); }),
                () => DispatcherQueue.TryEnqueue(() => { RestoreFromTray(); Navigation.SelectedItem = Navigation.SettingsItem; }),
                () => DispatcherQueue.TryEnqueue(() => _ = ShowTrayMenuAsync()),
                () => DispatcherQueue.TryEnqueue(() => OpenTagEditor("track")),
                () => DispatcherQueue.TryEnqueue(() => OpenTagEditor("artist")));
        }
        catch (Exception e) { ShowError(e); }
        AppWindow.Closing += (_, args) =>
        {
            if (!quitting && tray?.Available == true)
            {
                args.Cancel = true;
                AppWindow.Hide();
                tray.NotifyHidden();
            }
        };
        ready = true;
        timer.Tick += Tick;
        timer.Start();
        friendsTimer.Tick += async (_, _) => { if (page == "friends" && !closed) await RunAsync(LoadPageAsync); };
        friendsTimer.Start();
        Closed += (_, _) => { closed = true; timer.Stop(); friendsTimer.Stop(); engine.Suspend(); tray?.Dispose(); client.Dispose(); artworkHttp.Dispose(); };
        UpdateStatus();
        if (DailyUpdateCheck.IsChecked == true) _ = CheckDailyUpdateAsync();
    }

    private void RestoreFromTray()
    {
        AppWindow.Show();
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter) presenter.Restore();
        Activate();
    }

    private async void Tick(object? sender, object e)
    {
        if (ticking || closed) return;
        ticking = true;
        try
        {
            var sample = await listener.ReadAsync();
            if (closed) return;
            var changed = current?.Title != sample.Track?.Title || current?.Artist != sample.Track?.Artist || current?.Album != sample.Track?.Album;
            current = sample.Track;
            deviceIsPlaying = sample.Playing;
            engine.Update(client.Connected ? current : null, sample.Playing && !client.Paused && client.Connected, DateTimeOffset.UtcNow, sample.Restarted);
            TrackTitle.Text = current?.Title ?? "Nothing playing";
            ArtistName.Text = current == null ? "Play something in Apple Music." : ScrobbleLabel(current.OriginalArtist, current.Artist);
            AlbumName.Text = current == null ? "" : ScrobbleLabel(current.OriginalAlbum, current.Album);
            AlbumSeparator.Text = string.IsNullOrEmpty(current?.Album) ? "" : " - ";
            if (changed)
            {
                SongLink.NavigateUri = current == null ? null : MusicPresentation.TrackUrl(current.Artist, current.Title);
                ArtistLink.NavigateUri = current == null ? null : MusicPresentation.ArtistUrl(current.Artist);
                AlbumLink.NavigateUri = current == null || current.Album.Length == 0 ? null : MusicPresentation.AlbumUrl(current.Artist, current.Album);
                TrackLoved.Visibility = Visibility.Collapsed;
                if (current is { } lovedTrack && client.Connected) _ = RefreshLovedStateAsync(lovedTrack);
            }
            Progress.Value = current?.Duration is > 30 ? Math.Min(1, engine.PlayedSeconds / Math.Min(240, current.Duration.Value / 2)) : 0;
            PlaybackStatus.Text = current == null ? "Waiting for a media session…" : !client.Connected ? "Connect Last.fm below to scrobble." : client.Paused ? "Scrobbling paused" : !sample.Playing ? "Playback paused" : current.Duration == null ? "Duration unavailable — this track cannot be scrobbled yet." : current.Duration <= 30 ? "Tracks of 30 seconds or less are not scrobbled." : engine.Submitted ? "Scrobble queued or submitted" : $"{engine.PlayedSeconds:0} seconds listened";
            if (changed) { ClearDetails(); if (page == "playing") { revision++; _ = RunAsync(LoadPageAsync); } }
            if (DateTimeOffset.UtcNow - lastRetry > TimeSpan.FromSeconds(60) && !actionBusy)
            {
                lastRetry = DateTimeOffset.UtcNow;
                await client.RetryAsync();
            }
            UpdateStatus();
        }
        catch (Exception ex) { engine.Suspend(); if (!closed) ShowError(ex); }
        finally { ticking = false; }
    }

    private async Task RunAsync(Func<Task> action)
    {
        try { await action(); if (!closed) UpdateStatus(); }
        catch (Exception e) { if (!closed) ShowError(e); }
    }
    private async Task UserActionAsync(Func<Task> action)
    {
        if (actionBusy) return;
        actionBusy = true;
        try { await RunAsync(action); }
        finally { actionBusy = false; }
    }
    private void ShowError(Exception e) { ErrorBar.Message = e.Message; ErrorBar.IsOpen = true; }
    private void UpdateStatus()
    {
        var status = $"{client.Status}  ·  {client.PendingCount} pending";
        AccountStatus.Text = MainAccountStatus.Text = status;
        if (!client.Connected)
        {
            AccountInfo.Text = "Not connected to Last.fm";
            AccountAvatar.Source = null;
            AccountProfileLink.Visibility = Visibility.Collapsed;
            accountInfoOwner = null;
        }
        else if (!string.Equals(accountInfoOwner, client.Username, StringComparison.Ordinal))
        {
            AccountInfo.Text = $"Connected as {client.Username}";
            AccountAvatar.Source = null;
            AccountProfileLink.Visibility = Visibility.Collapsed;
            accountInfoOwner = client.Username;
        }
        MainAccountControls.Visibility = page == "settings" ? Visibility.Collapsed : Visibility.Visible;
        MainConnectButton.Visibility = ConnectButton.Visibility = client.Connected || client.PendingToken != null ? Visibility.Collapsed : Visibility.Visible;
        MainConnectButton.IsEnabled = ConnectButton.IsEnabled = client.Configured;
        MainApproveButton.Visibility = ApproveButton.Visibility = client.PendingToken != null ? Visibility.Visible : Visibility.Collapsed;
        MainSignOutButton.Visibility = SignOutButton.Visibility = client.Connected ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void SettingsTabChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!ready || SettingsTabs.SelectedItem is not TabViewItem { Header: "last.fm Accounts" }) return;
        if (!client.Connected || client.Username == null) { AccountInfo.Text = "Not connected to Last.fm"; return; }
        try
        {
            var info = await client.RequestAsync(new() { ["method"] = "user.getInfo", ["user"] = client.Username });
            var user = info["user"];
            var name = LastFmClient.Text(user?["realname"]);
            var username = LastFmClient.Text(user?["name"]);
            var plays = LastFmClient.Text(user?["playcount"]);
            AccountInfo.Text = $"{(name.Length > 0 ? name + " · " : "")}{plays} scrobbles";
            if (Uri.TryCreate(LastFmClient.Text(user?["url"]), UriKind.Absolute, out var profileUrl) && profileUrl.Scheme == "https" && (profileUrl.Host == "last.fm" || profileUrl.Host.EndsWith(".last.fm", StringComparison.OrdinalIgnoreCase)))
            {
                AccountProfileLink.Content = "@" + username + " on Last.fm";
                AccountProfileLink.NavigateUri = profileUrl;
                AccountProfileLink.Visibility = Visibility.Visible;
            }
            else AccountProfileLink.Visibility = Visibility.Collapsed;
            var avatar = MusicPresentation.ImageUrl(user?["image"]);
            AccountAvatar.Source = avatar == null ? null : new BitmapImage(avatar);
            accountInfoOwner = client.Username;
        }
        catch (Exception ex) { AccountAvatar.Source = null; AccountProfileLink.Visibility = Visibility.Collapsed; accountInfoOwner = client.Username; AccountInfo.Text = $"Connected as {client.Username}\nAccount details unavailable: {ex.Message}"; }
    }

    private async void Navigate(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (!ready) return;
        page = args.IsSettingsSelected ? "settings" : (args.SelectedItem as NavigationViewItem)?.Tag?.ToString() ?? "playing";
        Heading.Text = page switch { "recent" => "Scrobbles", "profile" => "Profile", "friends" => "Friends", "settings" => "Settings", _ => "Now Playing" };
        PlayingPanel.Visibility = page == "playing" ? Visibility.Visible : Visibility.Collapsed;
        SettingsPanel.Visibility = page == "settings" ? Visibility.Visible : Visibility.Collapsed;
        ResultsPanel.Visibility = page is "recent" or "profile" or "friends" ? Visibility.Visible : Visibility.Collapsed;
        RefreshButton.Visibility = page == "settings" ? Visibility.Collapsed : Visibility.Visible;
        await RunAsync(LoadPageAsync);
    }

    private async Task LoadPageAsync()
    {
        var version = ++revision;
        var selected = page;
        ResultsPanel.Children.Clear();
        if (selected == "playing") { await LoadDetailsAsync(version); return; }
        if (!client.Connected) { AddRow("Connect Last.fm", "Sign in below to see your activity."); return; }
        var user = client.Username!;
        var args = new Dictionary<string, string> { ["user"] = user, ["limit"] = "50" };
        if (selected == "settings") return;
        args["method"] = selected switch { "recent" => "user.getRecentTracks", "friends" => "user.getFriends", _ => "user.getInfo" };
        if (selected == "friends") args["recenttracks"] = "1";
        if (selected == "friends") args["page"] = "1";
        var json = await client.RequestAsync(args);
        if (version != revision || closed) return;
        if (selected == "recent")
        {
            foreach (var row in LastFmClient.Rows(json["recenttracks"]?["track"]))
            {
                var title = LastFmClient.Text(row["name"]);
                var artist = LastFmClient.Text(row["artist"]?["#text"]);
                var nowPlaying = LastFmClient.Text(row["@attr"]?["nowplaying"]) == "true";
                var localMatch = nowPlaying && deviceIsPlaying && current != null &&
                    string.Equals(current.Title, title, StringComparison.OrdinalIgnoreCase) &&
                    (string.Equals(current.Artist, artist, StringComparison.OrdinalIgnoreCase) || string.Equals(current.OriginalArtist, artist, StringComparison.OrdinalIgnoreCase));
                var activity = localMatch ? "Now playing" : nowPlaying ? "Playing on another device" : LastFmClient.Text(row["date"]?["#text"]);
                AddRow(title, $"{artist} · {LastFmClient.Text(row["album"]?["#text"])}\n{activity}", MusicPresentation.ImageUrl(row["image"]), MusicPresentation.TrackUrl(artist, title), localMatch);
            }
        }
        else if (selected == "friends")
        {
            var friends = new List<JsonNode>();
            var page = 1;
            var totalPages = Math.Max(1, MusicPresentation.Count(json["friends"]?["@attr"]?["totalPages"]) ?? 1);
            friends.AddRange(LastFmClient.Rows(json["friends"]?["user"]));
            while (page < totalPages && version == revision && !closed)
            {
                page++;
                var next = await client.RequestAsync(new() { ["method"] = "user.getFriends", ["user"] = user, ["recenttracks"] = "1", ["limit"] = "50", ["page"] = page.ToString() });
                if (version != revision || closed) return;
                friends.AddRange(LastFmClient.Rows(next["friends"]?["user"]));
            }
            var seenFriends = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var row in friends)
            {
                var name = LastFmClient.Text(row["name"]);
                if (name.Length == 0 || !seenFriends.Add(name)) continue;
                var recent = LastFmClient.Rows(row["recenttrack"] ?? row["recenttracks"]?["track"]).FirstOrDefault();
                AddRow(name, recent == null ? "No recent listening available" : $"{LastFmClient.Text(recent["name"])} · {LastFmClient.Text(recent["artist"]?["#text"])}", MusicPresentation.ImageUrl(row["image"]), MusicPresentation.UserUrl(name));
            }
        }
        else
        {
            AddRow(LastFmClient.Text(json["user"]?["name"]), $"{LastFmClient.Text(json["user"]?["playcount"])} scrobbles · {LastFmClient.Text(json["user"]?["artist_count"])} artists", MusicPresentation.ImageUrl(json["user"]?["image"]), MusicPresentation.UserUrl(user));
            foreach (var kind in new[] { "artists", "albums", "tracks" })
            {
                var chart = await client.RequestAsync(new() { ["method"] = "user.getTop" + char.ToUpperInvariant(kind[0]) + kind[1..], ["user"] = user, ["period"] = "overall", ["limit"] = "5" });
                if (version != revision || closed) return;
                AddRow("Top " + kind + " · All time", "");
                foreach (var row in LastFmClient.Rows(chart["top" + kind]?[kind[..^1]]))
                    AddRow(LastFmClient.Text(row["name"]), $"{LastFmClient.Text(row["playcount"])} plays", MusicPresentation.ImageUrl(row["image"]), MusicPresentation.ChartUrl(kind, row));
            }
        }
        if (ResultsPanel.Children.Count == 0) AddRow("Nothing here yet", "Your Last.fm activity will appear here.");
    }

    private void AddRow(string title, string detail, Uri? image = null, Uri? destination = null, bool highlighted = false)
    {
        var stack = new StackPanel { Spacing = 4 };
        stack.Children.Add(new TextBlock { Text = title, FontSize = 17, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        if (detail.Length > 0) stack.Children.Add(new TextBlock { Text = detail, Opacity = .9, TextWrapping = TextWrapping.Wrap, Foreground = (Brush)Application.Current.Resources[highlighted ? "AccentTextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush"], FontWeight = highlighted ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal });
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        if (image != null) row.Children.Add(new Image { Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(image), Width = 56, Height = 56, Stretch = Stretch.UniformToFill });
        Grid.SetColumn(stack, 1); row.Children.Add(stack);
        FrameworkElement content = row;
        if (destination != null)
            content = new HyperlinkButton { Content = row, NavigateUri = destination, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Foreground = (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"], Padding = new Thickness(0) };
        ResultsPanel.Children.Add(new Border { Child = content, Padding = new Thickness(16), CornerRadius = new CornerRadius(10), Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"], BorderBrush = highlighted ? (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"] : (Brush)Application.Current.Resources["ControlStrokeColorDefaultBrush"], BorderThickness = new Thickness(highlighted ? 2 : 1) });
    }
    private async void Refresh(object sender, RoutedEventArgs e) => await RunAsync(LoadPageAsync);
    private async void Connect(object sender, RoutedEventArgs e) => await UserActionAsync(async () => { var uri = await client.BeginAuthAsync(); if (!await Launcher.LaunchUriAsync(uri)) throw new InvalidOperationException("Could not open the browser."); });
    private async void Approve(object sender, RoutedEventArgs e) => await UserActionAsync(async () => { await client.CompleteAuthAsync(); await client.RetryAsync(); });
    private async void SignOut(object sender, RoutedEventArgs e) => await UserActionAsync(() => { client.SignOut(); TrackDetails.Text = ""; ResultsPanel.Children.Clear(); return Task.CompletedTask; });
    private async void Retry(object sender, RoutedEventArgs e) => await UserActionAsync(client.RetryAsync);
    private async void Love(object sender, RoutedEventArgs e) { if (current is { } track) { await UserActionAsync(() => client.LoveAsync(track, true)); await RefreshLovedStateAsync(track); } }
    private async void Unlove(object sender, RoutedEventArgs e) { if (current is { } track) { await UserActionAsync(() => client.LoveAsync(track, false)); await RefreshLovedStateAsync(track); } }
    private async void OpenTrack(object sender, RoutedEventArgs e) { if (current is { } track) await RunAsync(async () => { await Launcher.LaunchUriAsync(new Uri($"https://www.last.fm/music/{Uri.EscapeDataString(track.Artist)}/_/{Uri.EscapeDataString(track.Title)}")); }); }
    private async void TagTrack(object sender, RoutedEventArgs e) { if (current is { } track) await EditTagsAsync("track", track, track.Artist); }
    private async void TagArtist(object sender, RoutedEventArgs e) { if (current is { } track) await EditTagsAsync("artist", track, track.Artist); }
    private void OpenTagEditor(string kind)
    {
        if (current is not { } track || !client.Connected) return;
        RestoreFromTray();
        _ = EditTagsAsync(kind, track, track.Artist);
    }

    private async Task EditTagsAsync(string kind, PlayingTrack track, string artist)
    {
        if (!client.Connected) { ShowError(new InvalidOperationException("Connect Last.fm to manage tags.")); return; }
        await UserActionAsync(async () =>
        {
            var own = kind == "track" ? await client.TrackTagsAsync(track) : await client.ArtistTagsAsync(artist);
            var community = kind == "track" ? await client.TrackTagsAsync(track, true) : await client.ArtistTagsAsync(artist, true);
            var tagKey = kind == "track" ? "tags" : "tags";
            var ownRows = LastFmClient.Rows(own[kind]?[tagKey]?["tag"]).Select(t => LastFmClient.Text(t["name"])).Where(t => t.Length > 0).ToArray();
            var communityRoot = kind == "track" ? "toptags" : "toptags";
            var communityRows = LastFmClient.Rows(community[communityRoot]?["tag"]).Select(t => LastFmClient.Text(t["name"])).Where(t => t.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).Take(30).ToArray();
            var choices = ownRows.Concat(communityRows).Distinct(StringComparer.OrdinalIgnoreCase).Take(30).ToArray();
            var choicesPanel = new StackPanel { Spacing = 4, MaxHeight = 280 };
            var checks = new List<CheckBox>();
            foreach (var tag in choices)
            {
                var check = new CheckBox { Content = tag, IsChecked = ownRows.Contains(tag, StringComparer.OrdinalIgnoreCase) };
                checks.Add(check); choicesPanel.Children.Add(check);
            }
            var custom = new TextBox { Header = "Add tags (comma separated, up to 10)" };
            var content = new StackPanel { Spacing = 8 };
            content.Children.Add(new TextBlock { Text = "Your tags are selected. Choose community tags or add new ones." });
            content.Children.Add(choicesPanel); content.Children.Add(custom);
            var dialog = new ContentDialog { Title = $"Tag {kind}", Content = content, PrimaryButtonText = "Apply", CloseButtonText = "Cancel", XamlRoot = Content.XamlRoot };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            var selected = checks.Where(c => c.IsChecked == true).Select(c => c.Content?.ToString() ?? "")
                .Concat(custom.Text.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
                .Where(t => t.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).Take(10).ToArray();
            if (kind == "track") await client.AddTrackTagsAsync(track, selected); else await client.AddArtistTagsAsync(artist, selected);
        });
    }

    private void CleanupChanged(object sender, RoutedEventArgs e) => SaveCleanupSettings();
    private void PreservedArtistsChanged(object sender, TextChangedEventArgs e) => SaveCleanupSettings();
    private void SaveCleanupSettings()
    {
        if (!ready) return;
        cleanup = new MetadataCleanup(FirstArtistCheck.IsChecked == true, AlbumSuffixCheck.IsChecked == true,
            PreservedArtistsBox.Text.Split(Environment.NewLine, StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries));
        PreserveArtistsPanel.Visibility = cleanup.FirstArtistOnly ? Visibility.Visible : Visibility.Collapsed;
        listener.Cleanup = cleanup;
        try { LocalStore.Save("metadata-cleanup.json", cleanup); }
        catch (Exception ex) { ShowError(ex); }
        RefreshCleanupPreview();
        engine.Reset();
        current = null;
    }
    private void RefreshCleanupPreview()
    {
        CleanupPreview.Text = "Artist example:\nHours In Silence\nDrake & 21 Savage (scrobbling as Drake) - Her Loss\n\nAlbum example:\nbfo2\nSummrs - What We Have - EP (scrobbling as What we have)";
    }
    private static string ScrobbleLabel(string? original, string cleaned) =>
        !string.IsNullOrWhiteSpace(original) && !string.Equals(original, cleaned, StringComparison.Ordinal)
            ? $"{original} (scrobbling as {cleaned})" : cleaned;
    private void ThemeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!ready) return;
        var choice = (ThemeChoice.SelectedItem as ComboBoxItem)?.Content?.ToString() ?? "System";
        LocalStore.Save("theme.json", choice); ApplyTheme();
    }
    private void ApplyTheme()
    {
        if (Navigation == null || ThemeChoice.SelectedIndex < 0) return;
        RootGrid.RequestedTheme = ThemeChoice.SelectedIndex switch { 1 => ElementTheme.Light, 2 => ElementTheme.Dark, _ => ElementTheme.Default };
    }

    private async void ShareTrack(object sender, RoutedEventArgs e)
    {
        if (current is not { } track) return;
        await RunAsync(() => { ShareSheet.Show(WinRT.Interop.WindowNative.GetWindowHandle(this), MusicPresentation.TrackUrl(track.Artist, track.Title), track.Title); return Task.CompletedTask; });
    }

    private async Task RefreshLovedStateAsync(PlayingTrack track)
    {
        try
        {
            var loved = await client.IsLovedAsync(track);
            if (!closed && current == track) TrackLoved.Visibility = loved ? Visibility.Visible : Visibility.Collapsed;
        }
        catch { }
    }

    private async void CheckUpdates(object sender, RoutedEventArgs e) => await RunAsync(() => CheckForUpdateAsync(true));

    private void UpdatePreferencesChanged(object sender, RoutedEventArgs e)
    {
        if (!ready) return;
        LocalStore.Save("daily-update-check.json", DailyUpdateCheck.IsChecked == true);
        LocalStore.Save("auto-install-updates.json", AutoInstallUpdates.IsChecked == true);
    }

    private async Task CheckDailyUpdateAsync()
    {
        var last = LocalStore.Load("last-update-check.json", DateTimeOffset.MinValue);
        if (DateTimeOffset.UtcNow - last < TimeSpan.FromHours(24)) return;
        try
        {
            await CheckForUpdateAsync(false);
            LocalStore.Save("last-update-check.json", DateTimeOffset.UtcNow);
        }
        catch (Exception e) { if (!closed) UpdateCheckStatus.Text = "Update check failed: " + e.Message; }
    }

    private async Task CheckForUpdateAsync(bool showCurrent)
    {
        UpdateCheckStatus.Text = "Checking for updates…";
        using var http = new HttpClient();
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Scrap-Windows/1.1");
        http.Timeout = TimeSpan.FromSeconds(25);
        var releases = await http.GetFromJsonAsync<JsonArray>("https://api.github.com/repos/swagdotsh/scrap/releases?per_page=100")
            ?? throw new InvalidOperationException("GitHub returned no release information.");
        var candidates = LastFmClient.Rows(releases)
            .Where(r => LastFmClient.Text(r["draft"]) != "true" && LastFmClient.Text(r["prerelease"]) != "true" &&
                string.Equals(LastFmClient.Text(r["target_commitish"]), "windows-app-sdk", StringComparison.OrdinalIgnoreCase))
            .Select(r => (Release: r, Tag: LastFmClient.Text(r["tag_name"])))
            .Select(candidate => (candidate.Release, candidate.Tag, Version: ParseReleaseVersion(candidate.Tag)))
            .Where(candidate => candidate.Version != null)
            .OrderByDescending(candidate => candidate.Version)
            .ToArray();
        if (candidates.Length == 0)
        {
            UpdateCheckStatus.Text = "No published releases were found for the windows-app-sdk branch.";
            return;
        }
        var release = candidates[0].Release;
        var latest = candidates[0].Version!;
        var currentVersion = typeof(MainWindow).Assembly.GetName().Version ?? new Version(1, 1);
        if (latest <= currentVersion) { UpdateCheckStatus.Text = "Scrap is up to date (" + currentVersion + ")."; return; }
        var asset = LastFmClient.Rows(release["assets"]).FirstOrDefault(a =>
            LastFmClient.Text(a["name"]).EndsWith(".zip", StringComparison.OrdinalIgnoreCase) &&
            (LastFmClient.Text(a["name"]).Contains("windows", StringComparison.OrdinalIgnoreCase) || LastFmClient.Text(a["name"]).Contains("win-x64", StringComparison.OrdinalIgnoreCase)));
        var digest = LastFmClient.Text(asset?["digest"]);
        var download = LastFmClient.Text(asset?["browser_download_url"]);
        if (asset == null || !digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase) || !Uri.TryCreate(download, UriKind.Absolute, out var uri) || uri.Host != "github.com")
        {
            UpdateCheckStatus.Text = $"Scrap {latest} is available, but this release has no Windows ZIP with a SHA-256 digest.";
            return;
        }
        UpdateCheckStatus.Text = $"Scrap {latest} is available. Downloading and verifying…";
        var bytes = await http.GetByteArrayAsync(uri);
        if (bytes.Length == 0 || bytes.Length > 500_000_000) throw new InvalidOperationException("The update archive size is invalid.");
        var expected = digest[7..].ToLowerInvariant();
        var actual = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
        if (!CryptographicOperations.FixedTimeEquals(Convert.FromHexString(expected), Convert.FromHexString(actual)))
            throw new InvalidOperationException("The update archive failed SHA-256 verification.");
        var archive = Path.Combine(Path.GetTempPath(), "Scrap-update-" + latest + ".zip");
        await File.WriteAllBytesAsync(archive, bytes);
        var auto = AutoInstallUpdates.IsChecked == true;
        if (!auto && showCurrent)
        {
            var dialog = new ContentDialog { Title = $"Scrap {latest} is ready", Content = "The Windows release ZIP passed its published SHA-256 check. Install and restart Scrap now?", PrimaryButtonText = "Install and restart", CloseButtonText = "Later", XamlRoot = Content.XamlRoot };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) { UpdateCheckStatus.Text = $"Scrap {latest} downloaded and verified. Choose Check for updates to install it."; return; }
        }
        else if (!auto) { UpdateCheckStatus.Text = $"Scrap {latest} is available. Choose Check for updates to install it."; return; }
        ScheduleVerifiedInstall(archive, latest);
    }

    private static Version? ParseReleaseVersion(string tag)
    {
        if (tag.StartsWith("windows-", StringComparison.OrdinalIgnoreCase)) tag = tag["windows-".Length..];
        return Version.TryParse(tag.TrimStart('v'), out var version) ? version : null;
    }

    private void ScheduleVerifiedInstall(string archive, Version version)
    {
        var stage = Path.Combine(Path.GetTempPath(), "Scrap-stage-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(stage);
        ZipFile.ExtractToDirectory(archive, stage);
        var exe = Directory.GetFiles(stage, "Scrap.exe", SearchOption.AllDirectories).FirstOrDefault()
            ?? throw new InvalidOperationException("The verified archive does not contain Scrap.exe.");
        var payload = Path.GetDirectoryName(exe)!;
        var script = Path.Combine(Path.GetTempPath(), "Scrap-install-" + Guid.NewGuid().ToString("N") + ".ps1");
        var install = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        var backup = install + ".previous";
        var relaunchArgs = backgroundLaunch ? "--background" : "";
        File.WriteAllText(script, $$"""
            $ErrorActionPreference = 'Stop'
            $p = '{{PowerShellEscape(install)}}'; $b = '{{PowerShellEscape(backup)}}'; $s = '{{PowerShellEscape(payload)}}'; $a = '{{relaunchArgs}}'
            Start-Sleep -Seconds 2
            if (Test-Path -LiteralPath $b) { Remove-Item -LiteralPath $b -Recurse -Force }
            Move-Item -LiteralPath $p -Destination $b
            try { Move-Item -LiteralPath $s -Destination $p; $envFile = Join-Path $b '.env'; if (Test-Path -LiteralPath $envFile -PathType Leaf) { Copy-Item -LiteralPath $envFile -Destination (Join-Path $p '.env') }; if ($a) { Start-Process -FilePath (Join-Path $p 'Scrap.exe') -ArgumentList $a } else { Start-Process -FilePath (Join-Path $p 'Scrap.exe') } }
            catch { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }; Move-Item -LiteralPath $b -Destination $p; if ($a) { Start-Process -FilePath (Join-Path $p 'Scrap.exe') -ArgumentList $a } else { Start-Process -FilePath (Join-Path $p 'Scrap.exe') }; throw }
            Remove-Item -LiteralPath '{{PowerShellEscape(stage)}}' -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath '{{PowerShellEscape(archive)}}' -Force -ErrorAction SilentlyContinue
            """);
        Process.Start(new ProcessStartInfo("powershell.exe", $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{script}\"") { CreateNoWindow = true, UseShellExecute = false });
        UpdateCheckStatus.Text = $"Installing Scrap {version} and restarting…";
        quitting = true; Close();
    }

    private static string PowerShellEscape(string value) => value.Replace("'", "''");
    private void ToggleScrobbling(object sender, RoutedEventArgs e)
    {
        if (!ready) return;
        client.Paused = !ScrobblingSwitch.IsOn;
        engine.Suspend();
        try { LocalStore.Save("scrobbling-enabled.json", ScrobblingSwitch.IsOn); } catch (Exception ex) { ShowError(ex); }
    }

    private void ToggleStartup(object sender, RoutedEventArgs e)
    {
        if (!ready || startup == null) return;
        try
        {
            startup.SetEnabled(StartupCheck.IsChecked == true);
            startupEnabled = startup.Enabled;
            StartupCheck.IsChecked = startupEnabled;
        }
        catch (Exception ex) { StartupCheck.IsChecked = startupEnabled; ShowError(ex); }
    }
}
