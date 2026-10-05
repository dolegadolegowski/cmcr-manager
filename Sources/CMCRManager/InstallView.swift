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

    /// Unity Hub module identifiers with the names shown to the teacher.
    static let modules: [(id: String, title: String)] = [
        ("android", "Android"), ("ios", "iOS"), ("webgl", "WebGL"), ("windows-mono", "Windows"),
        ("mac-il2cpp", "macOS"), ("linux-mono", "Linux"), ("visionos", "visionOS"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TargetHeader(section: .install,
                         subtitle: "Instalowanie nowych aplikacji na zaznaczonych komputerach – z plików na tym Macu, z internetu lub z Homebrew.")
                .alignedWithGroupedForm()
                .padding([.horizontal, .top], 20)
            Form {
                localSection
                urlSection
                brewSection
                unitySection
                if let batch = model.lastBatch[.install] {
                    Section {
                        BatchResultsView(batch: batch)
                    } header: {
                        Label("Wynik ostatniej operacji", systemImage: "list.bullet.rectangle")
                    }
                    .id(batch.id)
                }
            }
            .formStyle(.grouped)
        }
        .groupedFormPageBackground()
        .confirmation($confirm)
    }

    // MARK: From files on this Mac

    var localSection: some View {
        Section {
            FileListEditor(items: $model.installItems,
                           placeholder: "Przeciągnij tutaj instalatory (.pkg, .dmg, .zip) lub aplikacje (.app) albo użyj „Dodaj…”.")
            HStack(spacing: 12) {
                Text("Aplikacje trafią do folderu Programy na każdym komputerze.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(".pkg → instalator systemowy, .dmg → zamontowanie i instalacja pakietu lub skopiowanie aplikacji, .zip → rozpakowanie, .app → skopiowanie do /Applications (z usunięciem kwarantanny). Instalacja z uprawnieniami administratora.")
                Spacer(minLength: 12)
                TargetButton(title: "Wyślij i zainstaluj", icon: "square.and.arrow.down.on.square.fill") {
                    model.installPackages(model.installItems, on: model.selectedMachines)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.installItems.isEmpty)
            }
        } header: {
            Label("Z plików na tym Macu", systemImage: "shippingbox")
        }
    }

    // MARK: From a web address

    var urlSection: some View {
        Section {
            TextField("Adres instalatora", text: $downloadURL, prompt: Text("https://…/Instalator.pkg"))
            HStack(spacing: 12) {
                Text("Każdy komputer pobierze plik sam – wygodne przy dużych instalatorach (.pkg, .dmg lub .zip).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                TargetButton(title: "Pobierz i zainstaluj", icon: "arrow.down.app") {
                    let url = downloadURL
                    model.runScript("Instalacja z URL: \((url as NSString).lastPathComponent)", on: model.selectedMachines) { _ in
                        Scripts.installFromURL(url)
                    }
                }
                .disabled(URL(string: downloadURL)?.scheme?.hasPrefix("http") != true)
            }
        } header: {
            Label("Z internetu", systemImage: "link")
        }
    }

    // MARK: Homebrew

    var brewArguments: String {
        brewName.split(separator: " ").map { shQuote(String($0)) }.joined(separator: " ")
    }

    var brewSection: some View {
        Section {
            TextField("Nazwa pakietu", text: $brewName, prompt: Text("np. google-chrome, visual-studio-code"))
                .help("Nazwy pakietów Homebrew, oddzielone spacjami (np. google-chrome, visual-studio-code, unity-hub, oracle-jdk)")
            Picker(selection: $brewCask) {
                Text("Aplikacja").tag(true)
                Text("Narzędzie Terminala").tag(false)
            } label: {
                Text("Rodzaj")
                Text("Programy z oknem, np. przeglądarki, to „Aplikacja”.")
            }
            .pickerStyle(.segmented)
            .help("„Aplikacja” instaluje pakiet --cask, „Narzędzie Terminala” – zwykłą formułę Homebrew.")
            HStack(spacing: 10) {
                TargetButton(title: "Odinstaluj…", icon: "trash", role: .destructive, prominent: false) {
                    let args = "uninstall \(brewCask ? "--cask " : "")\(brewArguments)"
                    confirm = ConfirmRequest(
                        title: "Odinstalować „\(brewName)” (Homebrew)?",
                        message: "Pakiet zostanie usunięty \(Polish.onComputers(model.actionTargets.count)).",
                        button: "Odinstaluj") {
                        model.runScript("brew \(args)", on: model.selectedMachines) { _ in Scripts.brew(args) }
                    }
                }
                .disabled(brewName.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer(minLength: 12)
                TargetButton(title: "Zainstaluj pakiet", icon: "plus.circle") {
                    let args = "install \(brewCask ? "--cask " : "")\(brewArguments)"
                    model.runScript("brew \(args)", on: model.selectedMachines) { _ in Scripts.brew(args) }
                }
                .disabled(brewName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            FormActionRow("Przygotowanie komputerów",
                          caption: "Homebrew trzeba zainstalować raz na każdym komputerze. Java (Oracle JDK) – z Homebrew.") {
                TargetButton(title: "Zainstaluj Homebrew", icon: "hammer", prominent: false) {
                    model.runScript("Instalacja Homebrew", on: model.selectedMachines) { _ in Scripts.installHomebrew() }
                }
                TargetButton(title: "Zainstaluj Javę", icon: "cup.and.saucer", prominent: false) {
                    model.runScript("brew install oracle-jdk", on: model.selectedMachines) { _ in Scripts.brew("install oracle-jdk") }
                }
            }
        } header: {
            Label("Homebrew – katalog darmowych programów", systemImage: "mug")
        }
    }

    // MARK: Unity

    var unitySection: some View {
        Section {
            TextField("Wersja edytora Unity", text: $unityVersion, prompt: Text("6000.3.7f1"))
                .font(.body.monospacedDigit())
            LabeledContent {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), alignment: .leading)], alignment: .leading,
                          spacing: 6) {
                    ForEach(Self.modules, id: \.id) { module in
                        Toggle(module.title, isOn: Binding(
                            get: { unityModules.contains(module.id) },
                            set: { if $0 { unityModules.insert(module.id) } else { unityModules.remove(module.id) } }))
                            .toggleStyle(.checkbox)
                            .help("Moduł Unity: \(module.id)")
                    }
                }
                .frame(maxWidth: 440)
            } label: {
                Text("Moduły")
                Text("Platformy, na które uczniowie będą budować gry.")
            }
            FormActionRow("Edytor Unity",
                          caption: "Instaluje edytor w podanej wersji razem z zaznaczonymi modułami.") {
                TargetButton(title: "Pokaż zainstalowane", icon: "list.bullet", prominent: false) {
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
            }
            FormActionRow("Moduły do zainstalowanego edytora",
                          caption: "Dodaje zaznaczone moduły, gdy edytor w tej wersji już jest na komputerach.") {
                TargetButton(title: "Dodaj moduły", icon: "plus.square", prominent: false) {
                    let v = unityVersion
                    let mods = Array(unityModules).sorted()
                    model.runScript("Unity \(v): moduły \(mods.joined(separator: ","))", on: model.selectedMachines) { _ in
                        Scripts.unityInstallModules(version: v, modules: mods)
                    }
                }
                .disabled(unityModules.isEmpty || unityVersion.isEmpty)
            }
            TextField(text: $androidAPIs, prompt: Text("32, 34")) {
                Text("Wersje Android API")
                Text("Numery oddzielone przecinkami.")
            }
            .font(.body.monospacedDigit())
            FormActionRow("Android SDK",
                          caption: "Narzędzia do budowania gier na Androida – w podanych wersjach API, dla edytora Unity z modułem Android.") {
                TargetButton(title: "Zainstaluj Android SDK", icon: "iphone.gen2", prominent: false) {
                    let v = unityVersion
                    let apis = androidAPIs.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                    model.runScript("sdkmanager API \(apis.joined(separator: ","))", on: model.selectedMachines) { _ in
                        Scripts.androidSDK(unityVersion: v, apiLevels: apis)
                    }
                }
                .disabled(androidAPIs.isEmpty)
            }
        } header: {
            Label("Unity Hub i Android SDK", systemImage: "cube")
        } footer: {
            FormSectionNote("Instalacje Unity trwają długo – postęp widać w dziale Zadania. Wcześniej zainstaluj Unity Hub (Homebrew: pakiet unity-hub).")
        }
    }
}
