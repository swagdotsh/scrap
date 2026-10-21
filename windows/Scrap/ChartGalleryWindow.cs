using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace Scrap;

public sealed class ChartGalleryWindow : Window
{
    private readonly string kind;
    private readonly Func<ChartPeriod, Task<List<ChartEntry>>> load;
    private readonly Func<Image, ChartEntry, Func<bool>, Task> artwork;
    private readonly Grid root = new();
    private readonly GridView grid = new() { SelectionMode = ListViewSelectionMode.None, IsItemClickEnabled = true, Padding = new Thickness(20) };
    private readonly ProgressRing progress = new() { IsActive = true, Width = 40, Height = 40 };
    private readonly TextBlock message = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(20) };
    private int version;
    public bool IsClosed { get; private set; }

    public ChartGalleryWindow(string kind, Func<ChartPeriod, Task<List<ChartEntry>>> load, Func<Image, ChartEntry, Func<bool>, Task> artwork)
    {
        this.kind = kind; this.load = load; this.artwork = artwork;
        SystemBackdrop = new MicaBackdrop();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Scrap.ico"));
        AppWindow.Resize(new Windows.Graphics.SizeInt32(720, 560));
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = 420;
            presenter.PreferredMinimumHeight = 320;
        }
        root.Background = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
        grid.ItemClick += async (_, e) => { if (e.ClickedItem is FrameworkElement { Tag: Uri url }) await Launcher.LaunchUriAsync(url); };
        root.Children.Add(grid); root.Children.Add(progress); root.Children.Add(message);
        Content = root;
        Closed += (_, _) => { IsClosed = true; version++; };
    }

    public async Task ShowAsync(ChartPeriod period, ElementTheme theme)
    {
        var current = ++version;
        root.RequestedTheme = theme;
        Title = $"{ProfileCharts.Title(kind)} · {period.Title}";
        grid.Items.Clear();
        message.Text = "";
        progress.IsActive = true; progress.Visibility = Visibility.Visible;
        Activate();
        bool Active() => !IsClosed && version == current;
        try
        {
            var entries = await load(period);
            if (!Active()) return;
            if (entries.Count == 0) message.Text = "Nothing scrobbled in this period.";
            for (var i = 0; i < entries.Count; i++) grid.Items.Add(Cell(entries[i], i + 1, Active));
        }
        catch (Exception e) { if (Active()) message.Text = $"Couldn’t load {ProfileCharts.Title(kind).ToLowerInvariant()}. {e.Message}"; }
        finally { if (Active()) { progress.IsActive = false; progress.Visibility = Visibility.Collapsed; } }
    }

    private FrameworkElement Cell(ChartEntry entry, int rank, Func<bool> active)
    {
        var image = new Image { Width = 150, Height = 150, Stretch = Stretch.UniformToFill };
        var cover = new Grid { Width = 150, Height = 150, CornerRadius = new CornerRadius(10), Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"] };
        cover.Children.Add(new FontIcon { Glyph = kind == "artists" ? "" : kind == "albums" ? "" : "", FontSize = 36, Opacity = .6 });
        cover.Children.Add(image);
        cover.Children.Add(new Border
        {
            Child = new TextBlock { Text = rank.ToString(), FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Bold },
            Padding = new Thickness(7, 3, 7, 3), Margin = new Thickness(7), CornerRadius = new CornerRadius(10),
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
            Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"]
        });
        var stack = new StackPanel { Width = 150, Spacing = 3, Tag = entry.Url, Margin = new Thickness(0, 0, 0, 10) };
        ToolTipService.SetToolTip(stack, $"Open {entry.Name} on last.fm");
        stack.Children.Add(cover);
        stack.Children.Add(new TextBlock { Text = entry.Name, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 4, 0, 0) });
        var secondary = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        if (kind != "artists") stack.Children.Add(new TextBlock { Text = entry.Artist, FontSize = 12, Foreground = secondary, TextTrimming = TextTrimming.CharacterEllipsis });
        stack.Children.Add(new TextBlock { Text = $"{entry.Count:N0} scrobbles", FontSize = 12, Foreground = secondary });
        _ = artwork(image, entry, active);
        return stack;
    }
}
