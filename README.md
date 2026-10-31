# WeatherBar

A small native macOS menu bar weather app. The menu bar shows the current conditions icon with two
stacked columns: the current temperature in °F over °C, and today's high over low. Click it for a
two-column forecast panel.

![Dropdown](docs/dropdown.png)

## Features

- **Menu bar:** conditions icon plus `56°F  H 65°` over `13°C  L 47°`, drawn as a template image so
  it follows light and dark menu bars.
- **Dropdown, left column:** current conditions (temperature in both units, feels-like, humidity,
  wind), then the next 10 hours with temperature, conditions, precipitation chance, wind and gusts,
  feels-like and humidity.
- **Dropdown, right column:** today's high and low, conditions, precipitation, humidity, wind,
  gusts, sunrise and sunset, then the next 7 days with highs, lows, conditions, precipitation chance,
  rain amount, wind and gusts.
- **Both units everywhere.** A Celsius-first setting flips every temperature, including the menu
  bar's high and low.
- **Location:** uses this Mac's location through Location Services and shows it as "City, ST". If
  that is denied or unavailable it falls back to a fixed place, Novi, MI by default.
- **Settings window:** Mac location or fixed place, place search by name, card counts, Celsius
  first, start at login.
- **Open Weather App** opens Apple's Weather app. **Refresh** fetches immediately; otherwise it
  refreshes every 10 minutes and on wake from sleep.
- **About window** with version and build date.

| Settings | About |
|---|---|
| ![Settings](docs/settings.png) | ![About](docs/about.png) |

## Requirements

- Apple Silicon Mac, macOS 13 or later. Intel is not supported.
- To build: Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not needed.

## Install

**From a release:** download `WeatherBar-<version>.zip` from the
[Releases](../../releases) page, unzip, and open `WeatherBar.app`. It is ad-hoc signed, not
notarized, so the first launch needs right-click, then Open. Or clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine WeatherBar.app
```

On first launch it offers to move itself to /Applications. Then turn on **Start WeatherBar at
login** in Settings. The login item points at the app's current location, so move it first.

**From source:**

```bash
./build.sh       # builds build/WeatherBar.app
./install.sh     # copies it to /Applications and launches it
```

## Settings from the command line

Everything in the Settings window is a `defaults` key. Quit and relaunch after changing one.

```bash
defaults write com.mayhoo.weatherbar useLocation  -bool true     # use this Mac's location (default)
defaults write com.mayhoo.weatherbar place        -string "Novi, MI"
defaults write com.mayhoo.weatherbar latitude     -float 42.4806
defaults write com.mayhoo.weatherbar longitude    -float -83.4755
defaults write com.mayhoo.weatherbar celsiusFirst -bool true     # °C first, bar high/low in °C
defaults write com.mayhoo.weatherbar hours        -int 10        # hourly cards
defaults write com.mayhoo.weatherbar days         -int 7         # daily cards
defaults write com.mayhoo.weatherbar menuWidth    -float 440     # width of each dropdown column
defaults write com.mayhoo.weatherbar refreshMinutes -int 10
defaults write com.mayhoo.weatherbar fontSize     -float 9       # menu bar text size
defaults write com.mayhoo.weatherbar bigTemp      -bool true     # add a large temp before the columns
defaults write com.mayhoo.weatherbar skipMovePrompt -bool true   # never offer to move to /Applications
```

## Development

The whole app is one file, `main.swift`, using AppKit, CoreLocation and ServiceManagement. There is
no Xcode project.

| File | Purpose |
|---|---|
| `main.swift` | The app: data fetch, menu bar drawing, dropdown cards, Settings and About windows. |
| `Info.plist` | Bundle metadata. Menu bar only (`LSUIElement`), location permission text, version. |
| `build.sh` | Compiles with `swiftc`, builds `AppIcon.icns` from `icon.png`, stamps the build date, ad-hoc signs. |
| `install.sh` | Copies the built app to /Applications and launches it. |
| `icon.png` | App icon source, 1024 × 1024. |
| `docs/` | Screenshots and the alternate icon candidate. |

**Test modes** run headless, which is useful over SSH or in CI:

```bash
B=build/WeatherBar.app/Contents/MacOS/WeatherBar
$B --once                          # print one fetch to stdout
$B --geocode "East Lansing"        # test the place search
$B --render out.png [--light]      # draw the dropdown to a PNG
$B --render-settings out.png       # draw the Settings window
$B --render-about out.png          # draw the About window
```

**Versioning:** the version lives in `Info.plist` (`CFBundleShortVersionString`). Bump it there,
commit, then tag `v<version>` to publish a release.

## Continuous integration

`.github/workflows/build.yml` runs on every push to `main`, on pull requests, and on demand. On an
Apple Silicon macOS runner it:

1. Builds the app with `build.sh`.
2. Checks the bundle: valid plist, icon present, arm64 binary, valid signature.
3. Smoke-tests a live weather fetch and a place search. These don't fail the build if the weather
   service is unreachable.
4. Renders the dropdown, Settings and About windows to PNGs.
5. Uploads the zipped app and the renders as build artifacts.

Pushing a tag such as `v1.4` also publishes a GitHub Release with the zipped app attached. The
release job fails if the tag doesn't match the version in `Info.plist`.

## Data and credits

- Weather and place search from [Open-Meteo](https://open-meteo.com), free with no API key.
- Icons are Apple SF Symbols, the same family Apple Weather uses.
- **Why not Apple WeatherKit:** it requires a paid Apple Developer Program membership and an app
  signed with the WeatherKit entitlement. Switching would mean replacing `fetchWeather` with a
  `WeatherService` call and signing with a developer certificate.

## History

| Version | Date | Change |
|---|---|---|
| 1.0 | Oct 26, 2026 | Menu bar icon, °F and °C, today's high and low. |
| 1.1 | Oct 26, 2026 | Stacked two-column menu bar text, hourly and daily forecast. |
| 1.2 | Oct 26, 2026 | Card-style dropdown with Current and Today sections. |
| 1.3 | Oct 26, 2026 | Settings and About windows, Mac location, start at login, app icon. |
| 1.4 | Oct 26, 2026 | Celsius first, solid cards, move-to-Applications prompt. |
| 1.4 | Oct 27, 2026 | Two-column dropdown. Build date without time. |

## License

Copyright 2026 Duane May. Licensed under the [Apache License, Version 2.0](LICENSE).
