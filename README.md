<div align="center">
<img width="219" height="450" alt="ios1" src="https://github.com/user-attachments/assets/2bf52a25-c464-4e7e-a0f3-548d01105ab8" />


# scrap for iPhone

A native last.fm scrobbler for iPhone. Requires iOS 27 and above.

This is the `ios` branch. For the macOS app (and Windows beta), see [`main`](https://github.com/swagdotsh/scrap).

[scrap website](https://scrap.swagrelated.com/)

</div>

## Features

### Scrobbling

- Scrobble songs from your Apple Music library to last.fm
- Update your last.fm now-playing status while scrap is open
- Skip plays that are already on last.fm (for example, ones your Mac scrobbled)
- **Scan…** for plays from the last two weeks that never made it to last.fm
- Queue unsuccessful scrobbles for retry
- Optional: scrobble songs that aren't in your library, love songs you've favorited in Apple Music

### Listening & discovery

- See how many times you've scrobbled an artist or track
- Artist biographies, tags, similar artists, top albums & tracks
- Weekly reports (Saturday to Friday): scrobbles vs last week, top artist, album and track, and new artists, albums and tracks you discovered
- Recent scrobbles and friends' recent listening

### Your last.fm account

- Your profile with top artists, albums & tracks for the last 7 days, 30 days, 365 days or all time
- Top 50 galleries for each
- Love / unlove the currently playing track

### iPhone extras

- Home screen widgets: **Top Artist** and **Recent Scrobbles**
- Lock screen widgets for your top artists
- Notifications every 5,000 scrobbles, when you discover a new artist, and when your weekly report is ready (Fridays at 16:00 Central European Time)
- Animated album covers (opt-in, paused in Low Power Mode and Low Data Mode)

## How scrobbling works on iPhone

iOS doesn't let apps watch what's playing in the background, so scrap can't scrobble in real time like the Mac app does. Instead it compares your Apple Music library's play counts with the last time it checked, and scrobbles the difference. It checks when you open scrap, when the song changes while it's open, when you pull to refresh, and whenever iOS lets it run in the background.

That means:

- Only songs **in your library** are counted this way. Turn on **Non-Library Track Scrobbling** in settings to also scrobble other songs while scrap is open.
- The very first check only takes note of your play counts. Plays before that aren't scrobbled; use **Scan…** to pick up the last two weeks.
- Scrobble times are close to when you played the song, not exact.
- iOS decides how often scrap runs in the background, based on how much you use it. Opening scrap now and then helps.

## Requirements

- **An iPhone on iOS 27 or above**
- **A Mac with Xcode 27** (scrap for iPhone isn't on the App Store yet, so you build it yourself)
- **Apple Music**, with the songs you want scrobbled in your library
- A **last.fm account** and your own [last.fm API credentials](https://www.last.fm/api/account/create)
- An **Apple Developer account**. A free Apple ID works, but apps installed with it expire after 7 days and some features (widgets, love favorited songs) may need a paid membership.

## Installing on your iPhone

1. Clone the repo and switch to this branch:

```bash
git clone https://github.com/swagdotsh/scrap.git
cd scrap
git switch ios
```

2. Create `scrap/LastFM.env` (inside the `scrap` folder, next to the Swift files):

```env
LASTFM_API_KEY=your_api_key
LASTFM_SHARED_SECRET=your_shared_secret
```

3. Open `scrap.xcodeproj` in Xcode
4. For both the **scrap** and **scrapWidgets** targets, go to **Signing & Capabilities** and pick your team. If you use your own team, change the bundle identifiers (`com.swagrelated.scrap` and `com.swagrelated.scrap.widgets`) and the App Group (`group.com.swagrelated.scrap`) to ones you own, and update the App Group name in `scrap/WidgetSync.swift` and `scrapWidgets/WidgetLastFM.swift` to match.
5. On your iPhone, turn on **Settings → Privacy & Security → Developer Mode** (your iPhone will restart)
6. Plug in your iPhone, select it as the run destination and press **⌘R**
7. If your iPhone says the developer isn't trusted, go to **Settings → General → VPN & Device Management** and trust it

## First run

1. Tap **Connect last.fm** and approve scrap. If the page doesn't close by itself after approving, close it and scrap will finish signing in.
2. Allow scrap to access Apple Music when asked
3. Allow notifications if you want milestones and weekly reports
4. Optional: tap **Scan…** to scrobble plays from the last two weeks

### Widgets

Long-press your home screen or lock screen, tap **Edit → Add Widget** and search for scrap. To change the Top Artist period, long-press the widget and choose **Edit Widget**. Open scrap at least once after signing in so the widgets know your account.

### Love favorited songs

This uses the Apple Music API, which needs the **MusicKit** app service. Go to [developer.apple.com](https://developer.apple.com/account/resources/identifiers/list) → **Identifiers**, open your app's identifier, turn on **MusicKit** under **App Services** and save. It may also need an Apple Music subscription.

### iPhone Settings

**Settings → Apps → scrap** has the version, links, acknowledgements, the license and a **Sign Out** switch (it signs you out the next time scrap opens).

> [!CAUTION]
> Keep `LastFM.env` gitignored. Its contents are included in the app, so don't put personal account credentials in it.

---

## Common Issues

### Songs aren't scrobbling

- Make sure the songs are in your Apple Music library, or turn on **Non-Library Track Scrobbling**
- Open scrap or pull to refresh to check for new plays
- Make sure scrobbling isn't paused and **Background Work** is on in settings
- Check **Settings → General → Background App Refresh** is on for scrap
- If scrobbles are waiting to send, use **Send waiting scrobbles** on the Scrobbles tab

### Plays from before I installed scrap are missing

The first check only records your play counts. Use **Scan…** to find plays from the last two weeks; last.fm rejects anything older.

### Nothing playing

- Play something in Apple Music
- Check **Settings → Apps → scrap → Media & Apple Music** is allowed

### Widgets say "Open scrap to sign in"

Open scrap once after signing in. If it still happens, check that both targets use the same App Group.

### "Connect last.fm" is greyed out

`scrap/LastFM.env` is missing or doesn't have both values. Add it and rebuild.

### The app stopped opening after a week

Apps installed with a free Apple ID expire after 7 days. Plug in your iPhone and run it from Xcode again.

## Support

If you're having issues, open an [issue](https://github.com/swagdotsh/scrap/issues). Include your iPhone model, iOS version, and what happened, and mention that you're using the iPhone version.

## Contributing

Contributions are welcome: bug fixes, iPhone improvements, docs, etc.

1. Fork the repo
2. Create a feature branch from `ios`
3. Make changes
4. Open a PR into `ios` with a clear description and testing notes
