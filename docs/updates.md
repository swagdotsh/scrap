# macOS updates

Scrap 1.4 uses Sparkle 2 to check, download, verify, install, and relaunch updates. Settings → Updates offers a manual check, daily automatic checks (on by default), and automatic download/installation (off by default). Sparkle remembers these preferences. Automatic installations normally finish on quit; its standard UI can offer a restart. The old GitHub checker and reminder timer are no longer used.

Versions before 1.4 still open GitHub and need one final manual installation. Publishing a GitHub release alone is not enough for Sparkle: publish its matching update feed too.

## Signing key

`Config/Info.plist` contains only the public Ed25519 key. The matching private key is in the maintainer's login Keychain, under Sparkle's signing-key service and account `com.swagrelated.scrap`. The release-preparation script checks that this key matches the built app before signing. Never commit or upload the private key. Keep a secure backup using Sparkle's `generate_keys --account com.swagrelated.scrap -x <private-backup-file>` if needed. Store that backup outside this repository. Retain the same key for future releases.

This signature authenticates the update archive; it is separate from Apple Developer ID signing and notarization. The current build uses ad-hoc Apple signing. Sparkle verifies the archive signature before extraction. Its installer XPC service and sandbox communication entitlements are enabled because Scrap is sandboxed.

## Prepare a release

1. Set **both** `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the app's Debug and Release configurations to the new version (for example, `1.4.1`). Sparkle compares `CFBundleVersion`; do not leave the build number unchanged.
2. Build a universal Release app with the project's normal signing enabled:

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
     -project scrap.xcodeproj -scheme scrap -configuration Release \
     -derivedDataPath build/Release -destination 'generic/platform=macOS' \
     'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
   ```

3. Prepare and verify the archive and candidate feed:

   ```sh
   python3 scripts/prepare-update.py \
     --app build/Release/Build/Products/Release/scrap.app \
     --sparkle-tools build/Release/SourcePackages/artifacts/sparkle/Sparkle/bin
   ```

   Optionally pass `--notes path/to/release-notes.txt` to embed release notes. Outputs go to `Releases/<version>/`: the universal ZIP, SHA-256 checksum, and candidate `appcast.xml`. The script preserves existing feed entries, rejects duplicate/older versions, checks the bundle configuration and both CPU architectures, verifies code signatures, and verifies the new archive's update signature. It does not publish anything or overwrite the root feed. Keep prepared ZIPs unchanged after signing.

4. Test the prepared app and a real update from an older Sparkle-enabled build using disposable copies before public release. Verify download, quit/install/relaunch, retained account/settings, menu-bar-only operation, and login startup. Do not use the installed daily-use app as a test target.

## Publish, in this order

1. Upload the prepared ZIP and checksum to the GitHub release tagged `v<version>` in `swagdotsh/scrap`. Confirm the archive URL in the candidate feed downloads the exact uploaded archive.
2. Copy `Releases/<version>/appcast.xml` to the repository root, review, commit, and publish it on `main`.
3. Verify the live feed at `https://raw.githubusercontent.com/swagdotsh/scrap/main/appcast.xml` and test **Check for Updates…** from an older test build.

The feed URL is deliberately separate from GitHub's latest-release endpoint, so Windows releases do not become macOS update candidates. Do not publish a feed before its download is available, or edit an archive after generating its signature.

The first prepared 1.4 archive and feed are local until these publishing steps are completed. Generating the files does not update the installed app or enable updates for existing users.
