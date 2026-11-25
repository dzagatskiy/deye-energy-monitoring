import Foundation

/// Extracts AppId / AppSecret from text the user copied from the Deye developer portal (or a note, a message,
/// JSON, `KEY=value` lines). Labelled values win; otherwise falls back to the observed shapes:
/// AppId — a long run of digits, AppSecret — 32 hex characters. Exact formats are not documented by Deye,
/// so the result is always shown to the user for confirmation before saving.
public enum DeyeAppCredentialsParser {
    public struct Result: Equatable, Sendable {
        public var appId: String?
        public var appSecret: String?
        public var isComplete: Bool { appId != nil && appSecret != nil }
    }

    public static func parse(_ text: String) -> Result {
        var result = Result(
            appId: labelled(text, label: #"app[\s_\-]*id"#, value: #"[A-Za-z0-9\-_]{6,128}"#),
            appSecret: labelled(text, label: #"app[\s_\-]*secret|secret[\s_\-]*(?:id|key)?"#, value: #"[A-Za-z0-9\-_]{16,128}"#)
        )
        if result.appSecret == nil {
            result.appSecret = firstMatch(text, #"(?<![A-Za-z0-9])[0-9a-fA-F]{32}(?![A-Za-z0-9])"#, group: 0)
        }
        if result.appId == nil {
            result.appId = firstMatch(text, #"(?<![A-Za-z0-9])[0-9]{10,20}(?![A-Za-z0-9])"#, group: 0)
        }
        if result.appId == result.appSecret { result.appSecret = nil }
        return result
    }

    /// `label <separator> value`, where the separator may be `:`, `=`, quotes, spaces or a newline.
    private static func labelled(_ text: String, label: String, value: String) -> String? {
        firstMatch(text, #"(?i)(?<![A-Za-z])(?:"# + label + #")["'\s]*[:=]?["'\s]*("# + value + ")", group: 1)
    }

    private static func firstMatch(_ text: String, _ pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range(at: group), in: text) else { return nil }
        return String(text[r])
    }
}

extension DeyeAppCredentialsParser {
    public enum ImportError: Error, Equatable, Sendable {
        case emptyInput
        case missingAppId
        case missingAppSecret
        case implausible
    }

    /// Strict variant for automation (Shortcuts): both keys must be found and look plausible,
    /// otherwise nothing is saved. Used where there is no form for the user to correct the result.
    public static func credentials(from text: String) throws(ImportError) -> DeyeAppCredentials {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyInput }
        let r = parse(text)
        guard let appId = r.appId else { throw .missingAppId }
        guard let appSecret = r.appSecret else { throw .missingAppSecret }
        let keys = DeyeAppCredentials(appId: appId, appSecret: appSecret)
        guard keys.isPlausible else { throw .implausible }
        return keys
    }
}
