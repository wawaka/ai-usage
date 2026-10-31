import AIUsageCore
import Foundation

// Diagnostic CLI: `ai-usage-cli [status|accounts] [--json]`. Shares state with the app
// (accounts added in the app are visible here on macOS through the Keychain).

let args = Array(CommandLine.arguments.dropFirst())
let json = args.contains("--json")
let command = args.first { !$0.hasPrefix("-") } ?? "status"

#if os(macOS)
let service = UsageService(secrets: KeychainSecretStore(), keychain: SystemKeychainReader())
#else
let service = UsageService(secrets: FileSecretStore())
#endif

func bar(_ pct: Double, width: Int = 20) -> String {
    let filled = Int((min(max(pct, 0), 100) / 100 * Double(width)).rounded())
    return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
}

func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: max(n, s.count), withPad: " ", startingAt: 0) }

switch command {
case "accounts":
    for a in await service.rescan() {
        print("\(pad(a.provider.displayName, 9)) \(a.label)  —  \(a.sourceDescription)")
    }
case "status":
    let statuses = await service.refreshAll()
    if json {
        let out: [[String: Any]] = statuses.map { s in
            var o: [String: Any] = ["id": s.account.id, "provider": s.account.provider.rawValue, "label": s.account.label,
                                    "source": s.account.sourceDescription, "state": s.analysis?.state.rawValue ?? "unknown"]
            if let e = s.error { o["error"] = e }
            if let snap = s.snapshot {
                o["windows"] = (snap.windows + snap.extraWindows).map { w -> [String: Any] in
                    var d: [String: Any] = ["label": w.label, "used_percent": w.usedPercent]
                    if let r = w.resetsAt { d["resets_at"] = ISO8601DateFormatter().string(from: r) }
                    return d
                }
                if let b = snap.balance { o["balance"] = b.formatted }
                if let p = snap.plan { o["plan"] = p }
            }
            return o
        }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } else {
        if statuses.isEmpty { print("No accounts found. Log in to an AI tool, or add an account in AI Usage.") }
        for s in statuses {
            let plan = Format.planLabel(s.snapshot?.plan).map { " (\($0))" } ?? ""
            print("\n\(s.account.provider.displayName) · \(s.account.label)\(plan)\(s.analysis?.state.badge.map { " [\($0)]" } ?? "")")
            if let snap = s.snapshot {
                if let b = snap.balance { print("  balance  \(b.formatted)\(b.isAvailable ? "" : " (depleted)")") }
                for w in snap.windows + snap.extraWindows {
                    print("  \(pad(w.label, 9)) \(bar(w.usedPercent)) \(pad(Format.percent(w.usedPercent), 5)) \(w.isUntouched ? "not started" : "\(pad(Format.countdown(w.resetsAt), 7)) \(Format.reset(w.resetsAt))")")
                }
            }
            if let e = s.error { print("  error: \(e)") } else if let m = s.analysis?.message { print("  \(m)") }
            print("  via \(s.account.sourceDescription)")
        }
        print()
    }
default:
    print("usage: ai-usage-cli [status|accounts] [--json]")
}
