<div align="center">
  
<img width="792" height="494" alt="image" src="https://github.com/user-attachments/assets/61e49c66-18c5-4641-8fab-6dc3fa0f0e32" />



# scrap

An open-source native scrobbler for macOS. Requires macOS 14.6 (Sonoma) and above.

<br />

<img alt="GitHub Issues" src="https://img.shields.io/github/issues/swagdotsh/scrap?style=for-the-badge" />
<img alt="GitHub Repo stars" src="https://img.shields.io/github/stars/swagdotsh/scrap?style=for-the-badge" />
<img alt="GitHub repo size" src="https://img.shields.io/github/repo-size/swagdotsh/scrap?style=for-the-badge" />
<img alt="GitHub top language" src="https://img.shields.io/github/languages/top/swagdotsh/scrap?style=for-the-badge" />

<br />

[scrap website](https://scrap.swagrelated.com/)

</div>

> [!TIP]
> This branch covers the macOS app. Looking for another device? Each has its own branch with setup instructions:
>
> - **iPhone**: [`ios`](https://github.com/swagdotsh/scrap/tree/ios)
> - **Windows (beta)**: [`windows-app-sdk`](https://github.com/swagdotsh/scrap/tree/windows-app-sdk)

## Features

### Scrobbling

- Scrobble songs playing in Apple Music or Spotify to last.fm
- Update your last.fm now-playing status
- Queue unsuccessful scrobbles for retry

### Listening & discovery

- See how many times you've scrobbled an artist or track
- Artist biographies, tags & similar artists
- Artist top albums & tracks
- Album artwork and links to last.fm
- Weekly reports (Saturday to Friday): scrobbles vs last week, top artist, album and track, and new artists, albums and tracks you discovered
- Notifications every 5,000 scrobbles, when you discover a new artist, and when your weekly report is ready (Fridays at 16:00 Central European Time)

### Your last.fm account

- Recent scrobbles
- All-time top artists, albums & tracks
- Friends' recent listening activity
- Love / unlove the currently playing track
- Tag the current song or artist on Last.fm from the macOS menu bar’s right-click menu; view your tags and community tags before applying up to 10 new tags

### Desktop controls

- Menu bar access
- Optional Dock icon
- Open on logon, with scrobbling initialized even when no window opens
- System, Light, or Dark appearance and adjustable menu bar background opacity in Settings → General
- In-app macOS updates with Sparkle: daily checks, verified downloads, installation and relaunch, plus optional automatic installation

## Requirements

- **macOS 14.6 (Sonoma) or above**
- **Apple silicon or Intel Mac** (universal build means works for both, but mayyy not be supported forever!)
- **Apple Music or Spotify** for playback
- A **last.fm account**

## Setting Up

1. Download `scrap-v1.6-universal.zip` from [Releases](https://github.com/swagdotsh/scrap/releases) (or get it from the [website](https://scrap.swagrelated.com/) that works too)
2. Extract the ZIP and drag `Scrap.app` into your Applications folder
3. Open scrap
4. Open Apple Music and play something
5. Allow scrap to access Music when macOS asks
6. Click **Connect last.fm**, approve access in your browser, then return to scrap and click **I've approved it**

That's it. Keep scrap running while you listen.

To scrobble Spotify, enable it in **Preferences → Services**. Spotify is off by default so it does not duplicate an existing Spotify–Last.fm connection.

To scrobble [untitled], enable it in **Preferences → Services** and allow scrap in **System Settings → Privacy & Security → Accessibility** when prompted. Scrap uses the [untitled] project name as the Last.fm album name. [untitled] is off by default.

> [!IMPORTANT]
> The current macOS build isn't signed (because it's kinda 200$ a year). If macOS blocks it, go to **System Settings -> Privacy & Security -> Open Anyway** after trying to open it.
>
> Visit [Apple Support](https://support.apple.com/en-gb/102445) for more info.

---

## Updates

Starting with 1.4, **Settings → Updates** can download and install updates inside Scrap. Daily checks are enabled by default; automatic download and installation can be enabled there too. Earlier versions need one final manual update to get this feature.

Maintainers: see [Preparing and publishing updates](docs/updates.md) for the signed release and feed workflow.

## Building from Source

You'll need **Xcode 27** and your own [last.fm API credentials](https://www.last.fm/api/account/create).

1. Clone the repo
2. Create a `.env` file in the project root:

```env
LASTFM_API_KEY=your_api_key
LASTFM_SHARED_SECRET=your_shared_secret
```

3. Open `scrap.xcodeproj` in Xcode
4. Select the `scrap` scheme and your Mac as the destination
5. Build and run

The build copies the last.fm app configuration into the app bundle. People using your build connect their own last.fm accounts.

> [!CAUTION]
> Keep `.env` gitignored. The build includes its contents in the app bundle, so don't put personal account credentials in it.

---

## Common Issues

### Nothing playing

- Make sure you're playing something in an enabled app (Apple Music or Spotify)
- Check **System Settings -> Privacy & Security -> Automation**
- Allow scrap to access Music

### Connected, but songs aren't scrobbling

- Make sure scrobbling isn't paused
- Keep scrap running while you listen
- Check your internet connection
- Use **Retry pending** if there are queued scrobbles

### Closed the window, but scrap is still running

That's normal. You can access it from the music-note icon in the menu bar.

To fully close it, choose **Quit scrap** from the menu.

### last.fm app credentials are missing

If you're building from source, check that `.env` contains both required values, then rebuild the app.

## Support

If you're having issues, open an [issue](https://github.com/swagdotsh/scrap/issues). Include your macOS version, scrap version, and what happened. For the iPhone or Windows versions, see the support section on their branch.

## Contributing

Contributions are welcome: bug fixes, platform improvements, docs, etc.

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, platform branches, testing, and pull request guidance.

Suggested workflow:

1. Fork the repo
2. Create a feature branch
3. Make changes
4. Open a PR with a clear description and testing notes
