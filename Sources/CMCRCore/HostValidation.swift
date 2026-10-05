import Foundation

/// Problems in the host list that would make actions hit the wrong Mac or fail.
public enum HostIssue: Hashable, Sendable {
    case emptyName, emptyAddress, emptyUser, duplicateName, duplicateAddress, invalidPort, invalidMAC

    public var message: String {
        switch self {
        case .emptyName: return "Brak nazwy."
        case .emptyAddress: return "Brak adresu (np. imac01.local)."
        case .emptyUser: return "Brak konta administratora."
        case .duplicateName: return "Ta sama nazwa jest użyta więcej niż raz – polecenia i foldery mogą trafić do złego komputera."
        case .duplicateAddress: return "Ten sam adres i port są użyte więcej niż raz."
        case .invalidPort: return "Port musi być liczbą od 1 do 65535."
        case .invalidMAC: return "Adres MAC ma zły format (oczekiwano np. a4:83:e7:12:34:56)."
        }
    }
}

public enum HostValidation {
    public static let portRange = 1...65_535

    public static func isValidMAC(_ s: String) -> Bool {
        let parts = s.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return false }
        return parts.allSatisfy { p in (1...2).contains(p.count) && p.allSatisfy(\.isHexDigit) }
    }

    /// Issues per host id (hosts without problems are absent).
    public static func issues(in machines: [Machine]) -> [UUID: [HostIssue]] {
        func key(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }
        var names: [String: Int] = [:], addresses: [String: Int] = [:]
        for m in machines {
            names[key(m.name), default: 0] += 1
            addresses["\(key(m.address)):\(m.port)", default: 0] += 1
        }
        var result: [UUID: [HostIssue]] = [:]
        for m in machines {
            var list: [HostIssue] = []
            if key(m.name).isEmpty { list.append(.emptyName) } else if names[key(m.name)]! > 1 { list.append(.duplicateName) }
            if key(m.address).isEmpty {
                list.append(.emptyAddress)
            } else if addresses["\(key(m.address)):\(m.port)"]! > 1 {
                list.append(.duplicateAddress)
            }
            if key(m.user).isEmpty { list.append(.emptyUser) }
            if !portRange.contains(m.port) { list.append(.invalidPort) }
            if !m.macAddress.trimmingCharacters(in: .whitespaces).isEmpty && !isValidMAC(m.macAddress) {
                list.append(.invalidMAC)
            }
            if !list.isEmpty { result[m.id] = list }
        }
        return result
    }

    /// The next host following the cmcr-helpers naming (`imacNN` on `imacNN.local`) that is not taken yet:
    /// the lowest free number, so deleting imac03 and adding again gives imac03, never a second imac15.
    public static func nextMachine(after machines: [Machine], prefix: String = "imac", digits: Int = 2,
                                   domain: String = "local") -> Machine {
        let usedNumbers = Set(machines.compactMap(\.number))
        let usedNames = Set(machines.map { $0.name.lowercased() })
        var n = 1
        while true {
            let name = prefix + String(format: "%0\(max(1, digits))d", n)
            if !usedNumbers.contains(n) && !usedNames.contains(name.lowercased()) {
                return Machine(name: name, address: domain.isEmpty ? name : "\(name).\(domain)", user: name)
            }
            n += 1
        }
    }
}
