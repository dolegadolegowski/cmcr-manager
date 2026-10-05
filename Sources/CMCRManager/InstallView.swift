import CMCRCore
import SwiftUI
import UniformTypeIdentifiers

struct InstallView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var downloadURL = ""
    @ViewState private var brewName = ""
    @ViewState private var brewCask = true
    @ViewState private var unityVersion = "6000.3.7f1"
    @ViewState private var unityModules: Set<String> = ["android"]
    @ViewState private var androidAPIs = "32, 34"
    @ViewState private var confirm: ConfirmRequest?

    static let modules = ["android", "ios", "webgl", "windows-mono", "mac-il2cpp", "linux-mono", "visionos"]

    var body: some View {
        Page {
            TargetHeader(section: .install,
                         subtitle: "Wgrywanie i instalacja nowych aplikacji na zaznaczonych iMacach (jako root).")
            Toggle("Zezwól na instalatory bez podpisu i notaryzacji Apple (tylko z zaufanego źródła, np. przygotowane w szkole)",
                   isOn: $model.installAllowUnsigned)
            localBox
            urlBox
            brewBox
            unityBox
            LastBatchView(section: .install)
        }
        .confirmation($confirm)
    }

    var localBox: some View {
        SectionBox(title: "Z plików na tym Macu", icon: "shippingbox") {
            FileListEditor(items: $model.installItems,
                           placeholder: "Przeciągnij instalatory: .pkg, .dmg, .zip lub pakiety .app.")
            Text(".pkg → installer, .dmg → montowanie i instalacja pakietu lub kopiowanie .app, .zip → rozpakowanie, .app → kopiowanie do /Applications (z usunięciem kwarantanny).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TargetButton(title: "Wyślij i zainstaluj", icon: "square.and.arrow.down.on.square.fill") {
                model.installPackages(model.installItems, on: model.selectedMachines)
            }
            .disabled(model.installItems.isEmpty)
        }
    }

    var urlBox: some View {
        SectionBox(title: "Z adresu URL (pobieranie bezpośrednio na iMacach)", icon: "link") {
            HStack {
                TextField("https://…/Instalator.pkg lub .dmg/.zip", text: $downloadURL)
                TargetButton(title: "Pobierz i zainstaluj", icon: "arrow.down.app") {
                    let url = downloadURL, allowUnsigned = model.installAllowUnsigned
                    model.runScript("Instalacja z URL: \((url as NSString).lastPathComponent)", on: model.selectedMachines) { _ in
                        Scripts.installFromURL(url, allowUnsigned: allowUnsigned)
                    }
                }
                .disabled(!Scripts.isSecureDownloadURL(downloadURL))
            }
            Text("Przydatne dla dużych instalatorów – każdy iMac pobiera plik sam, bez przesyłania przez ten komputer. Tylko adresy https://.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    var brewBox: some View {
        SectionBox(title: "Homebrew (notes.md)", icon: "mug") {
            HStack {
                TextField("Nazwa pakietu, np. google-chrome, visual-studio-code, unity-hub, oracle-jdk", text: $brewName)
                Toggle("Aplikacja (--cask)", isOn: $brewCask)
            }
            HStack {
                TargetButton(title: "Zainstaluj", icon: "plus.circle") {
                    let args = "install \(brewCask ? "--cask " : "")\(brewName.split(separator: " ").map { shQuote(String($0)) }.joined(separator: " "))"
                    model.runScript("brew \(args)", on: model.selectedMachines) { _ in Scripts.brew(args) }
                }
                .disabled(brewName.isEmpty)
                TargetButton(title: "Odinstaluj", icon: "minus.circle", role: .destructive, prominent: false) {
                    let args = "uninstall \(brewCask ? "--cask " : "")\(brewName.split(separator: " ").map { shQuote(String($0)) }.joined(separator: " "))"
                    confirm = ConfirmRequest(
                        title: "Odinstalować „\(brewName)” (Homebrew)?",
                        message: "Pakiet zostanie usunięty \(Polish.onComputers(model.actionTargets.count)).",
                        button: "Odinstaluj") {
                        model.runScript("brew \(args)", on: model.selectedMachines) { _ in Scripts.brew(args) }
                    }
                }
                .disabled(brewName.isEmpty)
                Spacer()
                TargetButton(title: "Zainstaluj Homebrew", icon: "hammer", prominent: false) {
                    model.runScript("Instalacja Homebrew", on: model.selectedMachines) { _ in Scripts.installHomebrew() }
                }
                TargetButton(title: "Oracle JDK", icon: "cup.and.saucer", prominent: false) {
                    model.runScript("brew install oracle-jdk", on: model.selectedMachines) { _ in Scripts.brew("install oracle-jdk") }
                }
            }
        }
    }

    var unityBox: some View {
        SectionBox(title: "Unity Hub i Android SDK (notes.md)", icon: "cube") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Wersja edytora")
                    TextField("6000.3.7f1", text: $unityVersion).frame(maxWidth: 160).font(.body.monospaced())
                }
                GridRow {
                    Text("Moduły")
                    HStack {
                        ForEach(Self.modules, id: \.self) { mod in
                            Toggle(mod, isOn: Binding(
                                get: { unityModules.contains(mod) },
                                set: { if $0 { unityModules.insert(mod) } else { unityModules.remove(mod) } }))
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                GridRow {
                    Text("Android API")
                    TextField("32, 34", text: $androidAPIs).frame(maxWidth: 160).font(.body.monospaced())
                }
            }
            HStack {
                TargetButton(title: "Edytory", icon: "list.bullet", prominent: false) {
                    model.runScript("Unity Hub: editors --all", on: model.selectedMachines) { _ in
                        Scripts.unityHub(["editors", "--all"])
                    }
                }
                TargetButton(title: "Zainstaluj edytor", icon: "square.and.arrow.down") {
                    let v = unityVersion
                    let mods = Array(unityModules).sorted()
                    model.runScript("Unity \(v) + \(mods.joined(separator: ","))", on: model.selectedMachines) { _ in
                        Scripts.unityInstallEditor(version: v, modules: mods)
                    }
                }
                .disabled(unityVersion.isEmpty)
                TargetButton(title: "Dodaj moduły", icon: "plus.square", prominent: false) {
                    let v = unityVersion
                    let mods = Array(unityModules).sorted()
                    model.runScript("Unity \(v): moduły \(mods.joined(separator: ","))", on: model.selectedMachines) { _ in
                        Scripts.unityInstallModules(version: v, modules: mods)
                    }
                }
                .disabled(unityModules.isEmpty || unityVersion.isEmpty)
                TargetButton(title: "Android SDK", icon: "iphone.gen2", prominent: false) {
                    let v = unityVersion
                    let apis = androidAPIs.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                    model.runScript("sdkmanager API \(apis.joined(separator: ","))", on: model.selectedMachines) { _ in
                        Scripts.androidSDK(unityVersion: v, apiLevels: apis)
                    }
                }
                .disabled(androidAPIs.isEmpty)
            }
            Text("Instalacje Unity trwają długo – postęp widać w „Zadaniach”. Unity Hub musi być wcześniej zainstalowany (np. brew install --cask unity-hub).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
