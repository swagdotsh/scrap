using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;

namespace Scrap;

internal static class ArtworkLoader
{
    public static async Task<BitmapImage?> LoadAsync(IEnumerable<Uri> candidates, bool animate,
        bool preferAnimated, Func<Uri, Task<byte[]>> fetch, Func<bool> active)
    {
        BitmapImage? fallback = null;
        foreach (var uri in candidates.Distinct())
        {
            if (!active()) return null;
            try
            {
                var bytes = await fetch(uri);
                if (!active()) return null;
                using var stream = new InMemoryRandomAccessStream();
                using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
                {
                    writer.WriteBytes(bytes);
                    await writer.StoreAsync();
                }
                stream.Seek(0);
                var bitmap = new BitmapImage { AutoPlay = animate };
                await bitmap.SetSourceAsync(stream);
                if (!active()) return null;
                if (animate ? !preferAnimated || bitmap.IsAnimatedBitmap : !bitmap.IsAnimatedBitmap)
                    return bitmap;
                fallback ??= bitmap;
            }
            catch (Exception) { if (!active()) return null; }
        }
        return active() ? fallback : null;
    }
}
