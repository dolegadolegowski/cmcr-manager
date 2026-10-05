import Foundation

/// Named groups of computers (rows, rooms, classes) stored on each `Machine`.
public enum HostGroups {
    /// All group names used by `machines`, sorted the way a Polish user expects ("Rząd 2" before "Rząd 10").
    public static func all(in machines: [Machine]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for m in machines {
            for g in m.groups where seen.insert(g.lowercased()).inserted { names.append(g) }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func members(of group: String, in machines: [Machine]) -> [Machine] {
        machines.filter { $0.isMember(of: group) }
    }

    /// Parses "Rząd 1, pracownia B" into ["Rząd 1", "pracownia B"] (trimmed, without duplicates).
    public static func parse(_ text: String) -> [String] {
        normalize(text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline }).map(String.init))
    }

    public static func format(_ groups: [String]) -> String { groups.joined(separator: ", ") }

    public static func normalize(_ groups: [String]) -> [String] {
        var seen = Set<String>()
        return groups
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Adds `group` to every machine whose id is in `ids`.
    public static func add(_ group: String, to ids: Set<UUID>, in machines: inout [Machine]) {
        let name = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        for i in machines.indices where ids.contains(machines[i].id) && !machines[i].isMember(of: name) {
            machines[i].groups.append(name)
        }
    }

    public static func remove(_ group: String, from ids: Set<UUID>, in machines: inout [Machine]) {
        for i in machines.indices where ids.contains(machines[i].id) {
            machines[i].groups.removeAll { $0.caseInsensitiveCompare(group) == .orderedSame }
        }
    }

    public static func rename(_ group: String, to newName: String, in machines: inout [Machine]) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        for i in machines.indices {
            machines[i].groups = normalize(machines[i].groups.map {
                $0.caseInsensitiveCompare(group) == .orderedSame ? name : $0
            })
        }
    }
}

public extension Machine {
    func isMember(of group: String) -> Bool {
        groups.contains { $0.caseInsensitiveCompare(group) == .orderedSame }
    }
}

/// Which hosts the list shows.
public enum HostStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all, online, offline, withUser, attention

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: return "Wszystkie"
        case .online: return "Włączone (online)"
        case .offline: return "Niedostępne"
        case .withUser: return "Z zalogowanym użytkownikiem"
        case .attention: return "Wymagające uwagi"
        }
    }

    public func accepts(_ status: HostStatus) -> Bool {
        switch self {
        case .all: return true
        case .online: return status.reachability == .online
        case .offline: return status.reachability == .offline || status.reachability == .unknown
        case .withUser: return status.consoleUser != nil && status.reachability == .online
        case .attention: return status.reachability == .authFailed || status.reachability == .error
        }
    }
}

public struct HostQuery: Equatable, Sendable {
    public var text = ""
    public var status: HostStatusFilter = .all
    /// Group name; nil shows every host.
    public var group: String?

    public init(text: String = "", status: HostStatusFilter = .all, group: String? = nil) {
        self.text = text
        self.status = status
        self.group = group
    }

    public var isActive: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty || status != .all || group != nil }

    /// Hosts matching the search text (name, address, account, notes, groups, logged-in user), status and group.
    public func apply(to machines: [Machine], status statusOf: (Machine) -> HostStatus) -> [Machine] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        return machines.filter { m in
            if let group, !m.isMember(of: group) { return false }
            let st = statusOf(m)
            if !status.accepts(st) { return false }
            guard !needle.isEmpty else { return true }
            let haystack = [m.name, m.address, m.user, m.notes, st.consoleUser ?? ""] + m.groups
            return haystack.contains { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

public extension Reachability {
    /// Known to be unreachable right now: actions would only wait for a timeout or fail to log in.
    var isUnreachable: Bool { self == .offline || self == .authFailed }
}
