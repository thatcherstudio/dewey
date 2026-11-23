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
            self.scheme = scheme
            self.host = ThisMac.isNamed(by: host) ? "this-mac" : host
            // No port: the scheme's own, which is where dewey sends a folder's `[decider] url`. The
            // app's own Laya URL arrives here with its port filled in (`LayaController.baseURL`).
            self.port = c.port ?? (scheme == "https" ? 443 : 80)
            self.path = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
        }
    }
}

/// The names an address can use for this Mac itself: localhost, 127.x.x.x, ::1.
enum ThisMac {
    static func isNamed(by host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1"
            || (host.hasPrefix("127.") && host.split(separator: ".").count == 4)
    }
}

/// What Scan & Plan does about the model before it reads a file, so that a plan doesn't fail for
/// want of it after the whole scan.
public enum ModelStart: Equatable, Sendable {
    /// Nothing: the model is ready or loading, isn't the app's to start, or isn't asked at all.
    case nothing
    /// The app's Laya is installed and not running: start it, and it loads while the scan runs.
    case startLaya
    /// The plan would ask the app's Laya, and Laya isn't installed: ask first (install it, or plan
    /// with rules only).
    case askToInstall

    /// - Parameters:
    ///   - source: which model the folder's plans ask; nil until `dewey status` has said (the app's
    ///     Laya is the default, so that is assumed).
    ///   - laya: the app's Laya, and `layaRunning` whether this app has a laya-serve running.
    ///   - layaIsLocal: the app's Laya URL names this Mac (one elsewhere isn't the app's to start).
    ///   - installed: a laya-serve was found on this Mac; nil while the app is still looking.
    public init(source: ModelSource?, laya: LayaController.Status, layaRunning: Bool, layaIsLocal: Bool,
                installed: Bool?) {
        guard source?.isAppLaya ?? true, layaIsLocal, !layaRunning else { self = .nothing; return }
        if case .ready = laya { self = .nothing; return }
        switch installed {
        case true?: self = .startLaya
        case false?: self = .askToInstall
        case nil: self = .nothing
        }
    }
}
