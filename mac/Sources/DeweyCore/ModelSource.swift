import Foundation

/// Which decision model a folder's plans ask, next to the Laya this app runs.
///
/// The app starts and watches one Laya (Dewey > Settings…, Laya URL). dewey asks whatever the folder's
/// own settings name (`[decider]` in its dewey.toml). The two usually agree. When they don't, the Laya
/// light says nothing about this folder's plans, so the folder's screens say which model it is.
public enum ModelSource: Equatable, Sendable {
    /// The Laya this app runs.
    case appLaya
    /// A Laya (or Jev-compatible) server somewhere else: another port, another machine.
    case otherLaya(String)
    /// A chat model on an OpenAI-compatible server.
    case chat(String)
    /// No model: rules and duplicates only.
    case rulesOnly

    /// `backend` and `url` are the folder's `[decider]` settings, `appLaya` the server the app runs.
    public init(backend: String, url: String, appLaya: URL) {
        switch backend {
        case "none": self = .rulesOnly
        case "chat": self = .chat(Self.place(url))
        default: self = Self.sameServer(url, appLaya.absoluteString) ? .appLaya : .otherLaya(Self.place(url))
        }
    }

    /// Plans wait for, and can start, the app's own Laya.
    public var isAppLaya: Bool { self == .appLaya }

    /// Both addresses reach one server: same scheme and port, and the same host, where every name for
    /// this Mac itself (localhost, 127.0.0.1, ::1) is one host.
    static func sameServer(_ a: String, _ b: String) -> Bool {
        guard let x = Address(a), let y = Address(b) else {
            return a.trimmingCharacters(in: .whitespaces) == b.trimmingCharacters(in: .whitespaces)
        }
        return x == y
    }

    /// "192.168.1.20:8000": the server as a person would say it.
    public static func place(_ url: String) -> String {
        let text = url.trimmingCharacters(in: .whitespaces)
        guard let c = URLComponents(string: text), let host = c.host, !host.isEmpty else { return text }
        return c.port.map { "\(host):\($0)" } ?? host
    }

    private struct Address: Equatable {
        var scheme: String
        var host: String
        var port: Int
        var path: String

        init?(_ text: String) {
            guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespaces)),
                  let scheme = c.scheme?.lowercased(), var host = c.host?.lowercased(), !host.isEmpty else { return nil }
            host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let thisMac = host == "localhost" || host.hasSuffix(".localhost") || host == "::1"
                || (host.hasPrefix("127.") && host.split(separator: ".").count == 4)
            self.scheme = scheme
            self.host = thisMac ? "this-mac" : host
            self.port = c.port ?? (scheme == "https" ? 443 : 80)
            self.path = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
        }
    }
}
