# scrap 2.0 for Mac

Everything added in scrap 2.0 (PR #14, merged into `main` as `d9b3206`, plus a follow-up PR). The app, widget and [untitled] helper are versioned 2.0.

---

# In-app artist, album, track & tag pages

Clicking an artist, album, track or tag anywhere in scrap now opens an in-app page instead of jumping to last.fm. This is ported from the iPhone version (`~/scrapiOS/MUSIC_PAGES.md`) and adapted for the Mac.

## Where it applies

Every last.fm `/music/...` and `/tag/...` link is intercepted through SwiftUI's `openURL` environment:

- Now Playing (track, artist, album, tags, top tracks/albums, similar artists, "More about *artist*")
- Scrobbles
- Reports (including top tags)
- Profile charts and the "See more" chart gallery
- Links inside the pages themselves

User and friend profile links still open on last.fm.

## The window

The main window is fixed at 680×350, so the pages open in a separate resizable window (560×720 by default) instead of a bottom sheet.

- Clicking a link from the main app shows that page in the window and brings it to the front.
- Clicking a link inside the window opens the new page on top. A **Back** button (⌘[) appears at the top left.
- **Top right:** **Share** opens the macOS share menu for the page's last.fm link. Its first item is **Open in last.fm**, shown with the last.fm logo.
- Close the window with the normal close button.

## The page

- **Header:** the name in large bold text. For albums the artist is underneath; for tracks it's `Artist - Album`. Each part opens its own page.
- **Artwork:** large cover image (artist photo for artists, the tag's most popular artist for tags).
- **Stats:** three columns: **Listeners**, **Scrobbles** (across all of last.fm) and **Your scrobbles**. Tags show **Taggings** instead of Scrobbles.
- **Tags:** tag chips (**Similar tags** on tag pages, shown only when last.fm has some).
- **About:** description trimmed to 5 lines. **View more** opens the full text in a resizable sheet.
- **Your scrobbles:** a monthly bar chart (see below).

### Lists

Every list on artist and tag pages shows the first 5 entries, with a **View more** link that expands it to 10. Each section expands on its own.

### Artist pages

1. Popular tracks
2. Popular albums
3. Your top tracks by this artist
4. Your top albums by this artist
5. Similar artists, shown as a horizontal carousel

### Album pages

1. Full tracklist with track numbers and durations. Each track opens its own page.
2. "More by *artist*" carousel. last.fm's API has no similar-albums endpoint, so this replaces it.

### Track pages

1. Similar tracks carousel

### Tag pages

1. Popular artists
2. Popular albums
3. Popular tracks
4. Your top artists
5. Your top albums
6. Your top tracks

## "Your scrobbles" chart

Sits under the About section on every page.

- One bar per month for the last 12 months (current month on the right), labelled with the month's first letter.
- Bar height = how many times you scrobbled the artist, album or track that month. The busiest month is highlighted.
- The scale on the right always shows at most three values, starting at 0, rounded to fit your busiest month: a peak of 500 gives `0 / 250 / 500`, a peak of 2,000 gives `0 / 1,000 / 2,000`.
- Data comes from `user.getWeeklyArtistChart` / `user.getWeeklyAlbumChart` / `user.getWeeklyTrackChart`, called with each month's date range (4 requests at a time).
- Each month's chart is cached for the session and reused across pages. The current month refreshes after 10 minutes.

## How "your top" lists work

last.fm has no endpoint for these.

- **Artist pages:** scrap walks your all-time `user.getTopTracks` / `user.getTopAlbums` charts (500 per page, up to 6 pages) and filters by artist. It stops early once it has enough results or has accounted for all your plays of that artist. Pages are cached for 15 minutes.
- **Tag pages:** scrap takes the tag's top 500 artists (`tag.getTopArtists`).
  - **Your top artists:** your top 1,000 artists that are in that set.
  - **Your top albums and tracks:** entries from your top 1,000 of each that are by those artists.
  - **Your scrobbles** (stat and chart): your plays of those artists.

  An artist outside the tag's top 500 isn't counted, even if you tagged them yourself.

## last.fm API calls used

`artist.getInfo`, `album.getInfo`, `track.getInfo`, `tag.getInfo`, `artist.getTopTracks`, `artist.getTopAlbums`, `artist.getSimilar`, `track.getSimilar`, `tag.getSimilar`, `tag.getTopArtists`, `tag.getTopAlbums`, `tag.getTopTracks`, `user.getTopArtists`, `user.getTopTracks`, `user.getTopAlbums`, `user.getWeekly*Chart`.

---

# Profile updates

## Join date

Under the scrobble count on the Profile page: **Joined 28 Jul 2022** (from `user.getInfo` → `registered`).

## "last.fm and You"

A new row under the profile card:

| Item | Icon (SF Symbol) | Shows |
| --- | --- | --- |
| Artists | `music.mic` | How many **different** artists you've scrobbled |
| Albums | `square.stack` | How many different albums |
| Tracks | `music.note` | How many different tracks |

These are counts of distinct items, not scrobble totals. They come from `user.getInfo` (`artist_count` / `album_count` / `track_count`) when last.fm includes them; otherwise from the `total` of your all-time `user.getTopArtists` / `getTopAlbums` / `getTopTracks` charts.

## New chart periods

The period picker (Profile charts and "See more") now offers:

1. **Last 24 hours** *(new)*
2. Last 7 days
3. Last 30 days
4. **Last 6 months** *(new, last.fm's `6month` period)*
5. **2026** *(new; always the current year, counted from January 1st)*
6. Last 365 days
7. All time

last.fm's top charts have no 24-hour or calendar-year period, so those options use `user.getWeeklyArtistChart` / `getWeeklyAlbumChart` / `getWeeklyTrackChart` for exactly the last 24 hours, or from Jan 1 to now. Results are sorted by plays and cached for 5 minutes. Those charts don't include artwork, so album and track covers are looked up per row.

---

# Discord Rich Presence: an app ID per service

Before, every service used the one `DISCORD_APPLICATION_ID`, so Spotify and [untitled] also showed as "Listening to Apple Music".

- Two new optional `.env` keys: `DISCORD_APPLICATION_ID_SPOTIFY` and `DISCORD_APPLICATION_ID_UNTITLED`.
- Apple Music keeps using `DISCORD_APPLICATION_ID`. Spotify and [untitled] fall back to it when their own ID isn't set.
- Discord ties each connection to one app ID, so when you switch to a service with a different ID, scrap disconnects and reconnects under the new one. The old activity is cleared.
- The preview in the Discord settings shows "Listening to …" with the name of the Discord app the selected service uses.
- The README documents the new keys.

---

# Now Playing

## Local Apple Music covers

When the song is playing in Apple Music on this Mac, the cover in Now Playing and in the highlighted "Now playing" card in Scrobbles is read straight from the Music app instead of downloaded from last.fm, so it shows up faster.

- Covers for the last 8 tracks stay cached.
- If Music has no artwork for the track, or the song is from Spotify, [untitled] or another scrobbler, it falls back to the last.fm cover.
- If "prioritize animated covers" is on and last.fm has an animated cover, that replaces the local one once it loads.
- Discord's "cover from the music app" option uses the same code.

## Top albums under "About *artist*"

- scrap fetches 10 albums and drops variants of one already listed, then shows the top 3. A variant is the same name with a bracketed tag like `[Explicit]` or `(Deluxe)`, or the same name followed by credits that include the artist. Different titles like "Vol. 2" or "Vol. 1 Remixes" are kept.
- Albums without a cover from last.fm get one looked up.
- Long album and track names are left-aligned and cut off after 2 lines.

## Other changes

- The artist/album line under the track title is bigger (`.body`, 13pt, instead of `.subheadline`, 11pt).
- "Read more on last.fm" is now **More about *artist***, which opens the in-app artist page.
- Tracks reported from somewhere else now say **"Now playing from another scrobbler"** and **"Reported from last.fm. This isn't coming from scrap."**

---

# Settings

## Support development

At the bottom of Settings → General, a "Support development" section with Ko-fi's official blue **Buy me a coffee** button. It opens https://ko-fi.com/zekkie. The button image is bundled in the app, so it doesn't contact Ko-fi until it's clicked.

---

# last.fm logo

The last.fm logo was traced from a PNG into an SVG (a single path, matching the original to within its anti-aliased edge), with a black and a white version. Both are in the asset catalog as `LastFMLogo` and `LastFMLogoWhite`. The black one is used as a template icon for "Open in last.fm" in the share menu, so macOS tints it for light and dark mode.

---

# Files

| File | Change |
| --- | --- |
| `scrap/MusicPage.swift` | **New.** `MusicItem` (last.fm URL ⇄ artist/album/track/tag), API loaders, the `.musicPages(client:)` modifier, the page window with back navigation and share button, the page view, the description sheet and the monthly chart. |
| `scrap/ProfileCharts.swift` | New chart periods (including Last 24 hours), custom-range charts, shared `chartEntries` helper, `libraryCount`, album artwork lookup. |
| `scrap/ContentView.swift` | `.musicPages` on the main window, join date, "last.fm and You", local covers, bigger metadata line, new wording. |
| `scrap/ChartGallery.swift` | `.musicPages` on the gallery, album cover lookup. |
| `scrap/ListeningDetails.swift` | Library counts on the profile, deduped top albums with cover lookup. |
| `scrap/ArtistDetails.swift` | `distinctAlbums` filter. |
| `scrap/AlbumArtwork.swift` | `LocalArtwork`, which reads covers from the Music app. |
| `scrap/AppConfiguration.swift` | The two new Discord ID keys. |
| `scrap/DiscordPresence.swift` | Per-service app IDs, reconnecting on switch, per-app names. |
| `scrap/DiscordSettingsView.swift` | Preview uses the selected service's app name. |
| `scrapTests/MusicPageTests.swift` | **New.** Link parsing, tag links, chart scale and album dedupe tests. |
| `scrapTests/DiscordPresenceTests.swift` | App ID fallback test. |
| `scrap/DesktopControls.swift` | Ko-fi button in General settings. |
| `scrap/Assets.xcassets` | `KofiButton`, `LastFMLogo` and `LastFMLogoWhite` images. |
| `scrap.xcodeproj/project.pbxproj` | Version 2.0. |
| `README.md` | Documents the new Discord keys. |
