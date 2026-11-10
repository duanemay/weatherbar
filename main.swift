// WeatherBar — a tiny macOS menu bar weather widget.
// Menu bar:  [icon] 50°F  H 67°      (two small stacked columns; bigTemp adds a large number)
//                   10°C  L 48°
// Dropdown: card-style Current / Today / Next hours / Next days sections, Refresh, Open Weather App, Quit.
// Data: Open-Meteo (free, no key). Build: ./build.sh  (Swift CLT only, no Xcode needed)
//
// Location: uses this Mac's location (macOS Location Services, reverse-geocoded to "City, ST") when
// allowed; otherwise the fixed place from Settings; otherwise Novi, MI.
//
// Settings window (menu → Settings…) covers place / location / card counts / start at login.
// The same keys via defaults (all optional):
//   defaults write com.mayhoo.weatherbar useLocation -bool true   # default true
//   defaults write com.mayhoo.weatherbar celsiusFirst -bool true  # °C before °F everywhere, bar H/L in °C
//   defaults write com.mayhoo.weatherbar latitude  -float 42.4806
//   defaults write com.mayhoo.weatherbar longitude -float -83.4755
//   defaults write com.mayhoo.weatherbar place     -string "Novi, MI"
//   defaults write com.mayhoo.weatherbar refreshMinutes -int 10
//   defaults write com.mayhoo.weatherbar fontSize  -float 9      # small stacked text size in the bar
//   defaults write com.mayhoo.weatherbar bigFontSize -float 15   # the large current-temp number (if bigTemp)
//   defaults write com.mayhoo.weatherbar bigTemp   -bool true    # also show a large current-temp number (off by default)
//   defaults write com.mayhoo.weatherbar hours     -int 10       # hourly cards in the dropdown
//   defaults write com.mayhoo.weatherbar days      -int 7        # daily cards in the dropdown
//   defaults write com.mayhoo.weatherbar menuWidth -float 440    # width of EACH dropdown column (two columns)
//
// Test modes: WeatherBar --once            prints one fetch to stdout
//             WeatherBar --render out.png  draws the dropdown to a PNG (layout check without a screen)
//             WeatherBar --render-settings out.png / --render-about out.png
//             WeatherBar --check-update     ask GitHub Releases for a newer version (no install)
//             WeatherBar --apply-update     headless: download, verify and install a newer release in place
//
// Updates: checks https://api.github.com/repos/duanemay/weatherbar/releases/latest at launch and daily,
// offers to install a newer release, verifies it (SHA-256, bundle id, version, signature), swaps it in
// place and relaunches.
//   defaults write com.mayhoo.weatherbar autoCheckUpdates   -bool false  # no automatic checks
//   defaults write com.mayhoo.weatherbar autoInstallUpdates -bool true   # install without asking
//   defaults write com.mayhoo.weatherbar updateFeedURL -string URL       # testing: alternate release JSON
//   defaults write com.mayhoo.weatherbar skipMovePrompt -bool true       # never offer to move to /Applications
//             WeatherBar --geocode "Novi, MI"

import Cocoa
import CoreLocation
import ServiceManagement
import CryptoKit

let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
let buildDate = Bundle.main.infoDictionary?["WBBuildDate"] as? String ?? "unknown"

// MARK: - Config

enum Config {
    static let d = UserDefaults.standard
    static let defaultLat = 42.4806, defaultLon = -83.4755, defaultPlace = "Novi, MI"
    static var lat: Double  { (d.object(forKey: "latitude")  as? Double) ?? defaultLat }
    static var lon: Double  { (d.object(forKey: "longitude") as? Double) ?? defaultLon }
    static var place: String { d.string(forKey: "place") ?? defaultPlace }
    static var celsiusFirst: Bool { d.bool(forKey: "celsiusFirst") }
    static var autoCheckUpdates: Bool { d.object(forKey: "autoCheckUpdates") == nil ? true : d.bool(forKey: "autoCheckUpdates") }
    static var autoInstallUpdates: Bool { d.bool(forKey: "autoInstallUpdates") }
    static var skippedVersion: String? { d.string(forKey: "skippedVersion") }
    static var updateFeedURL: String {
        d.string(forKey: "updateFeedURL") ?? "https://api.github.com/repos/duanemay/weatherbar/releases/latest"
    }
    static var useLocation: Bool { d.object(forKey: "useLocation") == nil ? true : d.bool(forKey: "useLocation") }
    static var refreshMinutes: Double { let m = d.double(forKey: "refreshMinutes"); return m > 0 ? m : 10 }
    static var fontSize: CGFloat { let f = d.double(forKey: "fontSize"); return f > 0 ? CGFloat(f) : 9 }
    static var bigFontSize: CGFloat { let f = d.double(forKey: "bigFontSize"); return f > 0 ? CGFloat(f) : 15 }
    static var bigTemp: Bool { d.bool(forKey: "bigTemp") }   // default off: just the two stacked columns
    static var hours: Int { let n = d.integer(forKey: "hours"); return n > 0 ? n : 10 }
    static var days: Int { let n = d.integer(forKey: "days"); return n > 0 ? n : 7 }
    static var menuWidth: CGFloat { let w = d.double(forKey: "menuWidth"); return w > 0 ? CGFloat(w) : 440 }
}

// MARK: - Model

struct Hour {
    let time: Date; let tempF: Double; let feelsF: Double; let code: Int; let isDay: Bool
    let precip: Int; let humidity: Int; let windMph: Double; let windDir: Int; let gustMph: Double
}
struct Day {
    let date: Date; let hiF: Double; let loF: Double; let code: Int
    let precip: Int; let rainIn: Double; let windMph: Double; let gustMph: Double; let sunrise: Date?; let sunset: Date?
}
struct Weather {
    let tempF: Double; let feelsF: Double; let code: Int; let isDay: Bool
    let humidity: Int; let windMph: Double; let windDir: Int; let gustMph: Double
    let today: Day
    let hourly: [Hour]
    let daily: [Day]
    let fetched: Date
}

struct Place { var lat: Double; var lon: Double; var name: String; var fromMac = false }
var fixedPlace: Place { Place(lat: Config.lat, lon: Config.lon, name: Config.place) }

func toC(_ f: Double) -> Double { (f - 32) * 5 / 9 }
func deg(_ v: Double) -> String { "\(Int(v.rounded()))°" }
func fc(_ f: Double) -> String { Config.celsiusFirst ? "\(deg(toC(f)))C / \(deg(f))F" : "\(deg(f))F / \(deg(toC(f)))C" }
/// Primary-unit value with its letter ("56°F" or "13°C"), and the secondary one.
func primary(_ f: Double) -> String { Config.celsiusFirst ? "\(deg(toC(f)))C" : "\(deg(f))F" }
func secondary(_ f: Double) -> String { Config.celsiusFirst ? "\(deg(f))F" : "\(deg(toC(f)))C" }
func primaryDeg(_ f: Double) -> String { deg(Config.celsiusFirst ? toC(f) : f) }
func mph(_ v: Double) -> String { "\(Int(v.rounded())) mph" }
func compass(_ deg: Int) -> String {
    let names = ["N","NNE","NE","ENE","E","ESE","SE","SSE","S","SSW","SW","WSW","W","WNW","NW","NNW"]
    return names[Int((Double(deg) / 22.5).rounded()) % 16]
}

/// WMO weather code → (SF Symbol name, plain-English description). Day/night variants where Apple has them.
func symbol(for code: Int, isDay: Bool) -> (String, String) {
    switch code {
    case 0:        return (isDay ? "sun.max.fill" : "moon.stars.fill", "Clear")
    case 1:        return (isDay ? "sun.max.fill" : "moon.fill", "Mostly Clear")
    case 2:        return (isDay ? "cloud.sun.fill" : "cloud.moon.fill", "Partly Cloudy")
    case 3:        return ("cloud.fill", "Cloudy")
    case 45, 48:   return ("cloud.fog.fill", "Foggy")
    case 51, 53, 55: return ("cloud.drizzle.fill", "Drizzle")
    case 56, 57:   return ("cloud.sleet.fill", "Freezing Drizzle")
    case 61, 63:   return ("cloud.rain.fill", "Rain")
    case 65:       return ("cloud.heavyrain.fill", "Heavy Rain")
    case 66, 67:   return ("cloud.sleet.fill", "Freezing Rain")
    case 71, 73:   return ("cloud.snow.fill", "Snow")
    case 75:       return ("snowflake", "Heavy Snow")
    case 77:       return ("snowflake", "Snow Grains")
    case 80, 81:   return (isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill", "Showers")
    case 82:       return ("cloud.heavyrain.fill", "Heavy Showers")
    case 85, 86:   return ("cloud.snow.fill", "Snow Showers")
    case 95:       return ("cloud.bolt.fill", "Thunderstorm")
    case 96, 99:   return ("cloud.bolt.rain.fill", "Thunderstorm with Hail")
    default:       return ("questionmark.circle", "Unknown")
    }
}

// MARK: - Fetch

enum FetchError: LocalizedError {
    case badURL, noData, badJSON(String)
    var errorDescription: String? {
        switch self {
        case .badURL: return "bad URL"
        case .noData: return "no data"
        case .badJSON(let s): return "unexpected response (\(s))"
        }
    }
}

func fmt(_ pattern: String) -> DateFormatter {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = pattern; f.timeZone = .current; return f
}
let localISO = fmt("yyyy-MM-dd'T'HH:mm")
let localDay = fmt("yyyy-MM-dd")
let hourFmt = fmt("h a")
let dayFmt = fmt("EEE")
let clockFmt = fmt("h:mm a")

func fetchWeather(_ place: Place, completion: @escaping (Result<Weather, Error>) -> Void) {
    let tz = TimeZone.current.identifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "auto"
    let urlString = "https://api.open-meteo.com/v1/forecast"
        + "?latitude=\(place.lat)&longitude=\(place.lon)"
        + "&current=temperature_2m,apparent_temperature,weather_code,is_day,relative_humidity_2m,wind_speed_10m,wind_direction_10m,wind_gusts_10m"
        + "&hourly=temperature_2m,apparent_temperature,weather_code,is_day,precipitation_probability,relative_humidity_2m,wind_speed_10m,wind_direction_10m,wind_gusts_10m"
        + "&daily=temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max,precipitation_sum,wind_speed_10m_max,wind_gusts_10m_max,sunrise,sunset"
        + "&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch&timezone=\(tz)&forecast_days=\(Config.days + 2)"
    guard let url = URL(string: urlString) else { completion(.failure(FetchError.badURL)); return }
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    req.setValue("WeatherBar/\(appVersion) (macOS menu bar)", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: req) { data, _, err in
        if let err = err { completion(.failure(err)); return }
        guard let data = data else { completion(.failure(FetchError.noData)); return }
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FetchError.badJSON("root") }
            if let reason = root["reason"] as? String { throw FetchError.badJSON(reason) }
            guard let cur = root["current"] as? [String: Any],
                  let daily = root["daily"] as? [String: Any],
                  let hourly = root["hourly"] as? [String: Any],
                  let t = cur["temperature_2m"] as? Double,
                  let code = cur["weather_code"] as? Int,
                  let dTimes = daily["time"] as? [String],
                  let hTimes = hourly["time"] as? [String]
            else { throw FetchError.badJSON("missing fields") }

            func num(_ dict: [String: Any], _ k: String) -> Double { (dict[k] as? Double) ?? Double((dict[k] as? Int) ?? 0) }
            func col(_ dict: [String: Any], _ k: String) -> [Double] {
                (dict[k] as? [Any] ?? []).map { ($0 as? Double) ?? Double(($0 as? Int) ?? 0) }
            }
            func at(_ a: [Double], _ i: Int) -> Double { i < a.count ? a[i] : 0 }
            func time(_ dict: [String: Any], _ k: String, _ i: Int) -> Date? {
                guard let a = dict[k] as? [String], i < a.count else { return nil }
                return localISO.date(from: a[i])
            }

            let hTemp = col(hourly, "temperature_2m"), hFeel = col(hourly, "apparent_temperature")
            let hCode = col(hourly, "weather_code"), hDay = col(hourly, "is_day"), hPrec = col(hourly, "precipitation_probability")
            let hHum = col(hourly, "relative_humidity_2m"), hWind = col(hourly, "wind_speed_10m")
            let hDir = col(hourly, "wind_direction_10m"), hGust = col(hourly, "wind_gusts_10m")
            let dHi = col(daily, "temperature_2m_max"), dLo = col(daily, "temperature_2m_min"), dCode = col(daily, "weather_code")
            let dPrec = col(daily, "precipitation_probability_max"), dRain = col(daily, "precipitation_sum")
            let dWind = col(daily, "wind_speed_10m_max"), dGust = col(daily, "wind_gusts_10m_max")

            func day(_ i: Int) -> Day? {
                guard i < dTimes.count, i < dHi.count, i < dLo.count, let d = localDay.date(from: dTimes[i]) else { return nil }
                return Day(date: d, hiF: dHi[i], loF: dLo[i], code: Int(at(dCode, i)), precip: Int(at(dPrec, i)),
                           rainIn: at(dRain, i), windMph: at(dWind, i), gustMph: at(dGust, i),
                           sunrise: time(daily, "sunrise", i), sunset: time(daily, "sunset", i))
            }
            guard let today = day(0) else { throw FetchError.badJSON("no daily") }

            let startOfHour = Date().addingTimeInterval(-3600)
            var hours: [Hour] = []
            for i in 0..<min(hTimes.count, hTemp.count) {
                guard let d = localISO.date(from: hTimes[i]), d > startOfHour else { continue }
                hours.append(Hour(time: d, tempF: hTemp[i], feelsF: at(hFeel, i), code: Int(at(hCode, i)), isDay: at(hDay, i) == 1,
                                  precip: Int(at(hPrec, i)), humidity: Int(at(hHum, i)), windMph: at(hWind, i),
                                  windDir: Int(at(hDir, i)), gustMph: at(hGust, i)))
                if hours.count >= Config.hours + 1 { break }
            }
            var days: [Day] = []
            for i in 1..<dTimes.count { if let d = day(i) { days.append(d) }; if days.count >= Config.days { break } }

            completion(.success(Weather(tempF: t, feelsF: cur["apparent_temperature"] as? Double ?? t, code: code,
                                        isDay: (cur["is_day"] as? Int ?? 1) == 1, humidity: Int(num(cur, "relative_humidity_2m")),
                                        windMph: num(cur, "wind_speed_10m"), windDir: Int(num(cur, "wind_direction_10m")),
                                        gustMph: num(cur, "wind_gusts_10m"), today: today, hourly: hours, daily: days, fetched: Date())))
        } catch { completion(.failure(error)) }
    }.resume()
}

// MARK: - Geocoding (Open-Meteo, free) and this Mac's location

struct GeoResult { let name: String; let lat: Double; let lon: Double }

func geocode(_ query: String, completion: @escaping ([GeoResult]) -> Void) {
    let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    guard let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(q)&count=8&language=en&format=json")
    else { completion([]); return }
    URLSession.shared.dataTask(with: url) { data, _, _ in
        var out: [GeoResult] = []
        if let data = data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = root["results"] as? [[String: Any]] {
            for r in results {
                guard let n = r["name"] as? String, let la = r["latitude"] as? Double, let lo = r["longitude"] as? Double else { continue }
                let parts = [n, r["admin1"] as? String, r["country_code"] as? String].compactMap { $0 }
                out.append(GeoResult(name: parts.joined(separator: ", "), lat: la, lon: lo))
            }
        }
        completion(out)
    }.resume()
}

/// Asks macOS for the Mac's location once and reverse-geocodes it to "City, ST".
final class LocationResolver: NSObject, CLLocationManagerDelegate {
    private let mgr = CLLocationManager()
    var onResolved: ((Place) -> Void)?
    var onFailed: ((String) -> Void)?
    private var asked = false

    func start() {
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyKilometer
        if !CLLocationManager.locationServicesEnabled() { onFailed?("Location Services are off"); return }
        handle(mgr.authorizationStatus)
    }
    private func handle(_ st: CLAuthorizationStatus) {
        switch st {
        case .notDetermined:
            if !asked { asked = true; mgr.requestWhenInUseAuthorization() }
        case .denied: onFailed?("location access denied for WeatherBar")
        case .restricted: onFailed?("location access restricted")
        default: mgr.requestLocation()
        }
    }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { handle(m.authorizationStatus) }
    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        CLGeocoder().reverseGeocodeLocation(l) { [weak self] pms, _ in
            let p = pms?.first
            var name = [p?.locality, p?.administrativeArea].compactMap { $0 }.joined(separator: ", ")
            if name.isEmpty { name = String(format: "%.2f, %.2f", l.coordinate.latitude, l.coordinate.longitude) }
            self?.onResolved?(Place(lat: l.coordinate.latitude, lon: l.coordinate.longitude, name: name, fromMac: true))
        }
    }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) { onFailed?(e.localizedDescription) }
}

// MARK: - Text rows (CLI + detail lines)

func hourDetail(_ h: Hour) -> String {
    "Prec \(h.precip)% • Wind \(compass(h.windDir)) \(mph(h.windMph)), gusts \(Int(h.gustMph.rounded())) • Feels \(fc(h.feelsF)) • Hum \(h.humidity)%"
}
func dayDetail(_ d: Day) -> String {
    var s = "Prec \(d.precip)%"
    if d.rainIn > 0 { s += " • \(String(format: "%.2f", d.rainIn))\" rain" }
    s += " • Wind \(mph(d.windMph)), gusts \(Int(d.gustMph.rounded()))"
    return s
}
func todayDetail(_ w: Weather) -> String {
    var s = "Precipitation: \(w.today.precip)% • Humidity: \(w.humidity)% • Wind: \(compass(w.windDir)) \(mph(w.windMph)) • Gusts \(mph(w.gustMph))"
    if let r = w.today.sunrise, let t = w.today.sunset { s += " • Sunrise: \(clockFmt.string(from: r)) • Sunset: \(clockFmt.string(from: t))" }
    return s
}

// MARK: - Dropdown card views

func symbolImage(_ name: String, size: CGFloat) -> NSImage? {
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    let out = img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular)) ?? img
    out.isTemplate = true
    return out
}

final class CardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 6, dy: 2)
        let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill(); path.fill()   // opaque base: no desktop bleed-through
        NSColor.labelColor.withAlphaComponent(0.06).setFill(); path.fill()              // slight tint so cards stand out
        NSColor.separatorColor.setStroke(); path.lineWidth = 0.5; path.stroke()
    }
}

func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
               frame: NSRect, lines: Int = 1) -> NSTextField {
    let l = lines > 1 ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
    l.font = NSFont.systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.maximumNumberOfLines = lines
    l.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
    l.frame = frame
    return l
}

/// One card: [leading label] [icon] [headline / subline] [detail text, wraps].
/// `detailLead`, when given, starts the right-hand text in the primary colour (e.g. the day's conditions),
/// so it can wrap across the wide right side instead of being cut off under the temperatures.
func card(width: CGFloat, height: CGFloat, leading: String, icon: String, headline: String, subline: String, detail: String,
          detailLead: String? = nil) -> NSView {
    let v = CardView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    let midY = height / 2
    v.addSubview(makeLabel(leading, size: 12, weight: .semibold, frame: NSRect(x: 14, y: midY - 8, width: 44, height: 16)))
    let iv = NSImageView(frame: NSRect(x: 60, y: midY - 15, width: 30, height: 30))
    iv.image = symbolImage(icon, size: 24); iv.imageScaling = .scaleProportionallyUpOrDown
    v.addSubview(iv)
    v.addSubview(makeLabel(headline, size: 14, weight: .bold, frame: NSRect(x: 98, y: midY + 1, width: 136, height: 18)))
    v.addSubview(makeLabel(subline, size: 11, color: .secondaryLabelColor, frame: NSRect(x: 98, y: midY - 15, width: 136, height: 14)))
    let detailLabel = makeLabel(detail, size: 10.5, color: .secondaryLabelColor,
                                frame: NSRect(x: 236, y: 5, width: width - 236 - 14, height: height - 10), lines: 3)
    if let lead = detailLead {
        let t = NSMutableAttributedString(string: lead, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.labelColor])
        t.append(NSAttributedString(string: " • " + detail, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.secondaryLabelColor]))
        detailLabel.attributedStringValue = t
    }
    v.addSubview(detailLabel)
    return v
}

func currentCard(_ w: Weather, width: CGFloat) -> NSView {
    let height: CGFloat = 92
    let v = CardView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    let (sym, desc) = symbol(for: w.code, isDay: w.isDay)
    let iv = NSImageView(frame: NSRect(x: 16, y: height / 2 - 26, width: 52, height: 52))
    iv.image = symbolImage(sym, size: 44); iv.imageScaling = .scaleProportionallyUpOrDown
    v.addSubview(iv)
    v.addSubview(makeLabel(fc(w.tempF), size: 24, weight: .bold, frame: NSRect(x: 84, y: height - 40, width: width - 100, height: 30)))
    v.addSubview(makeLabel(desc, size: 13, color: .secondaryLabelColor, frame: NSRect(x: 84, y: height - 60, width: width - 100, height: 17)))
    v.addSubview(makeLabel("Feels like \(fc(w.feelsF)) • Humidity \(w.humidity)% • Wind \(compass(w.windDir)) \(mph(w.windMph))",
                           size: 11, color: .secondaryLabelColor, frame: NSRect(x: 84, y: 10, width: width - 100, height: 15)))
    return v
}

func todayCard(_ w: Weather, width: CGFloat) -> NSView {
    let height: CGFloat = 88
    let v = CardView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    let t = w.today
    let (_, desc) = symbol(for: t.code, isDay: true)
    v.addSubview(makeLabel("Hi \(fc(t.hiF))   Lo \(fc(t.loF))", size: 16, weight: .bold,
                           frame: NSRect(x: 16, y: height - 30, width: width - 32, height: 22)))
    v.addSubview(makeLabel(desc, size: 11, color: .secondaryLabelColor, frame: NSRect(x: 16, y: height - 48, width: width - 32, height: 15)))
    v.addSubview(makeLabel(todayDetail(w), size: 10.5, color: .secondaryLabelColor,
                           frame: NSRect(x: 16, y: 6, width: width - 32, height: 30), lines: 2))
    return v
}

func hourCard(_ h: Hour, width: CGFloat) -> NSView {
    let (sym, desc) = symbol(for: h.code, isDay: h.isDay)
    return card(width: width, height: 54, leading: hourFmt.string(from: h.time), icon: sym,
                headline: fc(h.tempF), subline: desc, detail: hourDetail(h))
}

func dayCard(_ d: Day, width: CGFloat) -> NSView {
    let (sym, desc) = symbol(for: d.code, isDay: true)
    return card(width: width, height: 54, leading: dayFmt.string(from: d.date), icon: sym,
                headline: "\(primary(d.hiF)) / \(primary(d.loF))", subline: "\(secondary(d.hiF)) / \(secondary(d.loF))",
                detail: dayDetail(d), detailLead: desc)
}

func headerLabel(_ title: String, width: CGFloat) -> NSView {
    let l = makeLabel(title.uppercased(), size: 11, weight: .semibold, color: .secondaryLabelColor,
                      frame: NSRect(x: 14, y: 0, width: width - 28, height: 16))
    let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 22)); v.addSubview(l); return v
}

/// Lays `views` out top-to-bottom in a column of `width`; returns the column view.
func column(_ views: [NSView], width: CGFloat) -> NSView {
    let gap: CGFloat = 4
    let total = views.reduce(0) { $0 + $1.frame.height + gap }
    let col = NSView(frame: NSRect(x: 0, y: 0, width: width, height: total))
    var y = total
    for v in views { y -= v.frame.height + gap; v.frame.origin = NSPoint(x: 0, y: y); col.addSubview(v) }
    return col
}

/// The whole dropdown body: left = Current + Next hours, right = Today + Next days.
func dashboardView(_ wx: Weather, colWidth: CGFloat) -> NSView {
    var left: [NSView] = [headerLabel("Current", width: colWidth), currentCard(wx, width: colWidth), headerLabel("Next hours", width: colWidth)]
    left += wx.hourly.prefix(Config.hours).map { hourCard($0, width: colWidth) }
    var right: [NSView] = [headerLabel("Today", width: colWidth), todayCard(wx, width: colWidth), headerLabel("Next days", width: colWidth)]
    right += wx.daily.prefix(Config.days).map { dayCard($0, width: colWidth) }
    let l = column(left, width: colWidth), r = column(right, width: colWidth)
    let h = max(l.frame.height, r.frame.height)
    let v = NSView(frame: NSRect(x: 0, y: 0, width: colWidth * 2, height: h))
    l.frame.origin = NSPoint(x: 0, y: h - l.frame.height)            // both columns top-aligned
    r.frame.origin = NSPoint(x: colWidth, y: h - r.frame.height)
    v.addSubview(l); v.addSubview(r)
    return v
}

func sectionHeader(_ title: String) -> NSMenuItem {
    if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
    let mi = NSMenuItem(title: title, action: nil, keyEquivalent: ""); mi.isEnabled = false
    mi.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    return mi
}

func viewItem(_ v: NSView) -> NSMenuItem { let mi = NSMenuItem(); mi.view = v; return mi }

/// Fill `menu` with the dropdown. `target` receives Refresh/Open/Quit actions (nil = static items only).
func populate(_ menu: NSMenu, place: Place, note: String?, weather last: Weather?, lastError: String?, target: AnyObject?) {
    menu.removeAllItems()
    let w = Config.menuWidth
    let titleText = place.name + (place.fromMac ? "  (this Mac's location)" : "")
    let title = NSMenuItem(title: titleText, action: nil, keyEquivalent: ""); title.isEnabled = false
    title.attributedTitle = NSAttributedString(string: titleText, attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
    menu.addItem(title)
    if let note = note {
        let n = NSMenuItem(title: note, action: nil, keyEquivalent: ""); n.isEnabled = false
        n.attributedTitle = NSAttributedString(string: note, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(n)
    }
    if let wx = last {
        menu.addItem(viewItem(dashboardView(wx, colWidth: w)))
        menu.addItem(.separator())
        let upd = NSMenuItem(title: "Updated \(clockFmt.string(from: wx.fetched))" + (lastError.map { " · last try failed: \($0)" } ?? ""),
                             action: nil, keyEquivalent: "")
        upd.isEnabled = false; menu.addItem(upd)
    } else {
        let mi = NSMenuItem(title: lastError.map { "Couldn't load weather: \($0)" } ?? "Loading…", action: nil, keyEquivalent: "")
        mi.isEnabled = false; menu.addItem(mi)
    }
    menu.addItem(.separator())
    menu.addItem(withTitle: "Refresh", action: #selector(AppDelegate.refresh), keyEquivalent: "r").target = target
    menu.addItem(withTitle: "Open Weather App", action: #selector(AppDelegate.openWeather), keyEquivalent: "o").target = target
    menu.addItem(.separator())
    if let d = target as? AppDelegate, let rel = d.availableUpdate {
        let mi = NSMenuItem(title: "Update to WeatherBar \(rel.version)…", action: #selector(AppDelegate.installAvailableUpdate), keyEquivalent: "")
        mi.target = target
        mi.image = symbolImage("arrow.down.circle.fill", size: 13)
        menu.addItem(mi)
    }
    menu.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdatesManually), keyEquivalent: "").target = target
    menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings), keyEquivalent: ",").target = target
    menu.addItem(withTitle: "About WeatherBar", action: #selector(AppDelegate.showAbout), keyEquivalent: "").target = target
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit WeatherBar", action: #selector(AppDelegate.quit), keyEquivalent: "q").target = target
}

// MARK: - Self-update from GitHub Releases

struct Release {
    let version: String          // "1.5" (tag "v1.5" without the v)
    let zipURL: URL
    let sha256URL: URL?
    let notes: String
}

enum UpdateError: LocalizedError {
    case http(Int), noRelease, badRelease(String), checksum, verify(String), install(String)
    var errorDescription: String? {
        switch self {
        case .http(404): return "no published release found (GitHub returned 404; the repo may still be private)"
        case .http(let c): return "GitHub returned HTTP \(c)"
        case .noRelease: return "no release information"
        case .badRelease(let s): return "the release is missing \(s)"
        case .checksum: return "the download's SHA-256 checksum did not match"
        case .verify(let s): return "the downloaded app failed verification: \(s)"
        case .install(let s): return s
        }
    }
}

/// true when `a` is a newer dotted version than `b` ("1.10" > "1.9").
func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
        if p != q { return p > q }
    }
    return false
}

func githubRequest(_ url: URL) -> URLRequest {
    var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
    r.setValue("WeatherBar/\(appVersion)", forHTTPHeaderField: "User-Agent")
    r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    return r
}

func fetchLatestRelease(completion: @escaping (Result<Release, Error>) -> Void) {
    guard let url = URL(string: Config.updateFeedURL) else { completion(.failure(UpdateError.noRelease)); return }
    URLSession.shared.dataTask(with: githubRequest(url)) { data, resp, err in
        if let err = err { completion(.failure(err)); return }
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { completion(.failure(UpdateError.http(h.statusCode))); return }
        guard let data = data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String else { completion(.failure(UpdateError.noRelease)); return }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = j["assets"] as? [[String: Any]] ?? []
        func asset(_ name: String) -> URL? {
            assets.first { ($0["name"] as? String) == name }
                .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
        }
        guard let zip = asset("WeatherBar-\(version).zip") else {
            completion(.failure(UpdateError.badRelease("WeatherBar-\(version).zip"))); return
        }
        completion(.success(Release(version: version, zipURL: zip, sha256URL: asset("WeatherBar-\(version).zip.sha256"),
                                    notes: (j["body"] as? String) ?? "")))
    }.resume()
}

func download(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
    URLSession.shared.downloadTask(with: githubRequest(url)) { tmp, resp, err in
        if let err = err { completion(.failure(err)); return }
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { completion(.failure(UpdateError.http(h.statusCode))); return }
        guard let tmp = tmp else { completion(.failure(UpdateError.noRelease)); return }
        // the system deletes `tmp` when this handler returns, so keep a copy we own
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        do { try FileManager.default.moveItem(at: tmp, to: keep); completion(.success(keep)) } catch { completion(.failure(error)) }
    }.resume()
}

@discardableResult
func runTool(_ tool: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return (p.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Downloads, checks and unpacks `rel` beside the app it will replace. Returns the staged .app.
func prepareUpdate(_ rel: Release, replacing appURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
    let fm = FileManager.default
    let folder = appURL.deletingLastPathComponent()
    guard fm.isWritableFile(atPath: folder.path) else {
        completion(.failure(UpdateError.install("WeatherBar can't replace itself in \(folder.path). Move it to /Applications first.")))
        return
    }
    download(rel.zipURL) { r in
        let zip: URL
        switch r { case .success(let z): zip = z; case .failure(let e): completion(.failure(e)); return }
        func unpack(expectedSHA: String?) {
            // Clean up BEFORE calling completion: a caller may exit the process inside it.
            var stage: URL?
            func done(_ r: Result<URL, Error>) {
                try? fm.removeItem(at: zip)
                if case .failure = r, let dir = stage { try? fm.removeItem(at: dir) }   // drop a rejected download
                completion(r)
            }
            do {
                if let want = expectedSHA {
                    let got = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
                    guard got == want.lowercased() else { throw UpdateError.checksum }
                }
                // same volume as the app, so the final swap is a rename
                let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
                stage = dir
                let (code, out) = runTool("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
                guard code == 0 else { throw UpdateError.install("unzip failed: \(out)") }
                let newApp = dir.appendingPathComponent("WeatherBar.app")
                guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) else {
                    throw UpdateError.verify("no Info.plist")
                }
                guard info["CFBundleIdentifier"] as? String == (Bundle.main.bundleIdentifier ?? "com.mayhoo.weatherbar") else {
                    throw UpdateError.verify("wrong bundle identifier")
                }
                guard info["CFBundleShortVersionString"] as? String == rel.version else { throw UpdateError.verify("version mismatch") }
                let (vc, vout) = runTool("/usr/bin/codesign", ["--verify", "--strict", newApp.path])
                guard vc == 0 else { throw UpdateError.verify("signature check: \(vout)") }
                done(.success(newApp))
            } catch {
                done(.failure(error))
            }
        }
        guard let shaURL = rel.sha256URL else { unpack(expectedSHA: nil); return }
        URLSession.shared.dataTask(with: githubRequest(shaURL)) { d, _, _ in
            // `shasum -a 256` output: "<64 hex>  <file name>"
            let hex = d.flatMap { String(data: $0, encoding: .utf8) }?
                .split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)
            guard let hex = hex, hex.count == 64 else {
                try? fm.removeItem(at: zip)
                completion(.failure(UpdateError.badRelease("a valid .sha256 file"))); return
            }
            unpack(expectedSHA: hex)
        }.resume()
    }
}

/// Starts a small shell script that waits for this process to exit, swaps the bundles (putting the old one
/// back if the swap fails) and relaunches. Paths go in as arguments, never pasted into the script text.
func installAndRelaunch(staged newApp: URL, replacing appURL: URL, quit: () -> Void = { NSApp.terminate(nil) }) throws {
    let script = """
    pid="$1"; old="$2"; new="$3"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    rm -rf "$old.previous"
    if mv "$old" "$old.previous" && mv "$new" "$old"; then
      rm -rf "$old.previous"
    elif [ -d "$old.previous" ] && [ ! -d "$old" ]; then
      mv "$old.previous" "$old"
    fi
    rm -rf "$(dirname "$new")"
    xattr -dr com.apple.quarantine "$old" 2>/dev/null
    open "$old"
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", script, "weatherbar-update", String(ProcessInfo.processInfo.processIdentifier), appURL.path, newApp.path]
    try p.run()
    quit()
}

// MARK: - Settings + About windows

final class SettingsWindow: NSWindowController {
    var onSave: (() -> Void)?
    let useMac = NSButton(radioButtonWithTitle: "Use this Mac's location", target: nil, action: nil)
    let useFixed = NSButton(radioButtonWithTitle: "Always use the fixed place below", target: nil, action: nil)
    let search = NSSearchField()
    let searchBtn = NSButton(title: "Find", target: nil, action: nil)
    let results = NSPopUpButton()
    let placeField = NSTextField(), latField = NSTextField(), lonField = NSTextField()
    let hoursField = NSTextField(), daysField = NSTextField()
    let loginBox = NSButton(checkboxWithTitle: "Start WeatherBar at login", target: nil, action: nil)
    let celsiusBox = NSButton(checkboxWithTitle: "Celsius first (°C / °F; menu bar Hi/Lo in °C)", target: nil, action: nil)
    let checkUpdatesBox = NSButton(checkboxWithTitle: "Check for updates daily", target: nil, action: nil)
    let autoInstallBox = NSButton(checkboxWithTitle: "Install updates without asking", target: nil, action: nil)
    let status = NSTextField(labelWithString: "")
    var found: [GeoResult] = []

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 390), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "WeatherBar Settings"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    func build() {
        guard let content = window?.contentView else { return }
        func lbl(_ t: String) -> NSTextField { let l = NSTextField(labelWithString: t); l.alignment = .right; return l }
        for b in [useMac, useFixed] { b.target = self; b.action = #selector(modeChanged) }
        searchBtn.target = self; searchBtn.action = #selector(doSearch); searchBtn.bezelStyle = .rounded
        search.placeholderString = "City, State  (e.g. Novi, MI)"; search.target = self; search.action = #selector(doSearch)
        results.target = self; results.action = #selector(pickResult); results.isHidden = true
        for f in [placeField, latField, lonField, hoursField, daysField] { f.font = NSFont.systemFont(ofSize: 12) }
        loginBox.target = self; loginBox.action = #selector(loginToggled)
        status.font = NSFont.systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byWordWrapping; status.maximumNumberOfLines = 2

        let searchRow = NSStackView(views: [search, searchBtn]); searchRow.spacing = 6
        let coordRow = NSStackView(views: [lbl("Lat"), latField, lbl("Lon"), lonField]); coordRow.spacing = 6
        let countRow = NSStackView(views: [hoursField, lbl("hourly cards"), daysField, lbl("daily cards")]); countRow.spacing = 6
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(save)); save.keyEquivalent = "\r"
        let btnRow = NSStackView(views: [NSView(), cancel, save]); btnRow.spacing = 8

        let grid = NSGridView(views: [
            [lbl("Location"), useMac],
            [NSView(), useFixed],
            [lbl("Find place"), searchRow],
            [NSView(), results],
            [lbl("Place name"), placeField],
            [lbl("Coordinates"), coordRow],
            [lbl("Dropdown"), countRow],
            [lbl("Units"), celsiusBox],
            [lbl("Login"), loginBox],
            [lbl("Updates"), checkUpdatesBox],
            [NSView(), autoInstallBox],
            [NSView(), status],
            [NSView(), btnRow],
        ])
        grid.rowSpacing = 8; grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 80
        grid.column(at: 1).width = 330
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            latField.widthAnchor.constraint(equalToConstant: 90), lonField.widthAnchor.constraint(equalToConstant: 90),
            hoursField.widthAnchor.constraint(equalToConstant: 40), daysField.widthAnchor.constraint(equalToConstant: 40),
            searchBtn.widthAnchor.constraint(equalToConstant: 60),
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            results.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    func load(status text: String) {
        (Config.useLocation ? useMac : useFixed).state = .on
        placeField.stringValue = Config.place
        latField.stringValue = String(format: "%.4f", Config.lat)
        lonField.stringValue = String(format: "%.4f", Config.lon)
        hoursField.stringValue = "\(Config.hours)"; daysField.stringValue = "\(Config.days)"
        loginBox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        celsiusBox.state = Config.celsiusFirst ? .on : .off
        checkUpdatesBox.state = Config.autoCheckUpdates ? .on : .off
        autoInstallBox.state = Config.autoInstallUpdates ? .on : .off
        status.stringValue = text
        results.isHidden = true
    }

    @objc func modeChanged() {}
    @objc func doSearch() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        status.stringValue = "Searching…"
        geocode(q) { [weak self] r in DispatchQueue.main.async {
            guard let self = self else { return }
            self.found = r
            self.results.removeAllItems()
            if r.isEmpty { self.status.stringValue = "No match for “\(q)”"; self.results.isHidden = true; return }
            self.results.addItems(withTitles: r.map { $0.name })
            self.results.isHidden = false
            self.status.stringValue = "\(r.count) match\(r.count == 1 ? "" : "es") — pick one"
            self.pickResult()
        } }
    }
    @objc func pickResult() {
        let i = results.indexOfSelectedItem
        guard i >= 0, i < found.count else { return }
        let g = found[i]
        // "Novi, Michigan, US" → keep "Novi, Michigan" for the display name
        placeField.stringValue = g.name.split(separator: ",").prefix(2).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
        latField.stringValue = String(format: "%.4f", g.lat); lonField.stringValue = String(format: "%.4f", g.lon)
        useFixed.state = .on; useMac.state = .off
    }
    @objc func loginToggled() {
        do {
            if loginBox.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            status.stringValue = loginBox.state == .on ? "Will start at login." : "Won't start at login."
        } catch {
            status.stringValue = "Login item: \(error.localizedDescription)"
            loginBox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }
    @objc func cancel() { window?.close() }
    @objc func save() {
        let d = UserDefaults.standard
        d.set(useMac.state == .on, forKey: "useLocation")
        let name = placeField.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { d.set(name, forKey: "place") }
        if let la = Double(latField.stringValue), let lo = Double(lonField.stringValue), abs(la) <= 90, abs(lo) <= 180 {
            d.set(la, forKey: "latitude"); d.set(lo, forKey: "longitude")
        }
        if let h = Int(hoursField.stringValue), h > 0, h <= 48 { d.set(h, forKey: "hours") }
        if let n = Int(daysField.stringValue), n > 0, n <= 14 { d.set(n, forKey: "days") }
        d.set(celsiusBox.state == .on, forKey: "celsiusFirst")
        d.set(checkUpdatesBox.state == .on, forKey: "autoCheckUpdates")
        d.set(autoInstallBox.state == .on, forKey: "autoInstallUpdates")
        window?.close()
        onSave?()
    }
}

final class AboutWindow: NSWindowController {
    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 270), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "About WeatherBar"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        guard let c = win.contentView else { return }
        let iv = NSImageView(); iv.imageScaling = .scaleProportionallyUpOrDown
        iv.image = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) } ?? NSApp.applicationIconImage
        iv.translatesAutoresizingMaskIntoConstraints = false
        func l(_ t: String, _ size: CGFloat, _ w: NSFont.Weight = .regular, _ color: NSColor = .labelColor) -> NSTextField {
            let f = NSTextField(labelWithString: t); f.font = NSFont.systemFont(ofSize: size, weight: w); f.textColor = color; f.alignment = .center; return f
        }
        let stack = NSStackView(views: [iv, l("WeatherBar", 18, .bold), l("Version \(appVersion) · built \(buildDate)", 12, .regular, .secondaryLabelColor),
                                        l("Duane May", 14, .medium),
                                        l("Weather data by Open-Meteo.com", 11, .regular, .secondaryLabelColor),
                                        l("Icons: Apple SF Symbols", 11, .regular, .secondaryLabelColor)])
        stack.orientation = .vertical; stack.spacing = 6; stack.alignment = .centerX
        stack.setCustomSpacing(14, after: iv)
        stack.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(stack)
        NSLayoutConstraint.activate([
            iv.widthAnchor.constraint(equalToConstant: 96), iv.heightAnchor.constraint(equalToConstant: 96),
            stack.centerXAnchor.constraint(equalTo: c.centerXAnchor),
            stack.topAnchor.constraint(equalTo: c.topAnchor, constant: 22),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

func renderWindow(_ win: NSWindow?, to path: String) {
    guard let win = win, let inner = win.contentView else { print("no view"); exit(1) }
    // Wrap in an opaque window-coloured view so the PNG looks like the real window, not transparent.
    let v = NSView(frame: inner.bounds); v.wantsLayer = true
    v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    inner.removeFromSuperview(); inner.frame = v.bounds; v.addSubview(inner); win.contentView = v
    v.layoutSubtreeIfNeeded()
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { print("no bitmap"); exit(1) }
    v.cacheDisplay(in: v.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(Int(v.bounds.width))x\(Int(v.bounds.height)))")
}

// MARK: - Test modes

if let i = CommandLine.arguments.firstIndex(of: "--once"), i > 0 {
    let sem = DispatchSemaphore(value: 0)
    fetchWeather(fixedPlace) { result in
        switch result {
        case .success(let w):
            let (sym, desc) = symbol(for: w.code, isDay: w.isDay)
            print("\(Config.place): \(desc) [\(sym)]  bar: \(primary(w.tempF)) H \(primaryDeg(w.today.hiF)) / \(secondary(w.tempF)) L \(primaryDeg(w.today.loF))")
            print("Current: \(fc(w.tempF)), feels \(fc(w.feelsF)) • \(todayDetail(w))")
            print("Next hours:"); for h in w.hourly.prefix(Config.hours) { print("  \(hourFmt.string(from: h.time))  \(fc(h.tempF))  \(symbol(for: h.code, isDay: h.isDay).1)  \(hourDetail(h))") }
            print("Next days:");  for d in w.daily.prefix(Config.days) { print("  \(dayFmt.string(from: d.date))  \(fc(d.hiF)) / \(fc(d.loF))  \(symbol(for: d.code, isDay: true).1)  \(dayDetail(d))") }
        case .failure(let e): print("ERROR: \(e.localizedDescription)")
        }
        sem.signal()
    }
    sem.wait(); exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    // Draw every dropdown card into one tall PNG so the layout can be checked without a screen.
    let out = CommandLine.arguments[i + 1]
    let sem = DispatchSemaphore(value: 0)
    var fetched: Weather?
    fetchWeather(fixedPlace) { r in if case .success(let w) = r { fetched = w }; sem.signal() }
    sem.wait()
    guard let wx = fetched else { print("fetch failed"); exit(1) }
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: CommandLine.arguments.contains("--light") ? .aqua : .darkAqua)
    let container = dashboardView(wx, colWidth: Config.menuWidth)
    let w = container.frame.width, total = container.frame.height
    let bg = NSView(frame: container.frame); bg.wantsLayer = true
    bg.layer?.backgroundColor = (CommandLine.arguments.contains("--light") ? NSColor.white : NSColor(white: 0.13, alpha: 1)).cgColor
    bg.addSubview(container)
    let win = NSWindow(contentRect: bg.frame, styleMask: .borderless, backing: .buffered, defer: false)
    win.contentView = bg
    guard let rep = bg.bitmapImageRepForCachingDisplay(in: bg.bounds) else { print("no bitmap"); exit(1) }
    bg.cacheDisplay(in: bg.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { print("no png"); exit(1) }
    try? png.write(to: URL(fileURLWithPath: out))
    print("wrote \(out) (\(Int(w))x\(Int(total)))")
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--geocode"), i + 1 < CommandLine.arguments.count {
    let sem = DispatchSemaphore(value: 0)
    geocode(CommandLine.arguments[i + 1]) { r in r.forEach { print("\($0.name)  \($0.lat), \($0.lon)") }; if r.isEmpty { print("no results") }; sem.signal() }
    sem.wait(); exit(0)
}
for (flag, make) in [("--render-settings", { () -> NSWindow? in let s = SettingsWindow(); s.load(status: "Using this Mac's location: Novi, MI"); return s.window }),
                     ("--render-about", { () -> NSWindow? in AboutWindow().window })] {
    if let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: CommandLine.arguments.contains("--light") ? .aqua : .darkAqua)
        renderWindow(make(), to: CommandLine.arguments[i + 1]); exit(0)
    }
}

if CommandLine.arguments.contains("--apply-update") {
    // Headless test of the real update path: fetch, download, verify, stage, swap after this process exits.
    let sem = DispatchSemaphore(value: 0)
    fetchLatestRelease { r in
        guard case .success(let rel) = r else { if case .failure(let e) = r { print("ERROR: \(e.localizedDescription)") }; exit(1) }
        guard isNewer(rel.version, than: appVersion) else { print("already at \(appVersion); latest is \(rel.version)"); exit(0) }
        print("updating \(appVersion) -> \(rel.version)")
        prepareUpdate(rel, replacing: Bundle.main.bundleURL) { r in
            switch r {
            case .success(let staged):
                print("verified and staged: \(staged.path)")
                do { try installAndRelaunch(staged: staged, replacing: Bundle.main.bundleURL, quit: { exit(0) }) }
                catch { print("ERROR: \(error.localizedDescription)"); exit(1) }
            case .failure(let e): print("ERROR: \(e.localizedDescription)"); exit(1)
            }
            sem.signal()
        }
    }
    sem.wait(); exit(0)
}

if CommandLine.arguments.contains("--check-update") {
    let sem = DispatchSemaphore(value: 0)
    print("installed: \(appVersion)   feed: \(Config.updateFeedURL)")
    fetchLatestRelease { r in
        switch r {
        case .success(let rel):
            print("latest:    \(rel.version)   newer than installed: \(isNewer(rel.version, than: appVersion))")
            print("zip:       \(rel.zipURL)")
            print("sha256:    \(rel.sha256URL?.absoluteString ?? "none")")
        case .failure(let e): print("ERROR: \(e.localizedDescription)")
        }
        sem.signal()
    }
    sem.wait(); exit(0)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?
    var last: Weather?
    var lastError: String?
    var place: Place = fixedPlace
    var locationNote: String?
    let locator = LocationResolver()
    lazy var settings = SettingsWindow()
    lazy var about = AboutWindow()
    var availableUpdate: Release?
    var updateTimer: Timer?
    var installing = false

    func applicationDidFinishLaunching(_ note: Notification) {
        menu.delegate = self
        item.menu = menu
        setBar(icon: "ellipsis.circle", big: "…", col1: ("", ""), col2: ("", ""))
        locator.onResolved = { [weak self] p in DispatchQueue.main.async {
            guard let self = self, Config.useLocation else { return }
            let moved = abs(p.lat - self.place.lat) > 0.01 || abs(p.lon - self.place.lon) > 0.01 || !self.place.fromMac
            self.place = p; self.locationNote = nil
            if moved { self.refresh() }
        } }
        locator.onFailed = { [weak self] why in DispatchQueue.main.async {
            guard let self = self, Config.useLocation else { return }
            self.place = fixedPlace
            self.locationNote = "Mac location unavailable (\(why)) — using \(fixedPlace.name)"
            self.refresh()
        } }
        applySettings()
        timer = Timer.scheduledTimer(withTimeInterval: Config.refreshMinutes * 60, repeats: true) { [weak self] _ in self?.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        offerMoveToApplications()
        // first update check shortly after launch, then once a day
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkForUpdates(userInitiated: false) }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdates(userInitiated: false)
        }
    }

    // MARK: Move to Applications

    /// Offers to move the app into /Applications when it runs from anywhere else. Self-update and the
    /// login item both want a stable, writable home.
    func offerMoveToApplications() {
        let src = Bundle.main.bundleURL
        guard !src.path.hasPrefix("/Applications/"), !UserDefaults.standard.bool(forKey: "skipMovePrompt") else { return }
        let dest = URL(fileURLWithPath: "/Applications/WeatherBar.app")
        let alert = NSAlert()
        alert.messageText = "Move WeatherBar to the Applications folder?"
        alert.informativeText = "It is running from \(src.deletingLastPathComponent().path). In /Applications it can update itself and start at login reliably."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: "skipMovePrompt") }
        guard answer == .alertFirstButtonReturn else { return }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            do { try fm.moveItem(at: src, to: dest) } catch { try fm.copyItem(at: src, to: dest) }
            NSWorkspace.shared.openApplication(at: dest, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } catch {
            inform("Couldn't move WeatherBar", error.localizedDescription)
        }
    }

    // MARK: Updates

    @objc func checkForUpdatesManually() { checkForUpdates(userInitiated: true) }

    func checkForUpdates(userInitiated: Bool) {
        guard userInitiated || Config.autoCheckUpdates, !installing else { return }
        fetchLatestRelease { [weak self] r in DispatchQueue.main.async {
            guard let self = self else { return }
            switch r {
            case .success(let rel) where isNewer(rel.version, than: appVersion):
                self.availableUpdate = rel
                if userInitiated { self.offerUpdate(rel); return }
                if Config.skippedVersion == rel.version { return }
                if Config.autoInstallUpdates { self.install(rel) } else { self.offerUpdate(rel) }
            case .success:
                self.availableUpdate = nil
                if userInitiated { self.inform("WeatherBar is up to date", "Version \(appVersion) is the latest release.") }
            case .failure(let e):
                if userInitiated { self.inform("Couldn't check for updates", e.localizedDescription) }
            }
        } }
    }

    func offerUpdate(_ rel: Release) {
        let a = NSAlert()
        a.messageText = "WeatherBar \(rel.version) is available"
        let notes = rel.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        a.informativeText = "You have \(appVersion)." + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(600)))
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Later")
        a.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: install(rel)
        case .alertThirdButtonReturn: UserDefaults.standard.set(rel.version, forKey: "skippedVersion")
        default: break
        }
    }

    @objc func installAvailableUpdate() { if let rel = availableUpdate { install(rel) } }

    func install(_ rel: Release) {
        guard !installing else { return }
        installing = true
        let appURL = Bundle.main.bundleURL
        setBar(icon: "arrow.down.circle", big: "", col1: ("Updating", "…"), col2: ("", ""))
        prepareUpdate(rel, replacing: appURL) { [weak self] r in DispatchQueue.main.async {
            guard let self = self else { return }
            switch r {
            case .success(let staged):
                do { try installAndRelaunch(staged: staged, replacing: appURL) } catch {
                    self.installing = false; self.refresh()
                    self.inform("Update failed", error.localizedDescription)
                }
            case .failure(let e):
                self.installing = false; self.refresh()
                self.inform("Update to \(rel.version) failed",
                            e.localizedDescription + "\n\nYou can download it from the Releases page on GitHub instead.")
            }
        } }
    }

    func inform(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }

    /// Menu bar layout:  [icon] 49°F  H 66°     (optionally a large current temp before the columns)
    ///                          10°C  L 47°
    /// Drawn into a template image so it adapts to light/dark menu bars.
    func setBar(icon name: String, big: String, col1: (String, String), col2: (String, String)) {
        let barH: CGFloat = 22
        let small = Config.fontSize
        let bigFont = NSFont.monospacedDigitSystemFont(ofSize: Config.bigFontSize, weight: .medium)
        let smallFont = NSFont.monospacedDigitSystemFont(ofSize: small, weight: .medium)
        let bigAttr = NSAttributedString(string: big, attributes: [.font: bigFont, .foregroundColor: NSColor.black])
        func sm(_ t: String) -> NSAttributedString { NSAttributedString(string: t, attributes: [.font: smallFont, .foregroundColor: NSColor.black]) }
        let c1 = (sm(col1.0), sm(col1.1)), c2 = (sm(col2.0), sm(col2.1))
        let iconSize: CGFloat = 17
        let symImg = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular))
        let iconW: CGFloat = symImg.map { $0.size.width * iconSize / max($0.size.height, 1) } ?? iconSize
        let gap: CGFloat = 5
        let w1 = max(c1.0.size().width, c1.1.size().width)
        let w2 = max(c2.0.size().width, c2.1.size().width)
        let bigW = big.isEmpty ? 0 : bigAttr.size().width + gap
        let totalW = ceil(2 + iconW + gap + bigW + w1 + gap + w2 + 2)
        let lineH = small + 2
        let img = NSImage(size: NSSize(width: totalW, height: barH), flipped: false) { _ in
            var x: CGFloat = 2
            if let symImg = symImg {
                symImg.draw(in: NSRect(x: x, y: (barH - iconSize) / 2, width: iconW, height: iconSize), from: .zero, operation: .sourceOver, fraction: 1)
            }
            x += iconW + gap
            if !big.isEmpty { bigAttr.draw(at: NSPoint(x: x, y: (barH - bigAttr.size().height) / 2)); x += bigW }
            let topY = barH / 2 + 0.5, botY = barH / 2 - lineH + 0.5
            c1.0.draw(at: NSPoint(x: x, y: topY)); c1.1.draw(at: NSPoint(x: x, y: botY))
            x += w1 + gap
            c2.0.draw(at: NSPoint(x: x, y: topY)); c2.1.draw(at: NSPoint(x: x, y: botY))
            return true
        }
        img.isTemplate = true
        item.button?.image = img
        item.button?.imagePosition = .imageOnly
        item.button?.title = ""
    }

    /// Re-resolve the place from settings, then fetch. Called at launch and after Save in Settings.
    func applySettings() {
        if Config.useLocation {
            if !place.fromMac { place = fixedPlace }   // show something immediately; Mac location replaces it when it arrives
            locationNote = place.fromMac ? nil : "Finding this Mac's location…"
            locator.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self = self, Config.useLocation, !self.place.fromMac else { return }
                self.locationNote = "Mac location not available (no answer from Location Services) — using \(fixedPlace.name)"
            }
        } else {
            place = fixedPlace; locationNote = nil
        }
        refresh()
    }

    @objc func refresh() {
        let p = place
        fetchWeather(p) { [weak self] result in DispatchQueue.main.async { self?.apply(result) } }
    }

    @objc func showSettings() {
        settings.onSave = { [weak self] in self?.applySettings() }
        settings.load(status: locationNote ?? (place.fromMac ? "Using this Mac's location: \(place.name)" : "Using fixed place: \(place.name)"))
        settings.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        settings.showWindow(nil); settings.window?.makeKeyAndOrderFront(nil)
    }
    @objc func showAbout() {
        about.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        about.showWindow(nil); about.window?.makeKeyAndOrderFront(nil)
    }

    func apply(_ result: Result<Weather, Error>) {
        switch result {
        case .success(let w):
            last = w; lastError = nil
            let (sym, desc) = symbol(for: w.code, isDay: w.isDay)
            setBar(icon: sym, big: Config.bigTemp ? primaryDeg(w.tempF) : "",
                   col1: (primary(w.tempF), secondary(w.tempF)),
                   col2: ("H \(primaryDeg(w.today.hiF))", "L \(primaryDeg(w.today.loF))"))
            item.button?.toolTip = "\(place.name): \(desc)"
        case .failure(let e):
            lastError = e.localizedDescription
            if last == nil { setBar(icon: "exclamationmark.triangle", big: "—", col1: ("", ""), col2: ("", "")) }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu, place: place, note: locationNote, weather: last, lastError: lastError, target: self) }

    @objc func openWeather() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Weather.app"),
                                           configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
