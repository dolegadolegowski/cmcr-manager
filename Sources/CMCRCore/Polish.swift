import Foundation

/// Polish grammatical number: 1 komputer, 2–4 komputery (but 12–14 komputerów), 5+ komputerów.
public enum Polish {
    public enum PluralForm: Sendable { case one, few, many }

    public static func form(_ n: Int) -> PluralForm {
        let n = abs(n)
        if n == 1 { return .one }
        let units = n % 10, tens = n % 100
        if (2...4).contains(units) && !(12...14).contains(tens) { return .few }
        return .many
    }

    /// Picks the word form for `n`: `plural(5, "komputer", "komputery", "komputerów")` → "komputerów".
    public static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        switch form(n) {
        case .one: return one
        case .few: return few
        case .many: return many
        }
    }

    /// Number followed by the matching word form: "2 komputery".
    public static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        "\(n) \(plural(n, one, few, many))"
    }

    /// "1 komputer", "3 komputery", "12 komputerów".
    public static func computers(_ n: Int) -> String { count(n, "komputer", "komputery", "komputerów") }

    /// Locative after "na": "na 1 komputerze", "na 5 komputerach".
    public static func onComputers(_ n: Int) -> String { "na \(n) \(n == 1 ? "komputerze" : "komputerach")" }

    /// Genitive after "z"/"dla": "z 1 komputera", "z 4 komputerów".
    public static func ofComputers(_ n: Int) -> String { "\(n) \(n == 1 ? "komputera" : "komputerów")" }

    /// "1 zadanie", "2 zadania", "5 zadań".
    public static func jobs(_ n: Int) -> String { count(n, "zadanie", "zadania", "zadań") }

    /// "1 plik", "2 pliki", "5 plików".
    public static func files(_ n: Int) -> String { count(n, "plik", "pliki", "plików") }
}
