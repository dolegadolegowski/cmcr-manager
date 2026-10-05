import Foundation
import Testing
@testable import CMCRCore

@Suite struct HostsFileTests {
    func reason(_ json: String) -> String? {
        do {
            _ = try ConfigStore.decodeHosts(Data(json.utf8))
            return nil
        } catch {
            return (error as? HostsFileError)?.reason ?? "inny błąd: \(error)"
        }
    }

    @Test func validListDecodes() throws {
        let hosts = try ConfigStore.decodeHosts(Data(#"[{"address":"a.local"},{"name":"b","address":"b.local","port":2222}]"#.utf8))
        #expect(hosts.map(\.name) == ["a.local", "b"])
        #expect(hosts[1].port == 2222)
    }

    @Test func describesWhereTheFileIsBroken() {
        #expect(reason(#"[{"address":"a"},{"name":"b","adress":"b"}]"#) == "brak pola „address” (wpis nr 2)")
        #expect(reason(#"[{"address":"a","port":"22"}]"#) == "niepoprawna wartość (wpis nr 1, pole „port”)")
        #expect(reason(#"[{"address":null}]"#)?.hasPrefix("niepoprawna wartość (wpis nr 1") == true)
        #expect(reason(#"{"hosts":[]}"#) == "plik nie zawiera listy komputerów")
        #expect(reason(#"[{"address":"a" "b"}]"#)?.hasPrefix("niepoprawny JSON") == true)
        #expect(reason("")?.hasPrefix("niepoprawny JSON") == true)
    }

    /// The point of `readHostsFile()`: an unreadable file is an error, never the default list that could be saved over it.
    @Test func unreadableFileIsNotTheDefaultList() {
        #expect(throws: HostsFileError.self) { try ConfigStore.decodeHosts(Data("[{\"name\":\"x\"}]".utf8)) }
    }
}
