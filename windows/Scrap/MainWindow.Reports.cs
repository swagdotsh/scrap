using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using System.Globalization;

namespace Scrap;

public sealed partial class MainWindow
{
    private readonly Dictionary<ReportPeriod, ListeningReport> sessionReports = [];
    private string reportUser = "";
    private bool rebuildReport;
    private ReportKind reportKind = ReportKind.Week;
    /// A historical period the user picked; null follows the latest report.
    private ReportPeriod? reportPeriod;
    private DateTime? accountStart;

    /// last.fm launched in 2002; used until the account's sign-up date is known.
    private DateTime EarliestReportDate => accountStart ?? new DateTime(2002, 1, 1);

    private static Brush Resource(string key) => (Brush)Application.Current.Resources[key];

    private async Task LoadReportAsync(string user, Func<bool> active)
    {
        var now = DateTime.Now;
        var latest = ReportPeriod.Latest(reportKind, now);
        var period = reportPeriod is { } picked && picked.Kind == reportKind ? picked : latest;
        if (reportUser != user) { sessionReports.Clear(); reportUser = user; accountStart = null; }
        ReportControls(period, latest, now);
        if (!sessionReports.TryGetValue(period, out var report))
        {
            // Recent weeks are saved on this PC; a finished one doesn't need rebuilding.
            report = rebuildReport ? null : ReportStore.Load(period, user, now);
            if (report is not { IsFinal: true })
            {
                var loading = AddText("Building your report…", secondary: true);
                try
                {
                    accountStart ??= await AccountStartAsync(user);
                    report = await ListeningReport.BuildAsync(Request, user, period, (done, total) =>
                        DispatcherQueue.TryEnqueue(() => { if (active() && total > 1) loading.Text = $"Building your report… {done} of {total} pages"; }));
                }
                catch (Exception e)
                {
                    if (!active()) return;
                    ResultsPanel.Children.Remove(loading);
                    AddText("Couldn’t build your report. " + e.Message).Foreground = Resource("SystemFillColorCriticalBrush");
                    return;
                }
                rebuildReport = false;
                try { ReportStore.Save(report, user, now); } catch { }
                if (!active()) return;
                ResultsPanel.Children.Remove(loading);
            }
            sessionReports[period] = report;
        }
        ReportContent(report, now);
    }

    private async Task<DateTime?> AccountStartAsync(string user)
    {
        try
        {
            var info = await Request(new() { ["method"] = "user.getInfo", ["user"] = user });
            return MusicPresentation.Count(info["user"]?["registered"]?["unixtime"]) is { } seconds ? DateTimeOffset.FromUnixTimeSeconds(seconds).LocalDateTime : null;
        }
        catch { return null; }
    }

    private void ShowReportPeriod(ReportPeriod period)
    {
        reportPeriod = period == ReportPeriod.Latest(period.Kind, DateTime.Now) ? null : period;
        _ = RunAsync(LoadPageAsync);
    }

    private void ReportControls(ReportPeriod period, ReportPeriod latest, DateTime now)
    {
        var kinds = new SelectorBar();
        foreach (var kind in ReportPeriod.Kinds)
            kinds.Items.Add(new SelectorBarItem { Text = kind.ToString(), Tag = kind, IsSelected = kind == reportKind });
        kinds.SelectionChanged += (bar, args) =>
        {
            if (bar.SelectedItem?.Tag is not ReportKind kind || kind == reportKind) return;
            reportKind = kind;
            reportPeriod = null;
            try { LocalStore.Save("report-kind.json", kind); } catch (Exception e) { ShowError(e); }
            _ = RunAsync(LoadPageAsync);
        };
        ResultsPanel.Children.Add(kinds);

        var noun = period.Noun;
        var row = new Grid();
        var navigation = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        Button Arrow(string glyph, string tip, bool enabled, ReportPeriod target)
        {
            var button = new Button { Content = new FontIcon { Glyph = glyph, FontSize = 12 }, IsEnabled = enabled, Padding = new Thickness(8, 6, 8, 6) };
            ToolTipService.SetToolTip(button, tip);
            AutomationPropertiesName(button, tip);
            button.Click += (_, _) => ShowReportPeriod(target);
            return button;
        }
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        title.Children.Add(new TextBlock { Text = period.Title(now), FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        title.Children.Add(new FontIcon { Glyph = "", FontSize = 14, Foreground = Resource("TextFillColorSecondaryBrush") });
        var picker = new Button { Content = title, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(6, 2, 6, 2) };
        ToolTipService.SetToolTip(picker, $"Choose a {noun}");
        AutomationPropertiesName(picker, $"{period.Title(now)}. Choose a {noun}");
        var flyout = new Flyout { Placement = FlyoutPlacementMode.Bottom };
        flyout.Content = PeriodPicker(period, latest, now, picked => { flyout.Hide(); if (picked != period) ShowReportPeriod(picked); });
        picker.Flyout = flyout;
        navigation.Children.Add(Arrow("", $"Previous {noun}", period.Previous.End > EarliestReportDate, period.Previous));
        navigation.Children.Add(picker);
        navigation.Children.Add(Arrow("", $"Next {noun}", period != latest, period.Next));
        row.Children.Add(navigation);
        if (period != latest)
        {
            var latestButton = new Button { Content = "Latest", HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
            latestButton.Click += (_, _) => { reportPeriod = null; _ = RunAsync(LoadPageAsync); };
            row.Children.Add(latestButton);
        }
        ResultsPanel.Children.Add(row);
        if (period == latest)
        {
            var which = period.Kind switch { ReportKind.Month => "monthly ", ReportKind.Year => "yearly ", _ => "" };
            AddText($"Next {which}report {latest.Next.ReleaseDate.LocalDateTime:dddd, MMMM d}", 12, secondary: true);
        }
    }

    /// Calendar-style picker for a historical week, month or year.
    private FrameworkElement PeriodPicker(ReportPeriod selected, ReportPeriod latest, DateTime now, Action<ReportPeriod> select)
    {
        var earliest = EarliestReportDate;
        bool Available(ReportPeriod period) => period.IsReleased(now) && period.End > earliest;
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(new TextBlock { Text = $"Choose a {selected.Noun}", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        Button Cell(string text, ReportPeriod period)
        {
            var isSelected = period == selected;
            var button = new Button
            {
                Content = text, HorizontalAlignment = HorizontalAlignment.Stretch, IsEnabled = Available(period),
                FontWeight = isSelected ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal
            };
            if (isSelected) button.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
            button.Click += (_, _) => select(period);
            return button;
        }
        Grid CellGrid(int columns, double width)
        {
            var grid = new Grid { ColumnSpacing = 6, RowSpacing = 6, Width = width };
            for (var c = 0; c < columns; c++) grid.ColumnDefinitions.Add(new ColumnDefinition());
            return grid;
        }
        void Place(Grid grid, FrameworkElement cell, int index, int columns)
        {
            while (grid.RowDefinitions.Count <= index / columns) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(cell, index / columns); Grid.SetColumn(cell, index % columns);
            grid.Children.Add(cell);
        }
        var firstYear = Math.Min(earliest.Year, latest.Start.Year);
        var lastYear = latest.Start.Year;
        switch (selected.Kind)
        {
            case ReportKind.Week:
                var calendar = new CalendarView
                {
                    SelectionMode = CalendarViewSelectionMode.Single, FirstDayOfWeek = Windows.Globalization.DayOfWeek.Saturday,
                    MinDate = new DateTimeOffset(earliest < latest.LastDay ? earliest : latest.LastDay.AddDays(-1)), MaxDate = new DateTimeOffset(latest.LastDay)
                };
                calendar.SetDisplayDate(new DateTimeOffset(selected.Start));
                calendar.SelectedDates.Add(new DateTimeOffset(selected.Start));
                calendar.SelectedDatesChanged += (_, args) =>
                {
                    if (args.AddedDates.Count == 0) return;
                    var week = ReportPeriod.Containing(args.AddedDates[0].LocalDateTime, ReportKind.Week);
                    if (Available(week) && week != selected) select(week);
                };
                panel.Children.Add(calendar);
                panel.Children.Add(new TextBlock { Text = "Pick any day to see its week (Saturday to Friday).", FontSize = 12, Foreground = Resource("TextFillColorSecondaryBrush") });
                break;
            case ReportKind.Month:
                var year = selected.Start.Year;
                var months = CellGrid(3, 216);
                var header = new Grid { Width = 216 };
                var yearLabel = new TextBlock { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
                var previousYear = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 }, HorizontalAlignment = HorizontalAlignment.Left };
                var nextYear = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 }, HorizontalAlignment = HorizontalAlignment.Right };
                AutomationPropertiesName(previousYear, "Previous year"); AutomationPropertiesName(nextYear, "Next year");
                void Fill()
                {
                    yearLabel.Text = year.ToString(CultureInfo.CurrentCulture);
                    previousYear.IsEnabled = year > firstYear; nextYear.IsEnabled = year < lastYear;
                    months.Children.Clear();
                    for (var month = 1; month <= 12; month++)
                    {
                        var start = new DateTime(year, month, 1);
                        Place(months, Cell(start.ToString("MMM", CultureInfo.CurrentCulture), ReportPeriod.Containing(start, ReportKind.Month)), month - 1, 3);
                    }
                }
                previousYear.Click += (_, _) => { year--; Fill(); };
                nextYear.Click += (_, _) => { year++; Fill(); };
                header.Children.Add(previousYear); header.Children.Add(yearLabel); header.Children.Add(nextYear);
                Fill();
                panel.Children.Add(header);
                panel.Children.Add(months);
                break;
            default:
                var years = CellGrid(4, 260);
                var index = 0;
                for (var y = lastYear; y >= firstYear; y--)
                    Place(years, Cell(y.ToString(CultureInfo.CurrentCulture), ReportPeriod.Containing(new DateTime(y, 1, 1), ReportKind.Year)), index++, 4);
                panel.Children.Add(new ScrollViewer { Content = years, MaxHeight = 320, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
                break;
        }
        return panel;
    }

    private void ReportContent(ListeningReport report, DateTime now)
    {
        var noun = report.Period.Noun;
        var total = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        total.Children.Add(new TextBlock { Text = report.Scrobbles.ToString("N0"), FontSize = 36, FontWeight = Microsoft.UI.Text.FontWeights.Bold });
        total.Children.Add(new TextBlock { Text = "scrobbles", VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 8), Foreground = Resource("TextFillColorSecondaryBrush") });
        if (report.PreviousScrobbles > 0)
        {
            var change = (double)(report.Scrobbles - report.PreviousScrobbles) / report.PreviousScrobbles;
            total.Children.Add(new TextBlock
            {
                Text = (change >= 0 ? "↗ " : "↘ ") + change.ToString("P0"), FontSize = 18, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(8, 0, 0, 8),
                Foreground = Resource(change >= 0 ? "SystemFillColorSuccessBrush" : "SystemFillColorCriticalBrush")
            });
        }
        ResultsPanel.Children.Add(total);
        AddText($"Previous {noun}: {report.PreviousScrobbles:N0}", secondary: true);
        AddText($"Top of the {noun}", 17, true);
        if (report.TopArtist is { } artist) ReportRow(artist, "Top artist", true);
        if (report.TopAlbum is { } album) ReportRow(album, "Top album · " + album.Artist);
        if (report.TopTrack is { } track) ReportRow(track, "Top track · " + track.Artist);
        if (report.TopArtist == null) AddText($"No scrobbles this {noun}.", secondary: true);
        if (report.Scrobbles > 0)
        {
            if (report.Period.Kind == ReportKind.Year && report.Monthly.Length == 12)
            {
                AddText("Scrobbles by month", 17, true);
                ResultsPanel.Children.Add(BarChart(report.Monthly, i => new DateTime(2000, i + 1, 1).ToString("MMM", CultureInfo.CurrentCulture), i => true, 1, 110));
            }
            if (report.BusiestMonth is { } month)
                HighlightSection("Month you scrobbled the most", month.Start.ToString("MMMM", CultureInfo.CurrentCulture), month);
            if (report.BusiestDay is { } day)
                HighlightSection("Day you scrobbled the most", day.Start.ToString("dddd, MMMM d", CultureInfo.CurrentCulture), day);
            if (report.PeakHour is { } peak)
            {
                AddText("Listening clock", 17, true);
                AddText($"You listened the most around {HourLabel(peak)}, with {report.Hourly[peak]:N0} scrobbles in that hour.", 12, secondary: true);
                ResultsPanel.Children.Add(BarChart(report.Hourly, HourLabel, i => i % 6 == 0, 6, 70));
            }
            if (report.TopTags.Count > 0)
            {
                AddText("Top tags", 17, true);
                foreach (var tag in report.TopTags) ResultsPanel.Children.Add(TagRow(tag));
                AddText("Based on the tags of your top artists, weighted by plays.", 12, secondary: true);
            }
        }
        DiscoverySection("New artists", report.NewArtists, noun, true);
        DiscoverySection("New albums", report.NewAlbums, noun);
        DiscoverySection("New tracks", report.NewTracks, noun);
        AddText($"Checks your {ListeningReport.DiscoveryCheckLimit} most-played artists, albums and tracks of the {noun}.", 12, secondary: true);
    }

    private static string HourLabel(int hour) =>
        new DateTime(2000, 1, 1, hour, 0, 0).ToString(CultureInfo.CurrentCulture.DateTimeFormat.ShortTimePattern.Contains('t') ? "h tt" : "HH:mm", CultureInfo.CurrentCulture);

    private void HighlightSection(string heading, string title, ReportHighlight highlight)
    {
        AddText(heading, 17, true);
        var line = new Grid();
        line.Children.Add(new TextBlock { Text = title, FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        line.Children.Add(new TextBlock { Text = $"{highlight.Scrobbles:N0} scrobbles", HorizontalAlignment = HorizontalAlignment.Right, Foreground = Resource("TextFillColorSecondaryBrush") });
        ResultsPanel.Children.Add(line);
        if (highlight.TopArtist is { } artist) ReportRow(artist, "Top artist", true);
        if (highlight.TopTrack is { } track) ReportRow(track, "Top track · " + track.Artist);
        if (highlight.TopAlbum is { } album) ReportRow(album, "Top album · " + album.Artist);
    }

    /// Bars scaled to the largest value, with the largest one highlighted.
    private static FrameworkElement BarChart(int[] values, Func<int, string> label, Func<int, bool> labeled, int labelSpan, double height)
    {
        var peak = values.Max();
        var peakIndex = peak > 0 ? Array.IndexOf(values, peak) : -1;
        var grid = new Grid { ColumnSpacing = 3, RowSpacing = 4 };
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(height) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (var i = 0; i < values.Length; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var bar = new Border
            {
                VerticalAlignment = VerticalAlignment.Bottom, CornerRadius = new CornerRadius(3, 3, 0, 0),
                Height = peak > 0 ? Math.Max(values[i] > 0 ? 2 : 0, height * values[i] / peak) : 0,
                Background = Resource("AccentFillColorDefaultBrush"), Opacity = i == peakIndex ? 1 : .35
            };
            var description = $"{label(i)}: {values[i]:N0} scrobbles";
            ToolTipService.SetToolTip(bar, description);
            AutomationPropertiesName(bar, description);
            Grid.SetColumn(bar, i);
            grid.Children.Add(bar);
            if (!labeled(i)) continue;
            var text = new TextBlock { Text = label(i), FontSize = 11, Foreground = Resource("TextFillColorSecondaryBrush"), HorizontalAlignment = labelSpan > 1 ? HorizontalAlignment.Left : HorizontalAlignment.Center };
            Grid.SetRow(text, 1); Grid.SetColumn(text, i); Grid.SetColumnSpan(text, Math.Min(labelSpan, values.Length - i));
            grid.Children.Add(text);
        }
        return grid;
    }

    /// A tag with a bar sized relative to the top tag.
    private static FrameworkElement TagRow(ReportTag tag)
    {
        var row = new Grid { ColumnSpacing = 10 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(140) });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.Children.Add(new TextBlock { Text = tag.Name, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center });
        var track = new Grid { VerticalAlignment = VerticalAlignment.Center };
        track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(tag.Weight, .02), GridUnitType.Star) });
        track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1 - Math.Min(tag.Weight, .98), GridUnitType.Star) });
        track.Children.Add(new Border { Height = 8, CornerRadius = new CornerRadius(4), Background = Resource("AccentFillColorDefaultBrush"), Opacity = .6 });
        Grid.SetColumn(track, 1);
        row.Children.Add(track);
        var link = new HyperlinkButton
        {
            Content = row, NavigateUri = tag.Url, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Foreground = Resource("TextFillColorPrimaryBrush"), Padding = new Thickness(0, 4, 0, 4)
        };
        ToolTipService.SetToolTip(link, $"Open the {tag.Name} tag on last.fm");
        return link;
    }

    private void DiscoverySection(string title, IReadOnlyList<ReportItem> items, string noun, bool artists = false)
    {
        AddText(items.Count == 0 ? title : $"{title} ({items.Count})", 17, true);
        if (items.Count == 0) AddText($"Nothing new this {noun}.", secondary: true);
        foreach (var item in items) ReportRow(item, artists ? null : item.Artist, artists);
    }

    private void ReportRow(ReportItem item, string? subtitle, bool artist = false)
    {
        var plays = $"{item.Count:N0} play{(item.Count == 1 ? "" : "s")}";
        AddRow(item.Name, string.IsNullOrEmpty(subtitle) ? plays : $"{subtitle}\n{plays}", item.Images, item.Url, portrait: artist ? item.Name : null);
    }
}
