# Contributing to scrap

Bug fixes, improvements, documentation, and compatibility reports are welcome. For larger changes, open an issue first so we can agree on the scope before you spend time building it.

## Choose the right branch

scrap's platform versions live on separate branches. Start from the branch you want to change and target that same branch when opening a pull request:

| Platform | Base branch |
| --- | --- |
| macOS | `main` |
| iPhone | `ios` |
| Windows | `windows-app-sdk` |

Use the README on your chosen branch for its setup instructions. Keep platform changes separate: do not merge the entire Windows branch into `main`. Shared fixes should be ported individually. The repository checks pull requests to `main` with the **Platform branch guard** workflow.

## Build the macOS app

You need Xcode 27 and your own [last.fm API credentials](https://www.last.fm/api/account/create).

1. Fork the repository and clone your fork.
2. Start from `main` and create a branch for your change, such as `fix/menu-bar-layout`.
3. Create a `.env` file in the repository root:

   ```env
   LASTFM_API_KEY=your_api_key
   LASTFM_SHARED_SECRET=your_shared_secret
   ```

4. Open `scrap.xcodeproj` in Xcode.
5. Select the `scrap` scheme and your Mac as the destination, then build and run.

Keep `.env` ignored by Git. Its contents are copied into the app bundle, so use it only for the app's last.fm API configuration. Never add personal account credentials, session tokens, signing keys, or secrets to a commit, issue, or pull request.

## Make and test your change

Keep changes focused and follow the surrounding Swift, SwiftUI, and AppKit code. Avoid unrelated formatting or dependency updates.

The macOS app targets **macOS 14.6 and later**, on both Apple silicon and Intel. Guard newer APIs with availability checks and provide a fallback where needed. Building with a recent SDK does not establish that a change works on the oldest supported OS.

- Build the `scrap` scheme and run relevant tests using **Product → Test** in Xcode. Add or update tests when changing behavior that benefits from automated coverage.
- The test targets currently require **macOS 26.5**, even though the app targets 14.6. Report the OS you actually tested on; do not describe Sonoma compatibility as verified without running on Sonoma.
- For UI changes, check the main window, menu bar popover, and relevant preferences in light and dark appearance. Include screenshots when they help explain the change.
- For playback or scrobbling changes, check the affected music service, play/pause and track changes, and whether scrobbles are duplicated or missed. Use your own last.fm account: these checks can send real listening activity.
- If your change affects offline handling, check queuing and retry behavior. If it affects startup, check launch and the relevant login or Dock settings.

Describe any checks you could not run, including unavailable macOS versions, hardware, or music services.

## Open a pull request

Give your pull request a clear title and include:

- The problem being solved and what changes for users.
- A related issue, if there is one.
- How you tested it, including OS version and architecture where relevant.
- Screenshots for visible changes and any remaining limitations.

Make sure the pull request targets the correct platform branch and required checks pass. Leave generated builds, release archives, and local credentials out of the change. Release packaging and publishing are maintainer tasks; see [the update guide](docs/updates.md) for that workflow.

## Report a bug or suggest a feature

Search [existing issues](https://github.com/swagdotsh/scrap/issues) first. For a bug, include the platform, OS and scrap versions, music service, steps to reproduce, expected result, and actual result. Remove credentials and private listening or account information from logs and screenshots.

For a feature, explain the use case and how you expect it to work.

## License

scrap is licensed under the [MIT License](LICENSE), copyright (c) 2026 zekkie. By submitting a contribution, you agree that it can be distributed under that license.
