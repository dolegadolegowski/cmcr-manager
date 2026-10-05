import Foundation

/// Target selection used by `cmcrctl`: `all`, the number from the host name (`4` → imac04), lists (`1,3,7`),
/// ranges (`1-5`), list positions (`@2`) and exact names, addresses or accounts (`imac04`, `imac04.local`).
/// Positions use `@`, not `#`: an unquoted `#2` starts a comment in scripts, so the shell would drop it.
///
/// A part that matches nothing is an error – never a fallback to another Mac – so a command meant for one
/// computer cannot silently run on a different one.
public enum HostSpec {
    public enum SelectionError: LocalizedError, Equatable {
        case empty
        case emptyList
        case notFound([String])

        public var errorDescription: String? {
            switch self {
            case .empty: return "Nie podano komputerów (all, numer, lista 1,3 lub zakres 1-5)."
            case .emptyList: return "Lista komputerów jest pusta (cmcrctl hosts generate lub aplikacja › Konfiguracja)."
            case .notFound(let parts):
                let hint = parts.contains { $0.hasPrefix("#") }
                    ? " Pozycję na liście podaj jako @2 – znak # w skryptach rozpoczyna komentarz." : ""
                return "Nie znaleziono komputera: \(parts.joined(separator: ", ")) (lista: cmcrctl list).\(hint)"
            }
        }
    }

    public static func isAll(_ spec: String) -> Bool {
        ["all", "wszystkie", "*"].contains(spec.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Hosts matching `spec`, in list order and without duplicates.
    public static func select(_ spec: String, from hosts: [Machine]) throws -> [Machine] {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SelectionError.empty }
        guard !hosts.isEmpty else { throw SelectionError.emptyList }
        if isAll(trimmed) { return hosts }

        var picked = Set<Int>()
        var missing: [String] = []
        let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw SelectionError.empty }
        for part in parts {
            let found = indices(matching: part, in: hosts)
            if found.isEmpty { missing.append(part) } else { picked.formUnion(found) }
        }
        if !missing.isEmpty { throw SelectionError.notFound(missing) }
        return picked.sorted().map { hosts[$0] }
    }

    static func indices(matching part: String, in hosts: [Machine]) -> [Int] {
        let all = Array(hosts.indices)
        if part.hasPrefix("@"), let pos = Int(part.dropFirst()) {
            return (1...hosts.count).contains(pos) ? [pos - 1] : []
        }
        if let n = Int(part) {
            return all.filter { hosts[$0].number == n }
        }
        let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
        if bounds.count == 2, let a = Int(bounds[0]), let b = Int(bounds[1]), a <= b {
            return all.filter { hosts[$0].number.map { (a...b).contains($0) } ?? false }
        }
        func same(_ x: String) -> Bool { x.caseInsensitiveCompare(part) == .orderedSame }
        let byName = all.filter { same(hosts[$0].name) }
        if !byName.isEmpty { return byName }
        return all.filter { same(hosts[$0].address) || same(hosts[$0].user) || same(hosts[$0].destination) }
    }
}
