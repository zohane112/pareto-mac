// Settings: the Jev and Nebius keys (kept in the macOS Keychain), the shortcut, voice,
// and starting at login. Nothing here is ever sent anywhere except each key, to its own service.

import AppKit
import Carbon
import Security
import ServiceManagement

/// Search by meaning turns on when a Jev or Nebius key is saved. There's no plan to pick:
/// with no key, everything stays word for word and on this Mac.
enum Plan: String {
    case free, ai
}

/// The shortcuts offered in settings. ⌥Space is the default; Chrome's Control+Shift+F stays
/// with the Chrome extension.
enum Shortcut: String, CaseIterable, Identifiable {
    case optionSpace, controlSpace, controlOptionSpace, commandShiftSpace
    var id: String { rawValue }
    var label: String {
        switch self {
        case .optionSpace: return "⌥ Space"
        case .controlSpace: return "⌃ Space"
        case .controlOptionSpace: return "⌃⌥ Space"
        case .commandShiftSpace: return "⌘⇧ Space"
        }
    }
    var keyCode: UInt32 { UInt32(kVK_Space) }
    var modifiers: UInt32 {
        switch self {
        case .optionSpace: return UInt32(optionKey)
        case .controlSpace: return UInt32(controlKey)
        case .controlOptionSpace: return UInt32(controlKey | optionKey)
        case .commandShiftSpace: return UInt32(cmdKey | shiftKey)
        }
    }
}

enum Keychain {
    static let service = "com.ctrlf-by-meaning.mac"
    /// The Jev key's account name, from before the Nebius key existed; kept so saved keys carry over.
    static let jev = "jev-api-key"
    static let nebius = "nebius-api-key"

    static func read(_ account: String = jev) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult
    static func save(_ key: String, _ account: String = jev) -> Bool {
        delete(account)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: account == nebius ? "Pareto: Nebius API key" : "Pareto: Jev API key",
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String = jev) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    /// For the self-test only: keys and an endpoint handed over in the environment, never saved.
    /// CTRLF_NO_JEV=1 hides a saved Jev key, to test Nemotron on its own.
    private let env = ProcessInfo.processInfo.environment
    private var testKey: String? { env["CTRLF_JEV_KEY"] }
    private var testNebiusKey: String? { env["CTRLF_NEBIUS_KEY"] }
    private var noJev: Bool { env["CTRLF_NO_JEV"] == "1" }

    @Published var plan: Plan
    @Published var shortcut: Shortcut {
        didSet { defaults.set(shortcut.rawValue, forKey: "shortcut") }
    }
    /// The look: digital (light, the default) or terminal (plain dark).
    @Published var look: Look {
        didSet { defaults.set(look.rawValue, forKey: "look") }
    }
    /// Text that arrives all at once (how Wispr Flow and other dictation types) runs by itself.
    @Published var actAfterVoice: Bool {
        didSet { defaults.set(actAfterVoice, forKey: "actAfterVoice") }
    }
    /// Hold the shortcut to speak, let go to run it.
    @Published var holdToTalk: Bool {
        didSet { defaults.set(holdToTalk, forKey: "holdToTalk") }
    }
    @Published private(set) var hasJevKey: Bool { didSet { plan = hasJevKey || hasNebiusKey ? .ai : .free } }
    @Published private(set) var hasNebiusKey: Bool { didSet { plan = hasJevKey || hasNebiusKey ? .ai : .free } }
    /// After a search by meaning, Nemotron 3 Super writes a short answer (needs a Nebius key).
    @Published var writeAnswers: Bool {
        didSet { defaults.set(writeAnswers, forKey: "writeAnswers") }
    }
    /// macOS refused the shortcut: another app already uses it.
    @Published var shortcutTaken = false
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }
    var onboarded: Bool {
        get { defaults.bool(forKey: "onboarded") }
        set { defaults.set(newValue, forKey: "onboarded") }
    }

    private init() {
        let env = ProcessInfo.processInfo.environment
        let hasKey = env["CTRLF_NO_JEV"] != "1" && (env["CTRLF_JEV_KEY"] != nil || Keychain.read() != nil)
        let hasNebius = env["CTRLF_NEBIUS_KEY"] != nil || Keychain.read(Keychain.nebius) != nil
        hasJevKey = hasKey
        hasNebiusKey = hasNebius
        writeAnswers = defaults.object(forKey: "writeAnswers") as? Bool ?? true
        plan = hasKey || hasNebius ? .ai : .free
        shortcut = Shortcut(rawValue: defaults.string(forKey: "shortcut") ?? "") ?? .optionSpace
        look = Look(rawValue: defaults.string(forKey: "look") ?? "") ?? .digital
        actAfterVoice = defaults.object(forKey: "actAfterVoice") as? Bool ?? true
        holdToTalk = defaults.object(forKey: "holdToTalk") as? Bool ?? true
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } else {
            launchAtLogin = false
        }
    }

    var jevKey: String? { noJev ? nil : testKey ?? Keychain.read() }
    var nebiusKey: String? { testNebiusKey ?? Keychain.read(Keychain.nebius) }
    /// Token Factory's address: the default, or CTRLF_NEBIUS_BASE for the checks.
    var nebiusBase: URL { URL(string: env["CTRLF_NEBIUS_BASE"] ?? "") ?? Nemotron.defaultBase }

    func saveJevKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Keychain.save(trimmed) else { return false }
        hasJevKey = true
        return true
    }

    func removeJevKey() {
        Keychain.delete()
        hasJevKey = testKey != nil && !noJev
    }

    func saveNebiusKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Keychain.save(trimmed, Keychain.nebius) else { return false }
        hasNebiusKey = true
        return true
    }

    func removeNebiusKey() {
        Keychain.delete(Keychain.nebius)
        hasNebiusKey = testNebiusKey != nil
    }

    private func applyLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Pareto: launch at login: \(error.localizedDescription)")
        }
    }

    static let jevKeys = URL(string: "https://console.typesafe.ai/keys")!
    static let nebiusKeys = URL(string: "https://tokenfactory.nebius.com/")!
}
