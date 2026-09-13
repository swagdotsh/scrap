using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using System.Net;
using System.Text.RegularExpressions;
using Windows.System;

namespace Scrap;

public sealed partial class MainWindow : Window
{
    private readonly LastFmClient client = new();
    private readonly MediaListener listener = new();
    private readonly ScrobbleEngine engine = new();
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private string page = "playing";
    private bool ready, ticking, actionBusy, closed, quitting;
    private TrayIcon? tray;
    private StartupSetting? startup;
    private bool startupEnabled;
    private int revision;
    private DateTimeOffset lastRetry = DateTimeOffset.MinValue;
    private PlayingTrack? current;

    public MainWindow()
    {
        InitializeComponent();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Scrap.ico"));
        AppWindow.Resize(new Windows.Graphics.SizeInt32(920, 650));
        SystemBackdrop = new MicaBackdrop();
        engine.Scrobble += client.Enqueue;
        engine.NowPlaying += track => _ = RunAsync(() => client.NowPlayingAsync(track));
        client.AccountChanged += () => { engine.Reset(); revision++; if (ready) DispatcherQueue.TryEnqueue(() => { ClearDetails(); if (page == "playing") _ = RunAsync(LoadPageAsync); }); };
        try
        {
            client.Initialize();
            ScrobblingSwitch.IsOn = LocalStore.Load("scrobbling-enabled.json", true);
            client.Paused = !ScrobblingSwitch.IsOn;
        }
        catch (Exception e) { ShowError(e); }
        try
        {
            startup = WindowsStartup.Create();
            startupEnabled = startup.Enabled;
            StartupCheck.IsChecked = startupEnabled;
        }
        catch (Exception e) { StartupCheck.IsEnabled = false; ShowError(e); }
        try
        {
            tray = new TrayIcon(WinRT.Interop.WindowNative.GetWindowHandle(this),
                () => DispatcherQueue.TryEnqueue(RestoreFromTray),
                () => DispatcherQueue.TryEnqueue(() => { quitting = true; Close(); }),
                () => DispatcherQueue.TryEnqueue(() => { RestoreFromTray(); Navigation.SelectedItem = Navigation.SettingsItem; }),
                () => DispatcherQueue.TryEnqueue(() => _ = ShowTrayMenuAsync()));
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
        Closed += (_, _) => { closed = true; timer.Stop(); engine.Suspend(); tray?.Dispose(); client.Dispose(); artworkHttp.Dispose(); };
        UpdateStatus();
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
            engine.Update(client.Connected ? current : null, sample.Playing && !client.Paused && client.Connected, DateTimeOffset.UtcNow, sample.Restarted);
            TrackTitle.Text = current?.Title ?? "Nothing playing";
            ArtistName.Text = current?.Artist ?? "Play something in Apple Music.";
            AlbumName.Text = current?.Album ?? "";
            AlbumSeparator.Text = string.IsNullOrEmpty(current?.Album) ? "" : " - ";
            if (changed)
            {
                SongLink.NavigateUri = current == null ? null : MusicPresentation.TrackUrl(current.Artist, current.Title);
                ArtistLink.NavigateUri = current == null ? null : MusicPresentation.ArtistUrl(current.Artist);
                AlbumLink.NavigateUri = current == null || current.Album.Length == 0 ? null : MusicPresentation.AlbumUrl(current.Artist, current.Album);
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
        AccountStatus.Text = $"{client.Status}  ·  {client.PendingCount} pending";
        AccountControls.Visibility = page == "settings" ? Visibility.Collapsed : Visibility.Visible;
        ConnectButton.Visibility = client.Connected || client.PendingToken != null ? Visibility.Collapsed : Visibility.Visible;
        ConnectButton.IsEnabled = client.Configured;
        ApproveButton.Visibility = client.PendingToken != null ? Visibility.Visible : Visibility.Collapsed;
        SignOutButton.Visibility = client.Connected ? Visibility.Visible : Visibility.Collapsed;
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
        var args = new Dictionary<string, string> { ["user"] = user, ["limit"] = "30" };
        if (selected == "settings") return;
        args["method"] = selected switch { "recent" => "user.getRecentTracks", "friends" => "user.getFriends", _ => "user.getInfo" };
        if (selected == "friends") args["recenttracks"] = "1";
        var json = await client.RequestAsync(args);
        if (version != revision || closed) return;
        if (selected == "recent")
        {
            foreach (var row in LastFmClient.Rows(json["recenttracks"]?["track"]))
                AddRow(LastFmClient.Text(row["name"]), $"{LastFmClient.Text(row["artist"]?["#text"])} · {LastFmClient.Text(row["album"]?["#text"])}\n{(LastFmClient.Text(row["@attr"]?["nowplaying"]) == "true" ? "Now playing" : LastFmClient.Text(row["date"]?["#text"]))}", MusicPresentation.ImageUrl(row["image"]), MusicPresentation.TrackUrl(LastFmClient.Text(row["artist"]?["#text"]), LastFmClient.Text(row["name"])));
        }
        else if (selected == "friends")
        {
            foreach (var row in LastFmClient.Rows(json["friends"]?["user"]))
                AddRow(LastFmClient.Text(row["name"]), row["recenttrack"] == null ? "No recent listening shared" : $"{LastFmClient.Text(row["recenttrack"]?["artist"]?["#text"])} · {LastFmClient.Text(row["recenttrack"]?["name"])}", MusicPresentation.ImageUrl(row["image"]), MusicPresentation.UserUrl(LastFmClient.Text(row["name"])));
        }
        else
        {
            AddRow(LastFmClient.Text(json["user"]?["name"]), $"{LastFmClient.Text(json["user"]?["playcount"])} scrobbles · {LastFmClient.Text(json["user"]?["artist_count"])} artists", MusicPresentation.ImageUrl(json["user"]?["image"]), MusicPresentation.UserUrl(user));
            foreach (var kind in new[] { "artists", "albums", "tracks" })
            {
                var chart = await client.RequestAsync(new() { ["method"] = "user.getTop" + char.ToUpperInvariant(kind[0]) + kind[1..], ["user"] = user, ["period"] = "7day", ["limit"] = "5" });
                if (version != revision || closed) return;
                AddRow("Top " + kind + " · Last 7 days", "");
                foreach (var row in LastFmClient.Rows(chart["top" + kind]?[kind[..^1]]))
                    AddRow(LastFmClient.Text(row["name"]), $"{LastFmClient.Text(row["playcount"])} plays", MusicPresentation.ImageUrl(row["image"]), MusicPresentation.ChartUrl(kind, row));
            }
        }
        if (ResultsPanel.Children.Count == 0) AddRow("Nothing here yet", "Your Last.fm activity will appear here.");
    }

    private void AddRow(string title, string detail, Uri? image = null, Uri? destination = null)
    {
        var stack = new StackPanel { Spacing = 4 };
        stack.Children.Add(new TextBlock { Text = title, FontSize = 17, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        if (detail.Length > 0) stack.Children.Add(new TextBlock { Text = detail, Opacity = .7, TextWrapping = TextWrapping.Wrap });
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        if (image != null) row.Children.Add(new Image { Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(image), Width = 56, Height = 56, Stretch = Stretch.UniformToFill });
        Grid.SetColumn(stack, 1); row.Children.Add(stack);
        FrameworkElement content = row;
        if (destination != null)
            content = new HyperlinkButton { Content = row, NavigateUri = destination, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Foreground = (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"], Padding = new Thickness(0) };
        ResultsPanel.Children.Add(new Border { Child = content, Padding = new Thickness(16), CornerRadius = new CornerRadius(8), Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"] });
    }
    private async void Refresh(object sender, RoutedEventArgs e) => await RunAsync(LoadPageAsync);
    private async void Connect(object sender, RoutedEventArgs e) => await UserActionAsync(async () => { var uri = await client.BeginAuthAsync(); if (!await Launcher.LaunchUriAsync(uri)) throw new InvalidOperationException("Could not open the browser."); });
    private async void Approve(object sender, RoutedEventArgs e) => await UserActionAsync(async () => { await client.CompleteAuthAsync(); await client.RetryAsync(); });
    private async void SignOut(object sender, RoutedEventArgs e) => await UserActionAsync(() => { client.SignOut(); TrackDetails.Text = ""; ResultsPanel.Children.Clear(); return Task.CompletedTask; });
    private async void Retry(object sender, RoutedEventArgs e) => await UserActionAsync(client.RetryAsync);
    private async void Love(object sender, RoutedEventArgs e) { if (current is { } track) await UserActionAsync(() => client.LoveAsync(track, true)); }
    private async void Unlove(object sender, RoutedEventArgs e) { if (current is { } track) await UserActionAsync(() => client.LoveAsync(track, false)); }
    private async void OpenTrack(object sender, RoutedEventArgs e) { if (current is { } track) await RunAsync(async () => { await Launcher.LaunchUriAsync(new Uri($"https://www.last.fm/music/{Uri.EscapeDataString(track.Artist)}/_/{Uri.EscapeDataString(track.Title)}")); }); }
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
