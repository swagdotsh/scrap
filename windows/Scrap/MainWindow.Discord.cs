using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Scrap;

public sealed partial class MainWindow
{
    private DiscordPresence? discord;
    private bool loadingDiscordSettings;
    private readonly DateTimeOffset discordSampleStart = DateTimeOffset.Now.AddSeconds(-72);
    private string discordPreviewSignature = "";
    private TextBlock? previewElapsed;
    private ProgressBar? previewBar;
    private DateTimeOffset? previewStart, previewEnd;

    private bool DiscordTabVisible => page == "settings" && SettingsTabs.SelectedItem is TabViewItem { Header: "Discord" };

    private void InitializeDiscord()
    {
        discord = new DiscordPresence(client, DispatcherQueue);
        discord.Changed += () => { RenderDiscordStatus(); if (DiscordTabVisible) RenderDiscordPreview(); };
        DiscordStatusChoice.ItemsSource = DiscordLabels.StatusSources.Select(DiscordLabels.Label).ToList();
        var buttonTitles = DiscordLabels.ButtonKinds.Select(DiscordLabels.MenuTitle).ToList();
        DiscordButton1Choice.ItemsSource = buttonTitles;
        DiscordButton2Choice.ItemsSource = buttonTitles;
        Presets(DiscordDetailsPresets, DiscordDetailsBox, ["{title}", "{title} by {artist}", "{title} – {artist}"]);
        Presets(DiscordStatePresets, DiscordStateBox, ["{artist}", "by {artist}", "{artist} on {service}"]);
        Presets(DiscordAlbumPresets, DiscordAlbumBox, ["{album}", "on {album}", "{album} by {artist}"]);
        LoadDiscordControls(discord.Settings);
        DiscordSwitch.Toggled += (_, _) => DiscordSettingsChanged();
        foreach (var box in new[] { DiscordDetailsBox, DiscordStateBox, DiscordAlbumBox, DiscordButton1Label, DiscordButton2Label })
            box.TextChanged += (_, _) => DiscordSettingsChanged();
        foreach (var choice in new[] { DiscordStatusChoice, DiscordCoverChoice, DiscordPausedChoice, DiscordButton1Choice, DiscordButton2Choice })
            choice.SelectionChanged += (_, _) => DiscordSettingsChanged();
        foreach (var check in new[] { DiscordCoverCheck, DiscordTimeCheck, DiscordLinksCheck, DiscordCleanupCheck })
            check.Click += (_, _) => DiscordSettingsChanged();
        RenderDiscordStatus();
    }

    private static void Presets(DropDownButton button, TextBox box, string[] presets)
    {
        var menu = new MenuFlyout();
        foreach (var preset in presets)
        {
            var item = new MenuFlyoutItem { Text = preset };
            item.Click += (_, _) => box.Text = preset;
            menu.Items.Add(item);
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        var hide = new MenuFlyoutItem { Text = "Hide this line" };
        hide.Click += (_, _) => box.Text = "";
        menu.Items.Add(hide);
        button.Flyout = menu;
        ToolTipService.SetToolTip(button, "Presets");
    }

    private void LoadDiscordControls(DiscordPresenceSettings settings)
    {
        loadingDiscordSettings = true;
        try
        {
            DiscordSwitch.IsOn = settings.Enabled;
            DiscordDetailsBox.Text = settings.DetailsFormat;
            DiscordStateBox.Text = settings.StateFormat;
            DiscordAlbumBox.Text = settings.AlbumFormat;
            DiscordStatusChoice.SelectedIndex = Array.IndexOf(DiscordLabels.StatusSources, settings.StatusSource);
            DiscordCoverCheck.IsChecked = settings.ShowCover;
            DiscordCoverChoice.SelectedIndex = (int)settings.CoverSource;
            DiscordTimeCheck.IsChecked = settings.ShowTimestamps;
            DiscordLinksCheck.IsChecked = settings.LinkNames;
            DiscordCleanupCheck.IsChecked = settings.UseScrobbleCleanup;
            DiscordPausedChoice.SelectedIndex = (int)settings.Paused;
            DiscordButton1Choice.SelectedIndex = Array.IndexOf(DiscordLabels.ButtonKinds, settings.Button1);
            DiscordButton1Label.Text = settings.Button1Label;
            DiscordButton2Choice.SelectedIndex = Array.IndexOf(DiscordLabels.ButtonKinds, settings.Button2);
            DiscordButton2Label.Text = settings.Button2Label;
            UpdateDiscordControlStates(settings);
        }
        finally { loadingDiscordSettings = false; }
    }

    private DiscordPresenceSettings DiscordSettingsFromControls() => new()
    {
        Enabled = DiscordSwitch.IsOn,
        DetailsFormat = DiscordDetailsBox.Text,
        StateFormat = DiscordStateBox.Text,
        AlbumFormat = DiscordAlbumBox.Text,
        StatusSource = DiscordLabels.StatusSources[Math.Max(0, DiscordStatusChoice.SelectedIndex)],
        ShowCover = DiscordCoverCheck.IsChecked == true,
        CoverSource = (DiscordCoverSource)Math.Max(0, DiscordCoverChoice.SelectedIndex),
        ShowTimestamps = DiscordTimeCheck.IsChecked == true,
        LinkNames = DiscordLinksCheck.IsChecked == true,
        UseScrobbleCleanup = DiscordCleanupCheck.IsChecked == true,
        Paused = (DiscordPausedBehavior)Math.Max(0, DiscordPausedChoice.SelectedIndex),
        Button1 = DiscordLabels.ButtonKinds[Math.Max(0, DiscordButton1Choice.SelectedIndex)],
        Button1Label = DiscordButton1Label.Text,
        Button2 = DiscordLabels.ButtonKinds[Math.Max(0, DiscordButton2Choice.SelectedIndex)],
        Button2Label = DiscordButton2Label.Text
    };

    private void DiscordSettingsChanged()
    {
        if (!ready || loadingDiscordSettings || discord == null) return;
        var settings = DiscordSettingsFromControls();
        UpdateDiscordControlStates(settings);
        discord.Apply(settings);
        RenderDiscordPreview();
    }

    private void UpdateDiscordControlStates(DiscordPresenceSettings settings)
    {
        DiscordCoverOptions.Visibility = settings.ShowCover ? Visibility.Visible : Visibility.Collapsed;
        DiscordCoverNote.Visibility = settings.CoverSource == DiscordCoverSource.MusicApp ? Visibility.Visible : Visibility.Collapsed;
        DiscordButton1Label.PlaceholderText = DiscordLabels.DefaultLabel(settings.Button1);
        DiscordButton1Label.IsEnabled = settings.Button1 != DiscordButtonKind.None;
        DiscordButton2Label.PlaceholderText = DiscordLabels.DefaultLabel(settings.Button2);
        DiscordButton2Label.IsEnabled = settings.Button2 != DiscordButtonKind.None;
    }

    private void ToggleDiscordFromTray()
    {
        if (discord != null) DiscordSwitch.IsOn = !discord.Settings.Enabled;
    }

    private void RenderDiscordStatus()
    {
        if (discord == null) return;
        DiscordStatusText.Text = discord.StatusDescription;
        DiscordStatusDot.Fill = Resource(discord.ActivityError != null ? "SystemFillColorCautionBrush" : discord.Status switch
        {
            DiscordPresence.State.Connected => "SystemFillColorSuccessBrush",
            DiscordPresence.State.Connecting or DiscordPresence.State.WaitingForDiscord => "SystemFillColorCautionBrush",
            DiscordPresence.State.Error or DiscordPresence.State.NotConfigured => "SystemFillColorCriticalBrush",
            _ => "TextFillColorTertiaryBrush"
        });
    }

    /// The current song, or a sample when nothing is playing, as it would look on Discord.
    private void RenderDiscordPreview()
    {
        if (discord == null) return;
        var live = discord.Info;
        var info = live ?? new DiscordTrackInfo(new PlayingTrack("Midnight Drive", "The Example Band", "Night Sessions", 222), "Apple Music",
            SongLinkUrl: new Uri("https://song.link/"), AppleMusicUrl: new Uri("https://music.apple.com/"), SpotifyUrl: new Uri("https://open.spotify.com/"));
        var activity = DiscordActivity.Build(info, discord.Settings, live == null || discord.IsPlaying, live == null ? discordSampleStart : discord.StartedAt);
        var appName = discord.AppName ?? "scrap";
        previewStart = activity?.Start;
        previewEnd = activity?.End;
        var signature = activity == null ? "hidden"
            : string.Join('\n', (activity with { Start = null, End = null }).Payload().ToJsonString(), activity.Start.HasValue, activity.End.HasValue, appName, discord.Settings.ShowCover);
        if (signature == discordPreviewSignature) { UpdateDiscordPreviewClock(); return; }
        discordPreviewSignature = signature;
        DiscordPreview.Children.Clear();
        previewElapsed = null; previewBar = null;
        var secondary = Resource("TextFillColorSecondaryBrush");
        if (activity == null)
        {
            DiscordPreview.Children.Add(new Border
            {
                MinHeight = 120, CornerRadius = new CornerRadius(10), Padding = new Thickness(16), Background = Resource("CardBackgroundFillColorDefaultBrush"),
                Child = new TextBlock { Text = "Your activity is hidden while music is paused.", FontSize = 12, Foreground = secondary, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, VerticalAlignment = VerticalAlignment.Center }
            });
            return;
        }
        var status = new TextBlock { FontSize = 12, Foreground = secondary, TextTrimming = TextTrimming.CharacterEllipsis };
        status.Inlines.Add(new Run { Text = "Listening to " });
        status.Inlines.Add(new Run { Text = activity.StatusText(appName), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        ToolTipService.SetToolTip(status, "How your status appears in member lists");
        DiscordPreview.Children.Add(status);

        var card = new StackPanel { Spacing = 10 };
        card.Children.Add(new TextBlock { Text = "Listening to " + appName, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = secondary, TextTrimming = TextTrimming.CharacterEllipsis });
        var row = new Grid { ColumnSpacing = 10 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        if (activity.CoverUrl != null || discord.Settings.ShowCover)
        {
            var cover = new Grid { Width = 64, Height = 64, CornerRadius = new CornerRadius(8), Background = Resource("ControlFillColorSecondaryBrush") };
            cover.Children.Add(new FontIcon { Glyph = "", FontSize = 20, Foreground = Resource("TextFillColorTertiaryBrush") });
            if (activity.CoverUrl != null) cover.Children.Add(new Image { Source = new BitmapImage(activity.CoverUrl), Stretch = Stretch.UniformToFill });
            row.Children.Add(cover);
        }
        var texts = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        if (activity.Details != null) texts.Children.Add(new TextBlock { Text = activity.Details, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        if (activity.State != null) texts.Children.Add(new TextBlock { Text = activity.State, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis });
        if (activity.AlbumText != null) texts.Children.Add(new TextBlock { Text = activity.AlbumText, FontSize = 12, Foreground = secondary, TextTrimming = TextTrimming.CharacterEllipsis });
        Grid.SetColumn(texts, 1);
        row.Children.Add(texts);
        card.Children.Add(row);
        if (activity.Start is { } start)
        {
            var bar = new Grid { ColumnSpacing = 6 };
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            bar.ColumnDefinitions.Add(new ColumnDefinition());
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            previewElapsed = new TextBlock { FontSize = 11, Foreground = secondary };
            bar.Children.Add(previewElapsed);
            if (activity.End is { } end)
            {
                previewBar = new ProgressBar { VerticalAlignment = VerticalAlignment.Center, Maximum = Math.Max(1, (end - start).TotalSeconds) };
                Grid.SetColumn(previewBar, 1);
                bar.Children.Add(previewBar);
                var total = new TextBlock { Text = Clock((end - start).TotalSeconds), FontSize = 11, Foreground = secondary };
                Grid.SetColumn(total, 2);
                bar.Children.Add(total);
            }
            else
            {
                var label = new TextBlock { Text = "elapsed", FontSize = 11, Foreground = secondary };
                Grid.SetColumn(label, 1);
                bar.Children.Add(label);
            }
            card.Children.Add(bar);
        }
        foreach (var button in activity.Buttons)
        {
            var face = new Border
            {
                Padding = new Thickness(6), CornerRadius = new CornerRadius(6), Background = Resource("ControlFillColorSecondaryBrush"),
                Child = new TextBlock { Text = button.Label, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Medium, HorizontalAlignment = HorizontalAlignment.Center }
            };
            ToolTipService.SetToolTip(face, button.Url.AbsoluteUri);
            card.Children.Add(face);
        }
        DiscordPreview.Children.Add(new Border
        {
            Child = card, Padding = new Thickness(12), CornerRadius = new CornerRadius(10),
            Background = Resource("CardBackgroundFillColorDefaultBrush"), BorderBrush = Resource("ControlStrokeColorDefaultBrush"), BorderThickness = new Thickness(1)
        });
        UpdateDiscordPreviewClock();
    }

    private void UpdateDiscordPreviewClock()
    {
        if (previewStart is not { } start || previewElapsed == null) return;
        var elapsed = Math.Max(0, (DateTimeOffset.Now - start).TotalSeconds);
        var shown = previewEnd is { } end ? Math.Min(elapsed, (end - start).TotalSeconds) : elapsed;
        previewElapsed.Text = Clock(shown);
        if (previewBar != null) previewBar.Value = shown;
    }

    private static string Clock(double seconds)
    {
        var value = (int)Math.Floor(seconds);
        return value >= 3600 ? $"{value / 3600}:{value / 60 % 60:00}:{value % 60:00}" : $"{value / 60}:{value % 60:00}";
    }
}
