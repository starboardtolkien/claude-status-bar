import Foundation

// Plan usage limits from the same endpoint Claude Code's /usage reads, authed with Claude Code's
// own OAuth token. Read-only: we never refresh the token (Claude Code owns that), we just re-read it.
struct UsageWindow {
    var percent: Double   // 0–100
    var resetsAt: Date?
}

struct UsageSnapshot {
    var fiveHour: UsageWindow?
    var sevenDay: UsageWindow?
    var sevenDayFable: UsageWindow?
    var creditsReported = false  // false when the response carries no extra_usage block
    var creditsEnabled = false
    var creditsUsed: Double?    // dollars
    var creditsLimit: Double?   // dollars
    var fetchedAt = Date()
}

final class UsageMonitor {
    private(set) var snapshot: UsageSnapshot?
    private(set) var lastError: String?
    var onUpdate: (() -> Void)?

    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let interval: TimeInterval = 60
    private var timer: Timer?
    private var inFlight = false
    private var backoffUntil = Date.distantPast
    private var backoff: TimeInterval = 0   // grows on repeated 429s, resets on success

    var isRunning: Bool { timer != nil }

    // Last good response, so a relaunch or a failed poll shows the previous numbers, not an error.
    private let cachePath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar/usage-cache.json")

    init() {
        if let d = FileManager.default.contents(atPath: cachePath), var snap = UsageMonitor.parse(d) {
            snap.fetchedAt = (try? FileManager.default.attributesOfItem(atPath: cachePath)[.modificationDate] as? Date) ?? .distantPast
            snapshot = snap
        }
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // A relaunch inside the poll interval reuses the cached numbers instead of spending a request.
        if snapshot.map({ Date().timeIntervalSince($0.fetchedAt) >= interval }) ?? true { refresh() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    func refresh(force: Bool = false) {
        if inFlight || (!force && Date() < backoffUntil) { return }
        inFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let token = UsageMonitor.readToken() else {
                DispatchQueue.main.async {
                    self?.inFlight = false
                    self?.lastError = "Not signed in to Claude Code"
                    NSLog("usage: no token")
                    self?.onUpdate?()
                }
                return
            }
            self?.request(token: token)
        }
    }

    private func request(token: String) {
        var req = URLRequest(url: endpoint, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("claude-status-bar", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async { self?.handle(data: data, resp: resp as? HTTPURLResponse, err: err) }
        }.resume()
    }

    private func handle(data: Data?, resp: HTTPURLResponse?, err: Error?) {
        inFlight = false
        defer { onUpdate?() }
        if let err = err { lastError = err.localizedDescription; NSLog("usage: %@", err.localizedDescription); return }
        guard let resp = resp else { lastError = "No response"; return }
        if resp.statusCode != 200 { NSLog("usage: HTTP %d", resp.statusCode) }
        switch resp.statusCode {
        case 200:
            guard let data = data, let snap = UsageMonitor.parse(data) else { lastError = "Unreadable response"; return }
            snapshot = snap
            lastError = nil
            backoff = 0
            try? data.write(to: URL(fileURLWithPath: cachePath), options: .atomic)
        case 401, 403:
            lastError = "Claude Code login expired"   // Claude Code refreshes it on its next run
        case 429:
            backoff = min(max(backoff * 2, 120), 900)
            let retry = (resp.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init) ?? backoff
            backoffUntil = Date().addingTimeInterval(max(retry, interval))
            NSLog("usage: rate limited, retrying in %.0fs", max(retry, interval))
            lastError = "Rate limited"
        default:
            lastError = "HTTP \(resp.statusCode)"
        }
    }

    static func parse(_ data: Data) -> UsageSnapshot? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var s = UsageSnapshot()
        s.fiveHour = window(o["five_hour"])
        s.sevenDay = window(o["seven_day"])
        // Model-specific weekly windows are keyed seven_day_<model>; match any key naming Fable.
        if let key = o.keys.sorted().first(where: { $0.hasPrefix("seven_day") && $0.lowercased().contains("fable") }) {
            s.sevenDayFable = window(o[key])
        }
        // Newer responses null the seven_day_<model> fields and list scoped weekly limits instead.
        for l in (o["limits"] as? [[String: Any]]) ?? [] where (l["kind"] as? String) == "weekly_scoped" {
            let model = (l["scope"] as? [String: Any])?["model"] as? [String: Any]
            let name = ((model?["id"] as? String ?? "") + " " + (model?["display_name"] as? String ?? "")).lowercased()
            guard name.contains("fable") || name.contains("mythos"), let pct = number(l["percent"]) else { continue }
            s.sevenDayFable = UsageWindow(percent: pct, resetsAt: (l["resets_at"] as? String).flatMap(parseDate))
        }
        if let x = o["extra_usage"] as? [String: Any] {
            s.creditsReported = true
            s.creditsEnabled = x["is_enabled"] as? Bool ?? false
            // The API reports credits in cents.
            s.creditsUsed = number(x["used_credits"]).map { $0 / 100 }
            s.creditsLimit = number(x["monthly_limit"] ?? x["monthly_credit_limit"]).map { $0 / 100 }
        }
        return s
    }

    private static func window(_ v: Any?) -> UsageWindow? {
        guard let w = v as? [String: Any], let u = number(w["utilization"]) else { return nil }
        return UsageWindow(percent: u, resetsAt: (w["resets_at"] as? String).flatMap(parseDate))
    }

    // Utilization arrives as a number or occasionally a string like "23%".
    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let str = v as? String { return Double(str.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // Claude Code stores credentials in the login keychain on macOS; older installs use a file.
    // Going through /usr/bin/security avoids a keychain prompt on every rebuild of this ad-hoc signed app.
    static func readToken() -> String? {
        if let json = runSecurity(), let t = accessToken(from: json) { return t }
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/.credentials.json")
        if let d = FileManager.default.contents(atPath: path), let t = accessToken(from: d) { return t }
        return nil
    }

    private static func runSecurity() -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-a", NSUserName(), "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // `security` can hang on some macOS releases; don't let it wedge the poll.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    private static func accessToken(from data: Data) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = o["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["accessToken"] as? String
    }
}
