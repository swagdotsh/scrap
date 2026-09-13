# Scrap for Windows

Native C# / WinUI 3 port of Scrap, using the Windows App SDK. The original macOS sources remain at the repository root. Windows development lives on `windows-app-sdk`.

## Build and run

Requires Windows 10 2004 (19041) or newer, x64, and the .NET 10 SDK. Visual Studio with WinUI development tools is optional when building from the command line.

```powershell
dotnet build windows/Scrap/Scrap.csproj -p:Platform=x64
dotnet run --project windows/Scrap.Tests/Scrap.Tests.csproj
dotnet publish windows/Scrap/Scrap.csproj -c Release -p:Platform=x64 -o windows/publish
```

Run `windows/publish/Scrap.exe`. Distribute the entire publish folder, not just the executable. This is an unpackaged, self-contained x64 app. An installer and Store/MSIX packaging are not included.

If using the SDK installed locally during development, replace `dotnet` with `.\.dotnet\dotnet.exe`.

## Connect Last.fm

The Windows executable, title bar/taskbar, and tray use `Scrap/Assets/Scrap.ico`, derived from `scrap/Scrap.icon` in the macOS project. To regenerate it after changing those source assets, run `./windows/Build-Icon.ps1` in PowerShell 7, then rebuild. The ICO contains 16–256 pixel sizes; the conversion preserves the note and gradient with a flat rendering of the macOS glass effect.

1. Fill in `LASTFM_API_KEY` and `LASTFM_SHARED_SECRET` in the repository root `.env`, then build/publish. The file is ignored by Git and copied beside the executable. For a fresh checkout, create `.env` with these two variable names.
2. Choose **Connect Last.fm** below Now Playing.
3. Approve Scrap in the browser, return to the app, and choose **I've approved it**.
4. Play a track in Apple Music. Closing Scrap hides it in the notification area and keeps scrobbling.

App credentials are read from `.env` beside the executable on startup; account sessions are stored in Windows Credential Manager. Rebuild after editing the root `.env`, or edit the copy beside the executable and restart. Pending submissions are atomically saved to `%LOCALAPPDATA%\Scrap\pending.json` and belong to the account that recorded them. Signing out preserves pending submissions for that account.

Settings contains **Open Scrap on startup**, the persistent scrobbling on/off switch, and **Retry pending scrobbles**. Startup is opt-in and registers the current executable under the current user's Windows Run key. Keep the publish folder in its intended location before enabling it; if you move Scrap, enable the option from the new location. Windows can delay startup or disable it through its Startup apps settings. Account controls are below the main pages. Click the tray icon to reopen Scrap, or right-click it for **Open Scrap** and **Quit Scrap**. If Windows cannot create the tray icon, closing exits normally so the app cannot become inaccessible.

The tray menu also offers **Settings** and **Love track / Unlove track**. Opening the menu checks the current track's Last.fm loved status (up to five seconds). Selecting the action checks again before updating it. Missing playback, a disconnected account, failed lookups, and track/account changes disable or cancel the action rather than guessing its state.

## Implemented

- Apple Music media-session detection.
- Close to tray, restore from tray, and explicit quit; playback tracking continues while hidden.
- Last.fm browser authorization, now-playing updates, love/unlove, and scrobbling.
- Original timing rules: tracks longer than 30 seconds, half their length or four minutes, whichever comes first. Pauses and sleep gaps do not count; repeat detection starts a new submission.
- Persistent submission queue with retry every minute or manually.
- Recent scrobbles, profile with weekly top artists/albums/tracks, friends' recent activity, track play count, and artist biography.
- Apple Music artist/album normalization, player album artwork with Last.fm fallback, and cached TheAudioDB artist portraits. Artwork, biography, and listening history load independently. Recent tracks, profiles, friends, and charts display images supplied by Last.fm.
- Native navigation, Mica backdrop, system light/dark theme, and accessible controls.
- Neutral-colored Last.fm links beside the cover and an italic artist/album/listening-summary line. Recent scrobbles, profile charts, and friends link to their Last.fm destinations.
- Song and artist tags, artist top tracks/albums, and a horizontal similar-artists carousel with portraits and scroll arrows.
- Closing to the tray sends a native notification; clicking the notification reopens Scrap. Windows notification preferences may suppress its display.

## Compatibility and remaining parity

Windows playback detection uses `GlobalSystemMediaTransportControlsSessionManager`, replacing macOS AppleScript. The player must expose title, artist, playback state, and duration. Apple Music detection matches `AppleMusic` in its media-session app ID. Missing duration prevents scrobbling rather than inventing a duration. Repeat detection is best effort when the player reports timeline positions; a seek from the final three seconds to the start can look like a repeat.

This initial port has no detailed artist drill-down, desktop media controls, or installer. Live playback and Last.fm end-to-end authorization must be checked with a real player and account. Network failures retain queued scrobbles; a response lost after server acceptance can result in a retry, so exactly-once delivery cannot be guaranteed. The metadata fix applies to newly detected playback; it does not edit previously submitted Last.fm history.

Reference: [Windows App SDK downloads](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/downloads), [Windows media session API](https://learn.microsoft.com/en-us/uwp/api/windows.media.control.globalsystemmediatransportcontrolssessionmanager).
