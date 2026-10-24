import SwiftUI
import Combine
import Foundation
import Security

// DaemonBridgeV3 is a secure-ish LAN draft handoff, not a privileged iOS daemon controller.
// It NEVER claims that a staged config changed the running operating system.
private enum BridgeKeychain {
    static let service = "com.kizzimo.powerlab.daemonbridge"
    static let account = "local-stage-token"
    static func read() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func write(_ value: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard let data = value.data(using: .utf8), !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

@MainActor final class DaemonBridgeV3: ObservableObject {
    @Published var host = UserDefaults.standard.string(forKey: "daemonbridge.host") ?? ""
    @Published var token = BridgeKeychain.read()
    @Published var status = "Not connected"
    @Published var busy = false

    private func endpoint(_ suffix: String) throws -> URL {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let octets = h.split(separator: ".").compactMap { Int($0) }
        let privateIP = octets.count == 4 && octets.allSatisfy { (0...255).contains($0) } &&
            (octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) ||
             (octets[0] == 172 && (16...31).contains(octets[1])))
        guard privateIP, let url = URL(string: "http://\(h):8765\(suffix)") else {
            throw NSError(domain: "DaemonBridge", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Enter the Windows computer's private LAN IPv4 address (10.x.x.x, 172.16-31.x.x, or 192.168.x.x)."
            ])
        }
        return url
    }

    func save() {
        host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(host, forKey: "daemonbridge.host")
        BridgeKeychain.write(token)
    }

    func check() async {
        guard !busy else { return }
        save()
        busy = true
        defer { busy = false }
        do {
            var req = URLRequest(url: try endpoint("/health"))
            req.timeoutInterval = 7
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let json = (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
            status = "Connected: \(json?["mode"] as? String ?? "draft staging"). Protected daemons unchanged."
        } catch {
            status = "Unavailable: \(error.localizedDescription)"
        }
    }

    func send(_ draft: DaemonDraft, preset: String) async {
        guard !busy else { return }
        save()
        busy = true
        defer { busy = false }
        do {
            guard !token.isEmpty else {
                throw NSError(domain: "DaemonBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Pairing token missing. Enter the token shown by the Windows companion."])
            }
            let bytes = try Data(contentsOf: draft.exportXML())
            let changes: [String: String] = draft.edits.mapValues {
                switch $0 {
                case .disabled: return "disable"
                case .enabled: return "enable"
                case .remove: return "remove"
                }
            }
            let payload: [String: Any] = [
                "preset": preset, "changes": changes, "source": draft.sourceName,
                "plist_base64": bytes.base64EncodedString()
            ]
            var req = URLRequest(url: try endpoint("/stage"))
            req.httpMethod = "POST"
            req.timeoutInterval = 15
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(token, forHTTPHeaderField: "X-Bridge-Token")
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let msg = json?["message"] as? String ?? "Unknown response"
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                status = "STAGED ON WINDOWS: \(msg). This has NOT changed iOS daemons."
            } else {
                status = "Rejected: \(msg)"
            }
        } catch {
            status = "Nothing sent: \(error.localizedDescription)"
        }
    }
}

enum DaemonPresetV3: String, CaseIterable, Identifiable {
    case restore = "Restore Draft"
    case balanced = "Balanced"
    case performance = "Performance"
    case extreme = "Extreme"
    case custom = "Custom"
    var id: String { rawValue }

    var labels: [String] {
        let balanced = ["com.apple.tipsd"]
        let performance = balanced + ["com.apple.gamed", "com.apple.printd", "com.apple.UsageTrackingAgent"]
        switch self {
        case .restore, .custom: return []
        case .balanced: return balanced
        case .performance: return performance
        case .extreme: return performance + [
            "com.apple.atc.atwakeup", "com.apple.MobileInternetSharing",
            "com.apple.assistant_service", "com.apple.assistantd", "com.apple.voiced",
            "com.apple.searchd", "com.apple.corespotlightservice",
            "com.apple.spotlightknowledged", "com.apple.spotlightknowledged.updater",
            "com.apple.spotlight.IndexAgent"
        ]
        }
    }
}

// Stores only manually staged choices. "Restore Draft" removes edits, not live daemon changes.
enum DaemonPresetStorage {
    private static let key = "daemonbridge.custom"
    static func custom() -> [String: DraftOverride] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode([String: DraftOverride].self, from: data) else { return [:] }
        return value
    }
    static func saveCustom(_ value: [String: DraftOverride]) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}
