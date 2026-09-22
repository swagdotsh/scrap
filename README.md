<div align="center">

<img width="792" height="494" alt="scrap" src="https://github.com/user-attachments/assets/94ef2a40-125a-46e5-8ef3-999f210a9f50" />

# scrap

An open-source native scrobbler for macOS and Windows (beta). Requires macOS 14.6 (Sonoma) and above or Windows 10 21H2 and above.

<br />

<img alt="GitHub Issues" src="https://img.shields.io/github/issues/swagdotsh/scrap?style=for-the-badge" />
<img alt="GitHub Repo stars" src="https://img.shields.io/github/stars/swagdotsh/scrap?style=for-the-badge" />
<img alt="GitHub repo size" src="https://img.shields.io/github/repo-size/swagdotsh/scrap?style=for-the-badge" />
<img alt="GitHub top language" src="https://img.shields.io/github/languages/top/swagdotsh/scrap?style=for-the-badge" />

<br />

[scrap website](https://scrap.swagrelated.com/)

</div>

## Features

### Scrobbling

- Scrobble songs playing in Apple Music & iTunes (Windows) to last.fm
- Update your last.fm now-playing status
- Queue unsuccessful scrobbles for retry

### Listening & discovery

- See how many times you've scrobbled an artist or track
- Artist biographies, tags & similar artists
- Artist top albums & tracks
- Album artwork and links to last.fm

### Your last.fm account

- Recent scrobbles
- All-time top artists, albums & tracks
- Friends' recent listening activity
- Love / unlove the currently playing track

### Desktop controls

- Menu bar / taskbar access
- Optional Dock icon (macOS)
- Automatic checks for new stable macOS releases, with a manual check in Preferences

> [!NOTE]
> Windows support is in beta and is mostly unsupported due to macOS being the main development platform. 

## Requirements

### macOS

- **macOS 14.6 (Sonoma) or above**
- **Apple silicon or Intel Mac** (universal build means works for both, but mayyy not be supported forever!)
- **Apple Music** for playback (works whether you're subscribed or not)
- A **last.fm account**

### Windows (beta)

- **Windows 10 21H2 or above**
- **Apple Music** for playback (works whether you're subscribed or not)
- A **last.fm account**

## Setting Up

### macOS

1. Download `scrap-v1.2-universal.zip` from [Releases](https://github.com/swagdotsh/scrap/releases) (or get it from the [website](https://scrap.swagrelated.com/downloads) that works too)
2. Extract the ZIP and drag `Scrap.app` into your Applications folder
3. Open scrap
4. Open Apple Music and play something
5. Allow scrap to access Music when macOS asks
6. Click **Connect last.fm**, approve access in your browser, then return to scrap and click **I've approved it**

That's it. Keep scrap running while you listen.

> [!IMPORTANT]
> The current macOS build isn't signed (because it's kinda 200$ a year). If macOS blocks it, go to **System Settings -> Privacy & Security -> Open Anyway** after trying to open it.
>
> Visit [Apple Support](https://support.apple.com/en-gb/102445) for more info.

---

## Building from Source

### macOS

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
> Keep `.env` gitignored. Its contents are included in compiled builds, so don't put personal account credentials or anything "secret" in it.

---

## Common Issues

### Nothing playing

- Make sure you're playing something in Apple Music
- Check **System Settings -> Privacy & Security -> Automation** (macOS)
- Allow scrap to access Music (macOS)

### Connected, but songs aren't scrobbling

- Make sure scrobbling isn't paused
- Keep scrap running while you listen
- Check your internet connection
- Use **Retry pending** if there are queued scrobbles

### Closed the window, but scrap is still running

That's normal. You can access it from the music-note icon in the menu bar (or on Windows, the scrap icon on the right of the taskbar)

To fully close it, choose **Quit scrap** from the menu.

### last.fm app credentials are missing

If you're building from source, check that `.env` contains both required values, then rebuild the app.

## Support

If you're having issues, open an [issue](https://github.com/swagdotsh/scrap/issues). Include your operating system, scrap version, and what happened.

For Windows reports, mention that you're using the beta.

## Contributing

Contributions are welcome: bug fixes, platform improvements, docs, etc.

Suggested workflow:

1. Fork the repo
2. Create a feature branch
3. Make changes
4. Open a PR with a clear description and testing notes
