namespace Scrap;

public sealed partial class MainWindow
{
    private bool preparingTrayMenu;

    private async Task ShowTrayMenuAsync()
    {
        if (preparingTrayMenu || closed) return;
        preparingTrayMenu = true;
        try
        {
            var track = current;
            var user = client.Username;
            bool StillCurrent() => !closed && client.Connected && client.Username == user &&
                current?.Title == track?.Title && current?.Artist == track?.Artist;
            if (track == null || !client.Connected)
            {
                tray?.ShowMenu(track == null ? "Love track (nothing playing)" : "Love track (connect Last.fm)", null);
                return;
            }
            bool loved;
            try { loved = await client.IsLovedAsync(track).WaitAsync(TimeSpan.FromSeconds(5)); }
            catch (Exception)
            {
                if (!closed) tray?.ShowMenu("Love status unavailable (retry)", null);
                return;
            }
            if (!StillCurrent()) { if (!closed) tray?.ShowMenu("Track changed (reopen menu)", null); return; }
            tray?.ShowMenu(loved ? "Unlove track" : "Love track", () =>
            {
                if (!StillCurrent()) return;
                _ = UserActionAsync(async () =>
                {
                    await TrackLove.ToggleAsync(() => client.IsLovedAsync(track), async desired =>
                    {
                        if (!StillCurrent()) throw new InvalidOperationException("The track or account changed. Open the tray menu again.");
                        await client.LoveAsync(track, desired);
                    });
                });
            });
        }
        finally { preparingTrayMenu = false; }
    }
}
