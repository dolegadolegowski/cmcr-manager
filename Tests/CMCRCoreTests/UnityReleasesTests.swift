import Foundation
import Testing
@testable import CMCRCore

// Unity Release API answers trimmed to the fields CMCR reads (shape and values as served for 6000.6 in Nov 2026).

private func release(_ version: String, _ rev: String, stream: String = "SUPPORTED", date: String = "2026-11-03T16:15:27.205Z",
                     editor: Int64 = 5_000_000_000, android: Int64 = 1_800_000_000) -> String {
    func download(_ arch: String, _ extra: Int64) -> String {
        """
        {"platform": "MAC_OS", "architecture": "\(arch)", "type": "PKG",
         "downloadSize": {"value": \(editor + extra), "unit": "BYTE"}, "installedSize": {"value": 10213404000, "unit": "BYTE"},
         "modules": [
          {"id": "android", "downloadSize": {"value": \(android), "unit": "BYTE"}, "installedSize": {"value": 5000000, "unit": "KILOBYTE"},
           "subModules": [
            {"id": "android-open-jdk-17.0.18+8", "downloadSize": {"value": 100, "unit": "MEGABYTE"},
             "installedSize": {"value": 200, "unit": "MEGABYTE"}, "subModules": []},
            {"id": "android-sdk-ndk-tools", "downloadSize": {"value": 166, "unit": "BYTE"}, "installedSize": {"value": 1, "unit": "BYTE"},
             "subModules": [{"id": "android-ndk-r27c", "downloadSize": {"value": 1, "unit": "GIGABYTE"},
                             "installedSize": {"value": 2.5, "unit": "GIGABYTE"}}]}
           ]},
          {"id": "ios", "downloadSize": {"value": 874332753, "unit": "BYTE"}, "installedSize": {"value": 2000000000, "unit": "BYTE"}}
         ]}
        """
    }
    return """
    {"version": "\(version)", "shortRevision": "\(rev)", "releaseDate": "\(date)", "stream": "\(stream)",
     "downloads": [\(download("ARM64", 0)), \(download("X86_64", 30_000_000))]}
    """
}

private func page(_ releases: String...) -> Data {
    Data(#"{"offset": 0, "limit": 10, "total": \#(releases.count), "results": [\#(releases.joined(separator: ","))]}"#.utf8)
}

@Test func unityVersionInputTellsLinesFromVersions() {
    #expect(UnityVersionInput("6000.6") == .line("6000.6"))
    #expect(UnityVersionInput(" 2022.3 ") == .line("2022.3"))
    #expect(UnityVersionInput("6000.6.8f1") == .exact("6000.6.8f1"))
    #expect(UnityVersionInput("6000.7.0b7") == .exact("6000.7.0b7"))
    #expect(UnityVersionInput("6000.0.85f2") == .exact("6000.0.85f2"))
    for bad in ["", "6000", "6000.6.", "6000.6.8", "6.6", "6000.6.8f1; rm -rf ~", "latest", "6000.6.8F1"] {
        #expect(UnityVersionInput(bad) == nil, "\(bad)")
    }
    #expect(UnityReleases.isFinal("6000.6.8f1") && !UnityReleases.isFinal("6000.6.0b10") && !UnityReleases.isFinal("6000.6.0a7"))
    #expect(UnityReleases.isChangeset("237b6593792b") && !UnityReleases.isChangeset("237B6593792B") && !UnityReleases.isChangeset("237b659379"))
    #expect(UnityReleases.isModuleID("android-open-jdk-17.0.18+8") && UnityReleases.isModuleID("mac-il2cpp"))
    #expect(!UnityReleases.isModuleID("-m") && !UnityReleases.isModuleID("Android") && !UnityReleases.isModuleID("a b"))
}

@Test func unityQueryAsksForFinalReleasesOfALine() throws {
    let line = try #require(URLComponents(url: UnityReleases.queryURL(for: .line("6000.6")), resolvingAgainstBaseURL: false))
    #expect(line.host == "services.api.unity.com")
    let items = line.queryItems ?? []
    #expect(items.contains(URLQueryItem(name: "version", value: "6000.6")))
    #expect(items.contains(URLQueryItem(name: "platform", value: "MAC_OS")))
    #expect(items.filter { $0.name == "stream" }.compactMap(\.value) == ["LTS", "SUPPORTED", "TECH"])
    #expect(items.contains(URLQueryItem(name: "order", value: "RELEASE_DATE_DESC")))
    let exact = try #require(URLComponents(url: UnityReleases.queryURL(for: .exact("6000.6.8f1")), resolvingAgainstBaseURL: false))
    #expect(exact.queryItems?.contains(URLQueryItem(name: "version", value: "6000.6.8f1")) == true)
    #expect(exact.queryItems?.contains { $0.name == "stream" } == false)
}

@Test func unityLineResolvesToItsNewestFinalRelease() throws {
    // Out of order, with a beta and a release of another line that the version filter of the API would not return.
    let data = page(release("6000.6.7f1", "b22767f04f04", date: "2026-10-21T10:00:00Z"),
                    release("6000.6.0b10", "0625e1538ccf", stream: "BETA"),
                    release("6000.6.8f1", "237b6593792b"),
                    release("6000.60.9f1", "aaaaaaaaaaaa"),
                    release("6000.6.10f1", "nothex"))
    #expect(throws: UnityReleaseError.invalidResponse("changeset „nothex” wersji 6000.6.10f1")) {
        try UnityReleases.parse(data, for: .line("6000.6"))
    }
    let r = try UnityReleases.parse(page(release("6000.6.7f1", "b22767f04f04"), release("6000.6.0b10", "0625e1538ccf", stream: "BETA"),
                                         release("6000.6.8f1", "237b6593792b"), release("6000.60.9f1", "aaaaaaaaaaaa")),
                                    for: .line("6000.6"))
    #expect(r.version == "6000.6.8f1")
    #expect(r.changeset == "237b6593792b")
    #expect(r.stream == "SUPPORTED")
    let second = try #require(ISO8601DateFormatter().date(from: "2026-11-03T16:15:27Z"))
    #expect(r.releaseDate.map { abs($0.timeIntervalSince(second) - 0.205) < 0.001 } == true)
    #expect(r.editor["arm64"] == UnityRelease.Size(download: 5_000_000_000, installed: 10_213_404_000))
    #expect(r.editor["x86_64"]?.download == 5_030_000_000)
    // android + OpenJDK + SDK & NDK Tools + NDK (a sub-module of a sub-module); KILOBYTE/MEGABYTE/GIGABYTE units.
    #expect(r.modules["arm64"]?["android"] == UnityRelease.Size(download: 1_800_000_000 + 100_000_000 + 166 + 1_000_000_000,
                                                               installed: 5_000_000_000 + 200_000_000 + 1 + 2_500_000_000))
    #expect(r.moduleIDs == ["android", "ios"])
    #expect(r.unknownModules(["ios", "andriod", "webgl"]) == ["andriod", "webgl"])
}

@Test func unityVersionNumbersCompareNumerically() {
    let order = ["6000.6.0a7", "6000.6.0b9", "6000.6.0b10", "6000.6.0f1", "6000.6.2f1", "6000.6.10f1", "6000.6.10f2"]
    for (a, b) in zip(order, order.dropFirst()) {
        #expect(UnityReleases.versionKey(a).lexicographicallyPrecedes(UnityReleases.versionKey(b)), "\(a) < \(b)")
    }
}

@Test func unityLookupErrorsSayWhatIsMissing() throws {
    #expect(throws: UnityReleaseError.noFinalRelease("6000.7")) {
        try UnityReleases.parse(page(release("6000.7.0b7", "0123456789ab", stream: "BETA")), for: .line("6000.7"))
    }
    #expect(throws: UnityReleaseError.notFound("6000.6.99f1")) {
        try UnityReleases.parse(page(release("6000.6.8f1", "237b6593792b")), for: .exact("6000.6.99f1"))
    }
    #expect(throws: UnityReleaseError.self) { try UnityReleases.parse(Data("<html>".utf8), for: .line("6000.6")) }
    #expect(UnityReleaseError.network("offline").isLookupUnavailable && UnityReleaseError.http(503).isLookupUnavailable)
    #expect(UnityReleaseError.rateLimited.isLookupUnavailable)
    #expect(!UnityReleaseError.notFound("x").isLookupUnavailable && !UnityReleaseError.noFinalRelease("x").isLookupUnavailable)
    #expect(UnityReleaseError.noFinalRelease("6000.7").localizedDescription.contains("6000.7"))
}

@Test func unityDiskNeedCoversTheLargerArchitecture() throws {
    let r = try UnityReleases.parse(page(release("6000.6.8f1", "237b6593792b")), for: .exact("6000.6.8f1"))
    let need = r.diskNeed(modules: ["android"])
    // x86_64 downloads 30 MB more: its total wins, rounded up to whole KB.
    #expect(need.editorKB == (5_030_000_000 + 10_213_404_000 + 1023) / 1024)
    #expect(need.modulesKB == ["android": (2_900_000_166 + 7_700_000_001 + 1023) / 1024])
    #expect(r.diskNeed(modules: []).modulesKB.isEmpty)
    let total = r.totalSize(modules: ["android", "ios"])
    #expect(total.download == 5_030_000_000 + 2_900_000_166 + 874_332_753)
}

@Test func unityResolveAsksTheAPIOnce() async throws {
    let seen = LockedURLs()
    let r = try await UnityReleases.resolve(.line("6000.6")) { url in
        seen.append(url)
        return page(release("6000.6.8f1", "237b6593792b"))
    }
    #expect(r.version == "6000.6.8f1")
    #expect(seen.urls == [UnityReleases.queryURL(for: .line("6000.6"))])
}

private final class LockedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [URL] = []
    var urls: [URL] { lock.withLock { list } }
    func append(_ u: URL) { lock.withLock { list.append(u) } }
}

@Test func unityInstallScriptSkipsChecksAndVerifies() {
    let body = Scripts.unityInstallEditor(version: "6000.6.8f1", modules: ["android", "ios"], changeset: "237b6593792b",
                                          diskNeed: UnityDiskNeed(editorKB: 100, modulesKB: ["android": 7, "ios": 3])).body
    #expect(body.contains("V='6000.6.8f1'; CS='237b6593792b'; EDKB=100"))
    #expect(body.contains("MODS=('android' 'ios')"))
    #expect(body.contains("MODKB=(7 3)"))
    #expect(body.contains(#"[ -x "$ED/Unity.app/Contents/MacOS/Unity" ]"#))          // already installed: skip
    #expect(body.contains("set -- install-modules --version \"$V\""))                // …or only the missing modules
    #expect(body.contains(#"[ -n "$CS" ] && set -- "$@" --changeset "$CS""#))
    #expect(body.contains(#"set -- "$@" --architecture "$ARCH""#))
    #expect(body.contains(#"--childModules"#))
    #expect(body.contains(#""$HUB" -- --headless "$@" --errors </dev/null"#))        // --errors after the command
    #expect(body.contains("df -Pk"))
    // Without sizes (Unity could not be asked) nothing is checked: 0 KB.
    let bare = Scripts.unityInstallEditor(version: "6000.3.7f1", modules: []).body
    #expect(bare.contains("CS=''; EDKB=0") && bare.contains("MODS=()") && bare.contains("MODKB=()"))
    #expect(Scripts.unityHub(["editors", "--installed"]).body.contains(#"APPS="${CMCR_APPS_DIR:-/Applications}""#))
}
