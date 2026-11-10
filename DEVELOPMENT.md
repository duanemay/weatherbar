# Developing WeatherBar

## Building

The whole app is one file, `main.swift`, using AppKit, CoreLocation, ServiceManagement and CryptoKit.
There is no Xcode project and no third-party code. You need an Apple Silicon Mac with the Xcode Command
Line Tools (`xcode-select --install`).

```bash
./build.sh       # builds build/WeatherBar.app
./install.sh     # copies it to /Applications and launches it
```

| File | Purpose |
|---|---|
| `main.swift` | The app: data fetch, menu bar drawing, forecast cards, Settings and About windows, updater. |
| `Info.plist` | Bundle metadata. Menu bar only (`LSUIElement`), location permission text, version. |
| `build.sh` | Compiles with `swiftc`, builds `AppIcon.icns` from `icon.png`, stamps the build date, signs. |
| `install.sh` | Copies the built app to /Applications and launches it. |
| `icon.png` | App icon source, 1024 × 1024. |
| `docs/` | Screenshots and the alternate icon candidate. |

## Test modes

These run without a screen, which is useful over SSH and in CI.

```bash
B=build/WeatherBar.app/Contents/MacOS/WeatherBar
$B --once                          # print one fetch, including NWS wording and alerts
$B --geocode "East Lansing"        # test the place search
$B --render out.png [--light]      # draw the forecast panel to a PNG
$B --render-settings out.png       # draw the Settings window
$B --render-about out.png          # draw the About window
$B --render-bar out.png            # draw the menu bar item, with the alert dot, on dark and light bars
$B --check-update                  # ask GitHub Releases for a newer version
$B --apply-update                  # download, verify and install a newer version in place
```

To test the updater without GitHub, serve a release JSON and zip locally, point the app at it with
`defaults write com.mayhoo.weatherbar updateFeedURL -string http://127.0.0.1:8765/release.json`, run
`--apply-update`, then delete the key.

## Settings from the command line

Everything in the Settings window is a `defaults` key. Quit and relaunch after changing one.

```bash
defaults write com.mayhoo.weatherbar useLocation  -bool true     # use this Mac's location (default)
defaults write com.mayhoo.weatherbar place        -string "Novi, MI"
defaults write com.mayhoo.weatherbar latitude     -float 42.4806
defaults write com.mayhoo.weatherbar longitude    -float -83.4755
defaults write com.mayhoo.weatherbar useNWS       -bool false    # skip National Weather Service wording and alerts
defaults write com.mayhoo.weatherbar celsiusFirst -bool true     # °C first, bar high/low in °C
defaults write com.mayhoo.weatherbar hours        -int 10        # hourly cards
defaults write com.mayhoo.weatherbar days         -int 7         # daily cards
defaults write com.mayhoo.weatherbar menuWidth    -float 440     # width of each panel column
defaults write com.mayhoo.weatherbar refreshMinutes -int 10
defaults write com.mayhoo.weatherbar fontSize     -float 9       # menu bar text size
defaults write com.mayhoo.weatherbar bigTemp      -bool true     # add a large temperature before the columns
defaults write com.mayhoo.weatherbar skipMovePrompt -bool true   # never offer to move to /Applications
defaults write com.mayhoo.weatherbar updateMode   -string ask    # ask (default), auto, or off
defaults write com.mayhoo.weatherbar updateCheckHours -float 12  # hours between scheduled update checks
```

## Data sources

- **Open-Meteo** supplies every number and the place search. Free, no key.
- **National Weather Service** (`api.weather.gov`, US only, free, no key) supplies the wording for each
  day and night period, the current period's full forecast in the Today card, and active alerts. The
  app matches each day to the daytime period on that date and the night period starting that evening.
  Outside the US, or if the service doesn't answer within 10 seconds, the cards fall back to
  Open-Meteo's one-word conditions. Temperatures always come from Open-Meteo, so they can differ by a
  few degrees from the numbers inside the NWS text.
- **Why not Apple WeatherKit:** it needs a paid Apple Developer Program membership and an app signed with
  the WeatherKit entitlement.

## How updates work

The app asks `api.github.com/repos/duanemay/weatherbar/releases/latest` for the newest release at
launch, every 12 hours, and after a wake when the last check is over an hour old. When it finds a newer
version, it shows the notes of every release since the installed one. The choices are **Install and
Relaunch**, **Later** (which holds that version's prompt for 12 hours) and **Skip This Version**.

Before anything is replaced, the download must pass five checks. If any fails, the installed app is
left untouched.

1. Its SHA-256 matches the `.sha256` file published with the release.
2. Its bundle identifier is `com.mayhoo.weatherbar`.
3. Its version matches the release tag.
4. Its code signature verifies.
5. It is signed with the WeatherBar certificate below.

The new copy is unpacked beside the old one. After WeatherBar quits, a short script swaps the two,
restores the old copy if the swap fails, and relaunches.

## Code signing

Releases from 1.14 on are signed with a self-signed **WeatherBar Code Signing** certificate, SHA-1
`305D14CB4AA12B2559947D3F4CD41D4510371334`. Every version carries the same signing identity, so macOS
keeps permissions such as Location across updates. The updater pins this certificate in
`releaseSigningRequirement`, so changing it means shipping a new pin first.

The certificate isn't from Apple, so a freshly downloaded copy needs right-click, then Open, the first
time. Updates installed by the app aren't quarantined and open normally.

CI imports the certificate from the `SIGNING_CERT_P12` and `SIGNING_CERT_PASSWORD` Actions secrets into
a temporary keychain and passes it to `build.sh` through `SIGN_IDENTITY` and `SIGN_KEYCHAIN`. Local
builds without those variables are ad-hoc signed, which is fine for development.

## Continuous integration

`.github/workflows/build.yml` runs on every push to `main`, on pull requests, and on demand. On an Apple
Silicon macOS runner it:

1. Builds and signs the app.
2. Checks the bundle: valid plist, icon present, arm64 binary, valid signature. Tag builds must also
   carry the WeatherBar certificate.
3. Smoke-tests a live weather fetch and a place search. These don't fail the build if the weather
   service is unreachable.
4. Renders the panel, Settings and About windows to PNGs.
5. Zips the app, writes its SHA-256 checksum, and uploads both plus the renders as build artifacts.

The only external dependencies are the workflow's GitHub Actions, pinned to commit SHAs. Dependabot
(`.github/dependabot.yml`) checks them every Monday and opens one grouped pull request for any updates.

## Releasing

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Info.plist`.
2. Commit, then push an annotated tag `v<version>`.

The release job publishes the zip and its `.sha256` file, and fails if the tag doesn't match
`Info.plist`. Its notes list the commits since the previous tag that touched `main.swift`,
`Info.plist` or `icon.png`, one bullet each, after any summary written in the tag message. Users see
these notes in the update prompt, so write commit subjects for them. Installed copies pick up a release
within 12 hours, or at the next wake.
