import CMCRCore
import Foundation

extension CLI {
    // MARK: - hosts

    func hostsCommand() -> Int32 {
        switch args[1] ?? "list" {
        case "list": return hostsList()
        case "add": return hostsAdd()
        case "remove", "rm": return hostsRemove()
        case "generate": return hostsGenerate()
        case "set": return hostsSet()
        default: usageError("Użycie: cmcrctl hosts [list|add|set|remove|generate]")
        }
    }

    func hostsList() -> Int32 {
        args.expect("hosts list", positional: 2)
        warnIfDefaultHosts()
        guard !hosts.isEmpty else {
            Console.out("Lista komputerów jest pusta – dodaj: cmcrctl hosts generate --replace")
            return ExitCode.success
        }
        Console.out(pad("#", 3, right: true) + "  " + pad("nazwa", 12) + " " + pad("konto@adres", 28) + " "
                    + pad("port", 5, right: true) + "  " + pad("MAC (Wake-on-LAN)", 17) + "  hasło")
        for (i, h) in hosts.enumerated() {
            Console.out(pad("\(i + 1)", 3, right: true) + "  " + pad(h.name, 12) + " " + pad(h.destination, 28) + " "
                        + pad("\(h.port)", 5, right: true) + "  " + pad(h.macAddress.isEmpty ? "—" : h.macAddress, 17)
                        + "  " + (h.usesSharedPassword ? "wspólne" : "własne"))
        }
        return ExitCode.success
    }

    func hostsAdd() -> Int32 {
        args.expect("hosts add", options: ["--port", "--mac"], positional: 5)
        let hosts = editableHosts()
        guard let name = args[2]?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            usageError("Użycie: cmcrctl hosts add nazwa [adres] [konto] [--port N] [--mac MAC]")
        }
        _ = checked(name, .name, "Niepoprawna nazwa")
        if args[3] == nil || args[4] == nil, let problem = HostEntry.problem(name, as: .sshPart) {
            usageError("Nazwa „\(name)” \(problem) – podaj też adres i konto: cmcrctl hosts add \"\(name)\" adres konto")
        }
        let address = checked(args[3]?.trimmingCharacters(in: .whitespaces) ?? "\(name).local", .sshPart, "Niepoprawny adres")
        let user = checked(args[4]?.trimmingCharacters(in: .whitespaces) ?? name, .sshPart, "Niepoprawne konto")
        let port = args.int("--port", in: 1...65535) ?? 22
        let mac = normalizedMAC(args.value("--mac") ?? "")
        if let dup = hosts.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame
            || ($0.address.caseInsensitiveCompare(address) == .orderedSame && $0.port == port) }) {
            fail("Komputer \(dup.name) (\(dup.destination)) już jest na liście.", code: ExitCode.usage)
        }
        let added = Machine(name: name, address: address, user: user, port: port, macAddress: mac)
        ConfigStore.saveHosts(hosts + [added])
        Console.out("Dodano \(added.name) (\(added.destination)\(port == 22 ? "" : ", port \(port)")).")
        return ExitCode.success
    }

    func hostsSet() -> Int32 {
        let use = "Użycie: cmcrctl hosts set nr [--mac MAC] [--port N]"
        args.expect("hosts set", options: ["--mac", "--port"], positional: 3)
        let hosts = editableHosts()
        let host = single(args[2], usage: use)
        let port = args.int("--port", in: 1...65535)
        let mac = args.value("--mac").map(normalizedMAC)
        guard port != nil || mac != nil else { usageError(use) }
        var list = hosts
        guard let i = list.firstIndex(where: { $0.id == host.id }) else { return ExitCode.failure }
        if let port { list[i].port = port }
        if let mac { list[i].macAddress = mac }
        ConfigStore.saveHosts(list)
        let h = list[i]
        Console.out("Zapisano \(h.name): port \(h.port), MAC \(h.macAddress.isEmpty ? "—" : h.macAddress).")
        return ExitCode.success
    }

    /// `aa:bb:cc:dd:ee:ff` from any common spelling; an empty value clears the address.
    func normalizedMAC(_ raw: String) -> String {
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        guard let mac = HostEntry.normalizedMAC(raw) else { usageError("Niepoprawny adres MAC: \(raw)") }
        return mac
    }

    /// `value`, or a usage error such as "Niepoprawny adres „a b”: zawiera spację." before anything is saved.
    func checked(_ value: String, _ kind: HostEntry.Kind, _ lead: String) -> String {
        if let problem = HostEntry.problem(value, as: kind) { usageError("\(lead) „\(value)”: \(problem).") }
        return value
    }

    func hostsRemove() -> Int32 {
        args.expect("hosts remove", positional: 3)
        guard args[2] != nil else { usageError("Użycie: cmcrctl hosts remove KOMP") }
        let hosts = editableHosts()
        let gone = targets(args[2])
        confirm("Usunąć z listy: \(names(gone))? Na samych iMacach nic się nie zmieni.")
        let ids = Set(gone.map(\.id))
        ConfigStore.saveHosts(hosts.filter { !ids.contains($0.id) })
        Console.out("Usunięto z listy: \(gone.map(\.name).joined(separator: ", ")).")
        return ExitCode.success
    }

    /// Same generator as Konfiguracja › Komputery (the loop at the top of cmcr-helpers.sh).
    func hostsGenerate() -> Int32 {
        args.expect("hosts generate", options: ["--start", "--count", "--digits", "--domain", "--replace", "--append"],
                    positional: 3)
        let prefix = checked(args[2] ?? "imac", .sshPart, "Niepoprawny prefiks")
        let start = args.int("--start", in: 0...999) ?? 1
        let count = args.int("--count", in: 1...250) ?? 15
        let digits = args.int("--digits", in: 1...4) ?? 2
        let domain = checked(args.value("--domain") ?? "local", .domain, "Niepoprawna domena (--domain)")
        let replace = args.has("--replace"), append = args.has("--append")
        if replace && append { usageError("Wybierz --replace albo --append.") }
        let hosts = append ? editableHosts() : hosts
        let generated = Machine.generate(prefix: prefix, start: start, count: count, digits: digits, domain: domain)
        let sample = generated.prefix(3).map(\.destination).joined(separator: ", ")
            + (generated.count > 3 ? " … \(generated.last!.destination)" : "")
        Console.out("Wygenerowano \(plural(generated.count, "komputer", "komputery", "komputerów")): \(sample)")
        if replace {
            confirm(hostsProblem == nil
                    ? "Zastąpić obecną listę (\(hosts.count)) wygenerowanymi wpisami (\(generated.count))?"
                    : "Zastąpić nieczytelny plik \(hostsPath) wygenerowanymi wpisami (\(generated.count))?")
            ConfigStore.saveHosts(generated)
            Console.out("Lista komputerów zastąpiona.")
        } else if append {
            let existing = Set(hosts.map { $0.address.lowercased() })
            let new = generated.filter { !existing.contains($0.address.lowercased()) }
            ConfigStore.saveHosts(hosts + new)
            Console.out("Dopisano \(plural(new.count, "komputer", "komputery", "komputerów")) (pominięto już obecne).")
        } else {
            Console.out("To tylko podgląd – dodaj --replace (zastąp listę) lub --append (dopisz brakujące).")
        }
        return ExitCode.success
    }

    // MARK: - password

    func password() -> Int32 {
        let use = "Użycie: cmcrctl password set|clear|status [--host nr]"
        guard let sub = args[1] else { usageError(use) }
        args.expect("password \(sub)", options: sub == "status" ? [] : ["--host"], positional: 2)
        // Choosing a host saves the list (the Keychain account is derived from its id): check it first.
        if args.value("--host") != nil { _ = editableHosts() }
        let host = args.value("--host").map { single($0, usage: use) }
        switch sub {
        case "set":
            let secret = readSecret()
            guard !secret.isEmpty else { fail("Nie podano hasła (pusty wiersz) – nic nie zapisano.", code: ExitCode.usage) }
            let account = host.map(Keychain.account(for:)) ?? Keychain.sharedAccount
            guard Keychain.set(secret, for: account) else { fail("Nie udało się zapisać hasła w Pęku kluczy.") }
            if let host { setUsesShared(false, for: host) }
            Console.out(host.map { "Zapisano własne hasło administratora komputera \($0.name) w Pęku kluczy." }
                        ?? "Zapisano wspólne hasło administratora w Pęku kluczy.")
        case "clear":
            let account = host.map(Keychain.account(for:)) ?? Keychain.sharedAccount
            guard Keychain.set(nil, for: account) else { fail("Nie udało się usunąć hasła z Pęku kluczy.") }
            if let host { setUsesShared(true, for: host) }
            Console.out(host.map { "Usunięto własne hasło komputera \($0.name) – używa hasła wspólnego." }
                        ?? "Usunięto wspólne hasło administratora z Pęku kluczy.")
        case "status":
            Console.out("Wspólne hasło administratora: \(Keychain.exists(Keychain.sharedAccount) ? "zapisane" : "brak")")
            for h in hosts where !h.usesSharedPassword {
                Console.out("\(h.name): własne hasło – \(Keychain.exists(Keychain.account(for: h)) ? "zapisane" : "brak")")
            }
            if let env = ProcessInfo.processInfo.environment["CMCR_PASSWORD"], !env.isEmpty {
                Console.out("Ustawiona zmienna CMCR_PASSWORD – ma pierwszeństwo przed Pękiem kluczy.")
            }
        default:
            usageError(use)
        }
        return ExitCode.success
    }

    /// Always saves: the Keychain account is derived from the host `id`, which must therefore be persisted.
    func setUsesShared(_ shared: Bool, for host: Machine) {
        guard let i = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        var list = hosts
        list[i].usesSharedPassword = shared
        ConfigStore.saveHosts(list)
    }

    /// First line of stdin; on a terminal read without echo (and asked twice).
    func readSecret() -> String {
        guard isatty(STDIN_FILENO) != 0 else {
            var line = readLine(strippingNewline: true) ?? ""
            if line.hasSuffix("\r") { line.removeLast() }
            return line
        }
        func ask(_ prompt: String) -> String {
            var buffer = [CChar](repeating: 0, count: 1024)
            guard let p = readpassphrase(prompt, &buffer, buffer.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY) else {
                fail("Nie można odczytać hasła z terminala.")
            }
            let value = String(cString: p)
            for i in buffer.indices { buffer[i] = 0 }
            return value
        }
        let first = ask("Hasło administratora: ")
        guard !first.isEmpty else { return "" }
        guard ask("Powtórz hasło: ") == first else { fail("Hasła się różnią – nic nie zapisano.", code: ExitCode.usage) }
        return first
    }
}
