import Foundation

/// hosts.json exists but cannot be used; `reason` is a short Polish description.
public struct HostsFileError: LocalizedError, Sendable {
    public let reason: String
    public var errorDescription: String? { reason }
}

public extension ConfigStore {
    /// The saved host list, or nil when hosts.json does not exist yet (the default lab applies).
    /// Unlike `loadHosts()` an unreadable file is an error, not the default list: code that edits and saves
    /// the list must never replace the user's entries with the fifteen default iMacs.
    static func readHostsFile() throws -> [Machine]? {
        guard FileManager.default.fileExists(atPath: hostsURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: hostsURL)
        } catch {
            throw HostsFileError(reason: "brak dostępu do pliku: \(error.localizedDescription)")
        }
        return try decodeHosts(data)
    }

    static func decodeHosts(_ data: Data) throws -> [Machine] {
        do {
            return try JSONDecoder().decode([Machine].self, from: data)
        } catch let error as DecodingError {
            throw HostsFileError(reason: describe(error))
        }
    }

    /// "brak pola „address” (wpis nr 2)" instead of Foundation's generic "The data couldn't be read…".
    internal static func describe(_ error: DecodingError) -> String {
        func place(_ path: [CodingKey]) -> String {
            let parts = path.map { key in key.intValue.map { "wpis nr \($0 + 1)" } ?? "pole „\(key.stringValue)”" }
            return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "brak pola „\(key.stringValue)”" + place(context.codingPath)
        case .typeMismatch(_, let context) where context.codingPath.isEmpty:
            return "plik nie zawiera listy komputerów"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "niepoprawna wartość" + place(context.codingPath)
        case .dataCorrupted(let context) where context.codingPath.isEmpty:
            let detail = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            return "niepoprawny JSON" + (detail.map { " – \($0)" } ?? "")
        case .dataCorrupted(let context):
            return "niepoprawna wartość" + place(context.codingPath)
        @unknown default:
            return error.localizedDescription
        }
    }
}
