using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Text.Json.Nodes;

namespace Scrap;

public sealed partial class MainWindow
{
    private readonly HttpClient artworkHttp = new() { Timeout = TimeSpan.FromSeconds(12) };
    private readonly Dictionary<string, (Uri? Url, DateTimeOffset Expires)> portraits = new(StringComparer.OrdinalIgnoreCase);
    private readonly SemaphoreSlim portraitLock = new(1, 1);
    private DateTimeOffset nextPortraitRequest;

    private void ClearDetails()
    {
        AlbumArtwork.Source = null;
        ArtistPortrait.Source = null;
        ArtistPortrait.Visibility = Visibility.Collapsed;
        ArtistSection.Visibility = Visibility.Collapsed;
        TrackDetails.Text = ""; ArtistHeading.Text = ""; ArtistBiography.Text = "";
        ArtistLinks.Children.Clear(); DetailsStatus.Text = "";
        TrackTags.Children.Clear(); ArtistTags.Children.Clear();
        ArtistTopTracks.Children.Clear(); ArtistTopAlbums.Children.Clear(); SimilarArtists.Children.Clear();
        SimilarScroll.ChangeView(0, null, null, true);
    }

    private async Task LoadDetailsAsync(int version)
    {
        var track = current;
        if (track == null) { ClearDetails(); return; }
        var thumbnail = listener.Thumbnail;
        ArtistSection.Visibility = Visibility.Visible;
        bool Active() => !closed && revision == version && current?.Title == track.Title && current?.Artist == track.Artist && current?.Album == track.Album;
        ArtistHeading.Text = "About " + track.Artist;
        ArtistBiography.Text = "Loading artist biography…";
        TrackDetails.Text = " - Loading your listening history…";
        TrackTags.Children.Clear(); ArtistTags.Children.Clear();
        ArtistTopTracks.Children.Clear(); ArtistTopAlbums.Children.Clear(); SimilarArtists.Children.Clear();
        long? artistCount = null, trackCount = null;
        var artistFinished = false; var trackFinished = false;
        void UpdateSummary()
        {
            if (Active() && artistFinished && trackFinished)
                TrackDetails.Text = " - " + MusicPresentation.ListeningSummary(track, artistCount, trackCount);
        }
        DetailsStatus.Text = "";
        ArtistLinks.Children.Clear();
        ArtistLinks.Children.Add(new HyperlinkButton { Content = "Artist on Last.fm", NavigateUri = new Uri("https://www.last.fm/music/" + Uri.EscapeDataString(track.Artist)) });
        ArtistLinks.Children.Add(new HyperlinkButton { Content = "Artwork: TheAudioDB", NavigateUri = new Uri("https://www.theaudiodb.com/") });

        async Task Part(string name, Func<Task> load)
        {
            try { await load(); }
            catch (Exception)
            {
                if (!Active()) return;
                DetailsStatus.Text += (DetailsStatus.Text.Length == 0 ? "" : "\n") + name + " unavailable. Use Refresh to retry.";
                if (name == "Artist biography") { ArtistBiography.Text = "Biography unavailable."; artistFinished = true; UpdateSummary(); }
                if (name == "Listening history") { trackFinished = true; UpdateSummary(); }
            }
        }

        var coverTask = Part("Album artwork", async () =>
        {
            if (thumbnail != null)
            {
                try
                {
                    using var stream = await thumbnail.OpenReadAsync();
                    if (stream.Size > 0)
                    {
                        var bitmap = new BitmapImage();
                        await bitmap.SetSourceAsync(stream);
                        if (Active()) AlbumArtwork.Source = bitmap;
                        return;
                    }
                }
                catch { /* Try the album catalogue if the player thumbnail failed. */ }
            }
            if (!client.Configured || string.IsNullOrWhiteSpace(track.Album)) return;
            var album = await client.RequestAsync(new() { ["method"] = "album.getInfo", ["artist"] = track.Artist, ["album"] = track.Album });
            var url = MusicPresentation.ImageUrl(album["album"]?["image"]);
            if (Active() && url != null) AlbumArtwork.Source = new BitmapImage(url);
        });
        var portraitTask = Part("Artist portrait", async () =>
        {
            var uri = await PortraitAsync(track.Artist);
            if (!Active() || uri == null) return;
            ArtistPortrait.Source = new BitmapImage(uri);
            ArtistPortrait.Visibility = Visibility.Visible;
        });
        if (!client.Configured)
        {
            ArtistBiography.Text = "Add Last.fm app credentials to load the biography.";
            TrackDetails.Text = " - Listening history unavailable.";
            await Task.WhenAll(coverTask, portraitTask);
            return;
        }
        var user = client.Username;
        Dictionary<string, string> Query(string method)
        {
            var args = new Dictionary<string, string> { ["method"] = method, ["artist"] = track.Artist, ["autocorrect"] = "1" };
            if (user != null) args["username"] = user;
            return args;
        }
        var historyTask = Part("Listening history", async () =>
        {
            var args = Query("track.getInfo"); args["track"] = track.Title;
            var result = await client.RequestAsync(args);
            if (!Active()) return;
            trackCount = MusicPresentation.Count(result["track"]?["userplaycount"]);
            trackFinished = true; UpdateSummary();
        });
        var biographyTask = Part("Artist biography", async () =>
        {
            var result = await client.RequestAsync(Query("artist.getInfo"));
            if (!Active()) return;
            var bio = MusicPresentation.Biography(LastFmClient.Text(result["artist"]?["bio"]?["summary"]));
            artistCount = MusicPresentation.Count(result["artist"]?["stats"]?["userplaycount"]);
            artistFinished = true; UpdateSummary();
            ArtistBiography.Text = bio.Length > 0 ? bio : "No biography available for this artist.";
            FillTags(ArtistTags, result["artist"]?["tags"]?["tag"]);
        });
        var tagsTask = Part("Song tags", async () =>
        {
            var args = Query("track.getTopTags"); args["track"] = track.Title;
            var result = await client.RequestAsync(args);
            if (Active()) FillTags(TrackTags, result["toptags"]?["tag"]);
        });
        async Task TopMusic(string kind, StackPanel panel)
        {
            var args = Query("artist.getTop" + kind); args["limit"] = "5";
            var result = await client.RequestAsync(args);
            if (!Active()) return;
            var key = kind.ToLowerInvariant();
            foreach (var item in LastFmClient.Rows(result["top" + key]?[key[..^1]]))
            {
                var name = LastFmClient.Text(item["name"]);
                if (name.Length == 0) continue;
                var target = kind == "Tracks" ? MusicPresentation.TrackUrl(track.Artist, name) : MusicPresentation.AlbumUrl(track.Artist, name);
                var link = MusicLink(name, target);
                var image = MusicPresentation.ImageUrl(item["image"]);
                if (image != null)
                {
                    var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
                    row.Children.Add(new Image { Source = new BitmapImage(image), Width = 44, Height = 44, Stretch = Microsoft.UI.Xaml.Media.Stretch.UniformToFill });
                    row.Children.Add(new TextBlock { Text = name, VerticalAlignment = VerticalAlignment.Center });
                    link.Content = row;
                }
                panel.Children.Add(link);
            }
            if (panel.Children.Count == 0) panel.Children.Add(new TextBlock { Text = "No top " + key + " available.", Opacity = .65 });
        }
        var topTracksTask = Part("Top tracks", () => TopMusic("Tracks", ArtistTopTracks));
        var topAlbumsTask = Part("Top albums", () => TopMusic("Albums", ArtistTopAlbums));
        var similarTask = Part("Similar artists", async () =>
        {
            var args = Query("artist.getSimilar"); args["limit"] = "10";
            var result = await client.RequestAsync(args);
            if (!Active()) return;
            var cards = new List<(string Name, Image Image)>();
            foreach (var item in LastFmClient.Rows(result["similarartists"]?["artist"]))
            {
                var name = LastFmClient.Text(item["name"]);
                if (name.Length == 0) continue;
                var image = new Image { Width = 112, Height = 112, Stretch = Microsoft.UI.Xaml.Media.Stretch.UniformToFill };
                var placeholder = new Grid { Width = 112, Height = 112, Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"] };
                placeholder.Children.Add(new FontIcon { Glyph = "\uE77B", FontSize = 36 }); placeholder.Children.Add(image);
                var card = new StackPanel { Width = 112, Spacing = 8 };
                card.Children.Add(placeholder);
                card.Children.Add(new TextBlock { Text = name, TextWrapping = TextWrapping.Wrap });
                var link = MusicLink(name, MusicPresentation.ArtistUrl(name)); link.Content = card;
                SimilarArtists.Children.Add(link); cards.Add((name, image));
            }
            if (cards.Count == 0) SimilarArtists.Children.Add(new TextBlock { Text = "No similar artists available.", Opacity = .65 });
            // Paint all cards first; hydrate portraits without blocking the other sections.
            foreach (var card in cards)
            {
                if (!Active()) return;
                try { var uri = await PortraitAsync(card.Name); if (Active() && uri != null) card.Image.Source = new BitmapImage(uri); }
                catch { /* Keep the named, clickable placeholder when no portrait is available. */ }
            }
        });
        await Task.WhenAll(coverTask, portraitTask, historyTask, biographyTask, tagsTask, topTracksTask, topAlbumsTask, similarTask);
    }

    private static HyperlinkButton MusicLink(string label, Uri destination) => new()
    {
        Content = label, NavigateUri = destination, HorizontalAlignment = HorizontalAlignment.Left,
        Padding = new Thickness(6), Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorPrimaryBrush"]
    };

    private static void FillTags(StackPanel panel, JsonNode? tags)
    {
        panel.Children.Clear();
        foreach (var item in LastFmClient.Rows(tags).Take(7))
        {
            var name = LastFmClient.Text(item["name"]);
            if (name.Length > 0) panel.Children.Add(MusicLink(name, MusicPresentation.TagUrl(name)));
        }
        if (panel.Children.Count == 0) panel.Children.Add(new TextBlock { Text = "No tags available.", Opacity = .65 });
    }
    private void PreviousSimilar(object sender, RoutedEventArgs e) => SimilarScroll.ChangeView(Math.Max(0, SimilarScroll.HorizontalOffset - 372), null, null);
    private void NextSimilar(object sender, RoutedEventArgs e) => SimilarScroll.ChangeView(Math.Min(SimilarScroll.ScrollableWidth, SimilarScroll.HorizontalOffset + 372), null, null);

    private async Task<Uri?> PortraitAsync(string artist)
    {
        await portraitLock.WaitAsync();
        try
        {
            if (portraits.TryGetValue(artist, out var cached) && cached.Expires > DateTimeOffset.UtcNow) return cached.Url;
            var delay = nextPortraitRequest - DateTimeOffset.UtcNow;
            if (delay > TimeSpan.Zero) await Task.Delay(delay);
            nextPortraitRequest = DateTimeOffset.UtcNow.AddSeconds(2.1);
            var json = JsonNode.Parse(await artworkHttp.GetStringAsync("https://www.theaudiodb.com/api/v1/json/123/search.php?s=" + Uri.EscapeDataString(artist)));
            var match = LastFmClient.Rows(json?["artists"]).FirstOrDefault(a => string.Equals(LastFmClient.Text(a["strArtist"]), artist, StringComparison.OrdinalIgnoreCase));
            var valid = Uri.TryCreate(LastFmClient.Text(match?["strArtistThumb"]), UriKind.Absolute, out var uri) && uri.Scheme == "https";
            portraits[artist] = (valid ? uri : null, DateTimeOffset.UtcNow.AddMinutes(valid ? 1440 : 5));
            return valid ? uri : null;
        }
        finally { portraitLock.Release(); }
    }
}
