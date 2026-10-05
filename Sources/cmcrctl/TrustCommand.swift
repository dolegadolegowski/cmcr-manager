import CMCRCore
import Foundation

extension CLI {
    static let trustUsage = """
      trust [KOMP] [--dry-run]                 pokaż odciski kluczy SSH komputerów i zaufaj nowym (pierwsze
                                               połączenie, reinstalacja); bez zaufanego klucza żadne polecenie
                                               nie łączy się z komputerem, więc hasło nie trafi do podszywającego się urządzenia
    """

    /// `cmcrctl trust [KOMP] [--dry-run]`: the same first-contact flow as the app's HostTrustSheet. Fetches each
    /// Mac's key without logging in, prints its fingerprint and trusts the new or changed ones after a
    /// confirmation (`--yes` in scripts). A changed key is named loudly: it may mean a device impersonating the Mac.
    func trust() async -> Int32 {
        args.expect("trust", options: ["--dry-run"], positional: 2)
        let list = targetsOrAllAtTerminal(args[1], command: "trust")
        let ssh = sshSettings()
        var scans = Array(repeating: HostTrust.Scan?.none, count: list.count)
        await withTaskGroup(of: (Int, HostTrust.Scan).self) { group in
            var active = 0
            for (i, host) in list.enumerated() {
                if active >= 8, let (done, scan) = await group.next() {
                    scans[done] = scan
                    active -= 1
                }
                group.addTask { (i, await HostTrust.scan(host, settings: ssh)) }
                active += 1
            }
            for await (done, scan) in group { scans[done] = scan }
        }
        var code = ExitCode.success
        var candidates: [HostTrust.Scan] = []
        var changed: [String] = []
        for scan in scans.compactMap({ $0 }) {
            let h = scan.host
            let label = "\(h.name) (\(HostTrust.knownHostsName(h, settings: ssh)))"
            guard let state = scan.state else {
                Console.err("✘ \(label): \(scan.error ?? "nie udało się odczytać klucza")")
                code = ExitCode.failure
                continue
            }
            let keys = scan.keys.map { "\($0.type) \($0.fingerprint)" }.joined(separator: ", ")
            switch state {
            case .trusted:
                Console.out("✔ \(label): \(keys) – zaufany")
            case .new:
                Console.out("? \(label): \(keys) – nowy klucz")
                candidates.append(scan)
            case .changed(let previous):
                Console.out("⚠ \(label): \(keys) – KLUCZ SIĘ ZMIENIŁ (poprzednio: "
                            + previous.map { "\($0.type) \($0.fingerprint)" }.joined(separator: ", ") + ")")
                candidates.append(scan)
                changed.append(h.name)
            }
        }
        if args.has("--dry-run") || candidates.isEmpty {
            if candidates.isEmpty && code == ExitCode.success { Console.err("Nic do zaufania – wszystkie klucze są już zaufane.") }
            return code
        }
        if !changed.isEmpty {
            Console.err("Uwaga: zmieniony klucz (\(changed.joined(separator: ", "))) oznacza reinstalację lub wymianę iMaca "
                        + "– albo urządzenie, które się pod niego podszywa. Zaufaj tylko, jeśli wiesz, dlaczego się zmienił.")
        }
        Console.err("Odcisk można porównać przy iMacu: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub")
        confirm("Zaufać kluczom: \(candidates.map(\.host.name).joined(separator: ", "))?")
        for scan in candidates {
            let r = await HostTrust.trust(scan, settings: ssh)
            if r.succeeded {
                Console.out("✔ \(scan.host.name): zaufano")
            } else {
                Console.err("✘ \(scan.host.name): \(r.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))")
                code = ExitCode.failure
            }
        }
        return code
    }
}
