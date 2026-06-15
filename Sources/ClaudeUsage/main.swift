import AppKit
import Foundation

// MARK: - Configuration

private let claudeUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
private let claudeKeychainService = "Claude Code-credentials"
private let codexSessionsDir = ("~/.codex/sessions" as NSString).expandingTildeInPath
private let pollInterval: TimeInterval = 300 // seconds

// MARK: - Claude API models

struct Window: Decodable {
    let utilization: Double?
    let resets_at: String?
}

struct ExtraUsage: Decodable {
    let is_enabled: Bool?
    let monthly_limit: Double?
    let used_credits: Double?
    let currency: String?
}

struct ClaudeUsageResponse: Decodable {
    let five_hour: Window?
    let seven_day: Window?
    let extra_usage: ExtraUsage?
}

// MARK: - Codex models (parsed from session .jsonl rate_limits snapshots)

struct CodexWindow: Decodable {
    let used_percent: Double?
    let window_minutes: Int?
    let resets_at: Double?
}

struct CodexRateLimits: Decodable {
    let primary: CodexWindow?
    let secondary: CodexWindow?
    let plan_type: String?
}

private struct CodexLine: Decodable {
    struct Payload: Decodable { let rate_limits: CodexRateLimits? }
    let timestamp: String?
    let payload: Payload?
}

/// What the latest Codex session log told us, plus how old it is.
struct CodexSnapshot {
    let limits: CodexRateLimits
    let asOf: Date?
}

// MARK: - Claude token (Keychain)

/// Reads the OAuth access token Claude Code stores in the login keychain.
/// Re-read on every poll so we always pick up the token Claude Code keeps
/// refreshed — we never run the OAuth refresh flow ourselves.
func readClaudeToken() -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    proc.arguments = ["find-generic-password", "-s", claudeKeychainService, "-w"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
        try proc.run()
        proc.waitUntilExit()
    } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let raw = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        let jsonData = raw.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
    else { return nil }
    let oauth = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
    return oauth["accessToken"] as? String
}

// MARK: - Codex usage (newest session file, no network)

func readCodexSnapshot() -> CodexSnapshot? {
    let fm = FileManager.default
    guard let url = URL(string: "file://" + codexSessionsDir),
          let walker = fm.enumerator(at: url,
                                     includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
    else { return nil }

    var newest: (URL, Date)?
    for case let f as URL in walker where f.pathExtension == "jsonl" {
        let vals = try? f.resourceValues(forKeys: [.contentModificationDateKey])
        guard let m = vals?.contentModificationDate else { continue }
        if newest == nil || m > newest!.1 { newest = (f, m) }
    }
    guard let (file, _) = newest,
          let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }

    // Scan from the end for the most recent line carrying a rate_limits block.
    let decoder = JSONDecoder()
    for line in text.split(separator: "\n").reversed() {
        guard line.contains("rate_limits"),
              let data = line.data(using: .utf8),
              let parsed = try? decoder.decode(CodexLine.self, from: data),
              let limits = parsed.payload?.rate_limits else { continue }
        let asOf = parsed.timestamp.flatMap { ISO8601DateFormatter.codex.date(from: $0) }
        return CodexSnapshot(limits: limits, asOf: asOf)
    }
    return nil
}

// MARK: - Formatting helpers

extension ISO8601DateFormatter {
    static let codex: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

func formatResetISO(_ iso: String?) -> String {
    guard let iso else { return "—" }
    let p = ISO8601DateFormatter()
    p.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = p.date(from: iso)
    if date == nil { p.formatOptions = [.withInternetDateTime]; date = p.date(from: iso) }
    return date.map(formatDate) ?? "—"
}

func formatResetEpoch(_ epoch: Double?) -> String {
    guard let epoch else { return "—" }
    return formatDate(Date(timeIntervalSince1970: epoch))
}

func formatDate(_ date: Date) -> String {
    let out = DateFormatter()
    out.dateFormat = "EEE h:mm a"
    return out.string(from: date)
}

func relativeAge(_ date: Date?) -> String {
    guard let date else { return "unknown" }
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86_400 { return "\(s / 3600)h ago" }
    return "\(s / 86_400)d ago"
}

func bar(_ pct: Double) -> String {
    let filled = max(0, min(10, Int((pct / 100.0 * 10).rounded())))
    return String(repeating: "█", count: filled) + String(repeating: "░", count: 10 - filled)
}

func pct(_ v: Double?) -> Int { Int((v ?? 0).rounded()) }

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?

    private var claude: ClaudeUsageResponse?      // last good reading (kept across transient errors)
    private var claudeUpdatedAt: Date?            // when that reading arrived
    private var claudeNote: String?               // transient status (rate limited / error)
    private var claudeBackoffUntil: Date?         // skip Claude network calls until this time
    private var codex: CodexSnapshot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "CL … · CX …"
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc func refresh() {
        // Codex: local file read, cheap, synchronous.
        codex = readCodexSnapshot()

        // Claude: network. Skip while backing off from a 429 so we don't keep
        // the rate limit tripped — but a manual "Refresh now" clears the backoff.
        if let until = claudeBackoffUntil, until > Date() {
            DispatchQueue.main.async { self.render() }
            return
        }

        guard let token = readClaudeToken() else {
            claudeNote = "No Claude token in Keychain (sign in with Claude Code)."
            DispatchQueue.main.async { self.render() }
            return
        }
        var req = URLRequest(url: claudeUsageURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let error {
                self.claudeNote = error.localizedDescription // keep last good reading
            } else if code == 200, let data,
                      let usage = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data) {
                self.claude = usage
                self.claudeUpdatedAt = Date()
                self.claudeNote = nil
                self.claudeBackoffUntil = nil
            } else if code == 429 {
                let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                let backoff = max(Double(header ?? "") ?? 0, 900) // floor 15 min
                let until = Date().addingTimeInterval(backoff)
                self.claudeBackoffUntil = until
                self.claudeNote = "rate limited — retrying \(formatDate(until))"
            } else {
                self.claudeNote = "HTTP \(code) from usage endpoint"
            }
            DispatchQueue.main.async { self.render() }
        }.resume()
    }

    @objc func manualRefresh() {
        claudeBackoffUntil = nil // user explicitly asked — bypass backoff
        refresh()
    }

    private func render() {
        let cl: String
        if let u = claude {
            cl = "CL \(pct(u.five_hour?.utilization))%" + (claudeNote != nil ? "·" : "")
        } else {
            cl = "CL ⚠️"
        }
        let cx = codex.map { "CX \(pct($0.limits.primary?.used_percent))%" } ?? "CX —"
        statusItem.button?.title = "\(cl) · \(cx)"
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        func row(_ s: String, enabled: Bool = false) {
            let item = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            item.isEnabled = enabled
            menu.addItem(item)
        }

        // Claude
        row("CLAUDE")
        if let u = claude {
            if let w = u.five_hour {
                row("  5-hour  \(bar(w.utilization ?? 0)) \(pct(w.utilization))%")
                row("    resets \(formatResetISO(w.resets_at))")
            }
            if let w = u.seven_day {
                row("  7-day   \(bar(w.utilization ?? 0)) \(pct(w.utilization))%")
                row("    resets \(formatResetISO(w.resets_at))")
            }
            if let e = u.extra_usage, e.is_enabled == true {
                let sym = (e.currency ?? "") == "USD" ? "$" : ""
                row(String(format: "  Extra  %@%.0f / %@%.0f", sym, e.used_credits ?? 0, sym, e.monthly_limit ?? 0))
            }
            if let note = claudeNote {
                row("  ⚠️ \(note)")
                row("    showing last reading from \(relativeAge(claudeUpdatedAt))")
            }
        } else if let note = claudeNote {
            row("  ⚠️ \(note)")
        } else {
            row("  Loading…")
        }

        menu.addItem(.separator())

        // Codex
        if let c = codex {
            row("CODEX — \(c.limits.plan_type ?? "")")
            if let w = c.limits.primary {
                row("  5-hour  \(bar(w.used_percent ?? 0)) \(pct(w.used_percent))%")
                row("    resets \(formatResetEpoch(w.resets_at))")
            }
            if let w = c.limits.secondary {
                row("  7-day   \(bar(w.used_percent ?? 0)) \(pct(w.used_percent))%")
                row("    resets \(formatResetEpoch(w.resets_at))")
            }
            row("  as of \(relativeAge(c.asOf)) (last Codex turn)")
        } else {
            row("CODEX")
            row("  No session data yet (run Codex once).")
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(manualRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
