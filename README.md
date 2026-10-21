<div align="center">
<img width="595" height="439" alt="image" src="https://github.com/user-attachments/assets/aabc56a1-eb69-4611-be68-f974a5db5960" />


# scrap for Windows (beta)

A native last.fm scrobbler for Windows, built with the Windows App SDK. Requires Windows 10 21H2 and above.

This is the `windows-app-sdk` branch. For the macOS app, see [`main`](https://github.com/swagdotsh/scrap). For iPhone, see [`ios`](https://github.com/swagdotsh/scrap/tree/ios).

[scrap website](https://scrap.swagrelated.com/)

</div>

> [!NOTE]
> Windows support is in beta and is mostly unsupported, since macOS is the main development platform.

## Features

### Scrobbling

- Scrobble songs playing in Apple Music for Windows to last.fm
- Update your last.fm now-playing status
- Love / unlove the currently playing track
- Queue unsuccessful scrobbles for retry
- Clean up scrobble metadata: remove album suffixes like " - Single", keep or drop "(Apple Music Edition)", and scrobble only the first artist (with a list of artists to keep whole, like Earth, Wind & Fire)

### Listening & discovery

- See how many times you've scrobbled an artist or track
- Artist top albums & tracks and similar artists
- Album artwork, with optional animated covers on Now Playing
- Tag the current track or artist on last.fm

### Your last.fm account

- Recent scrobbles
- Your profile with top artists, albums & tracks
- Friends' recent listening activity

### Desktop

- Lives in the notification area (system tray) when you close the window
- Open on login, with the window staying in the tray
- System, Light or Dark appearance
- In-app updates: daily checks, verified downloads and installation, plus optional automatic installation

## Requirements

- **Windows 10 21H2 or above**, 64-bit (x64)
- **Apple Music for Windows** from the Microsoft Store (works whether you're subscribed or not)
- A **last.fm account**

Spotify support is coming soon.

## Installing

1. Download the latest `Scrap-Windows-…-x64.zip` from [Releases](https://github.com/swagdotsh/scrap/releases) (Windows releases are marked "(Windows)")
2. Right-click the ZIP and choose **Extract All…**. Put the folder somewhere permanent, like `C:\Users\you\Apps\Scrap`
3. Open the folder and run `Scrap.exe`
4. If Windows SmartScreen says it protected your PC, click **More info → Run anyway**. scrap isn't code-signed yet.
5. Open Apple Music and play something
6. In scrap, choose **Connect Last.fm**, approve access in your browser, then return to scrap and choose **I've approved it**

That's it. Keep scrap running while you listen. Closing the window leaves it running in the notification area.

> [!IMPORTANT]
> Keep the whole extracted folder together. scrap is an unpackaged app with no installer, and `Scrap.exe` needs the files next to it.

### Open on login

Turn on **Settings → General → Open Scrap on login**. scrap starts in the notification area without opening its window.

### Updates

**Settings → Updates** checks for new Windows releases daily. Turn on **Automatically install verified updates** to have scrap download, verify and install them for you. Updates replace the app folder and keep your settings.

---

## Building from Source

You'll need a 64-bit Windows PC, the [.NET 10 SDK](https://learn.microsoft.com/en-us/dotnet/core/install/windows), Apple Music for Windows, and your own [last.fm API credentials](https://www.last.fm/api/account/create).

In PowerShell, clone the repository and switch branches:

```powershell
git clone https://github.com/swagdotsh/scrap.git
cd scrap
git switch windows-app-sdk
```

If `dotnet --version` does not show version 10, install the SDK with `winget install Microsoft.DotNet.SDK.10`, then open a new PowerShell window in the `scrap` folder. Create a `.env` file in that folder with:

```env
LASTFM_API_KEY=your_api_key
LASTFM_SHARED_SECRET=your_shared_secret
```

Build, test, and publish the app:

```powershell
dotnet build windows/Scrap/Scrap.csproj -p:Platform=x64
dotnet run --project windows/Scrap.Tests/Scrap.Tests.csproj
dotnet publish windows/Scrap/Scrap.csproj -c Release -p:Platform=x64 -o windows/publish
.\windows\publish\Scrap.exe
```

Keep the entire `windows/publish` folder together if you move the app.

> [!CAUTION]
> Keep `.env` gitignored. The Windows build copies it beside the executable, so don't put personal account credentials in it.

---

## Common Issues

### Nothing playing

- Make sure you're playing something in **Apple Music for Windows** (not the browser or iTunes)
- Pause and play again so Windows reports the track to scrap

### Connected, but songs aren't scrobbling

- Make sure the **Scrobbling** switch in settings is on
- Keep scrap running while you listen (check the notification area)
- Check your internet connection
- Use **Retry pending scrobbles** if there are queued scrobbles

### Closed the window, but scrap is still running

That's normal. Click the scrap icon in the notification area, on the right of the taskbar (you may need to click **^** to see it). To fully close it, right-click the icon and choose **Quit Scrap**.

### Windows protected your PC

Click **More info → Run anyway**. This appears because scrap isn't code-signed.

### Scrap.exe won't open after moving it

Move the whole folder, not just `Scrap.exe`.

### last.fm app credentials are missing

If you're building from source, check that `.env` contains both required values, then publish again.

## Support

If you're having issues, open an [issue](https://github.com/swagdotsh/scrap/issues). Include your Windows version, scrap version, and what happened, and mention that you're using the Windows beta.

## Contributing

Contributions are welcome: bug fixes, Windows improvements, docs, etc.

1. Fork the repo
2. Create a feature branch from `windows-app-sdk`
3. Make changes
4. Open a PR into `windows-app-sdk` with a clear description and testing notes. Don't target `main`; the Windows branch stays separate.
