import Foundation

/// One line of `dewey <command> --json` output. Protocol 1: see src/dewey/progress.py and cli.py.
///
/// Every run ends with exactly one closing event: `.result`, `.error` or `.interrupted`.
public enum DeweyEvent: Sendable, Equatable {
    case log(String)
    case progress(ProgressUpdate)
    /// The raw `data` object. Decode it with `DeweyEvent.decoder()` into the command's result type.
    case result(Data)
    case error(code: String, message: String)
    case interrupted(batch: String?, message: String)
    /// A stdout line that isn't a protocol event (never expected; shown as a log line).
    case unreadable(String)

    public var isClosing: Bool {
        switch self {
        case .result, .error, .interrupted: true
        default: false
        }
    }

    /// Result payloads use snake_case keys (`csv_sha256` → `csvSha256`).
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    public static func parse(_ line: String) -> DeweyEvent {
        let data = Data(line.utf8)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = obj["event"] as? String else {
            return .unreadable(line)
        }
        switch kind {
        case "log":
            return .log(obj["text"] as? String ?? "")
        case "progress":
            guard let p = try? decoder().decode(ProgressUpdate.self, from: data) else { return .unreadable(line) }
            return .progress(p)
        case "result":
            let payload = obj["data"] as? [String: Any] ?? [:]
            return .result((try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8))
        case "error":
            return .error(code: obj["code"] as? String ?? "error", message: obj["message"] as? String ?? "")
        case "interrupted":
            return .interrupted(batch: obj["batch"] as? String, message: obj["message"] as? String ?? "")
        default:
            return .unreadable(line)
        }
    }
}

/// A progress event. `phase` is stable (walk, hash, decide, move, undo); `label` is for people.
public struct ProgressUpdate: Codable, Sendable, Equatable {
    public var phase: String
    public var label: String
    public var unit: String
    public var n: Int
    public var total: Int?
    public var bytes: Int64
    public var totalBytes: Int64?
    public var rate: Double
    public var elapsed: Double
    public var eta: Double?
    public var extra: String
    public var done: Bool

    /// 0...1 when the total is known (by bytes when given, since big files dominate the time).
    public var fraction: Double? {
        if let tb = totalBytes, tb > 0 { return min(1, Double(bytes) / Double(tb)) }
        if let t = total, t > 0 { return min(1, Double(n) / Double(t)) }
        return done ? 1 : nil
    }
}

/// `dewey app-info`: the handshake the app does before anything else.
public struct AppInfo: Decodable, Sendable, Equatable {
    public static let supportedProtocol = 1

    public var version: String
    public var protocolVersion: Int
    public var python: String
    public var executable: String

    enum CodingKeys: String, CodingKey {
        case version, protocolVersion = "protocol", python, executable
    }
}
