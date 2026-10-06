import SwiftUI
import AppKit

struct Source: Decodable, Identifiable {
    let id, name, path, phase: String
    let kinds, excludes: [String]
    let files, chunks: Int
    let error: String?
    let last_sync: SyncStats?
    var phaseLabel: String {
        switch phase { case "ready": return "À jour"; case "indexing": return "Indexation…"; case "error": return "Erreur"; default: return "Démarrage…" }
    }
}
struct SyncStats: Decodable { let skipped_files: [SkippedFile]? }
struct SkippedFile: Decodable { let path, error: String }
struct ServiceStatus: Decodable {
    let sources: [Source]
    let files, chunks: Int
    let device: String
    let model_loaded, image_search: Bool
    let max_tokens: Int
}
struct Hit: Decodable, Identifiable, Hashable {
    let source_id, source_name, source_path, path, symbol, kind, asset_kind, code: String
    let start_line, end_line: Int
    let cosine: Double?
    let line_origin: String
    let parent_id: String?
    let rawID: String
    var id: String { source_id + ":" + rawID }
    var url: URL { URL(fileURLWithPath: source_path).appendingPathComponent(path) }
    enum CodingKeys: String, CodingKey {
        case source_id, source_name, source_path, path, symbol, kind, asset_kind, code, start_line, end_line, cosine, line_origin, parent_id
        case rawID = "id"
    }
}
struct SearchReply: Decodable {
    let results: [Hit]
    let elapsed_ms: Double
    let issues: [SearchIssue]
    let stale_paths: [StalePath]
}
struct SearchIssue: Decodable { let source_id, error: String }
struct StalePath: Decodable { let source_id, path: String }
struct FileReply: Decodable { let code: String }
struct ModelOptions: Decodable, Equatable {
    var max_tokens = 4096
    var dimensions = 768
    var precision = "float32"
    var images = true
    var image_tokens = 280
    var query_task = "auto"
    var image_encoder_available = true
    var body: [String: Any] {
        ["max_tokens": max_tokens, "dimensions": dimensions, "precision": precision,
         "images": images, "image_tokens": image_tokens, "query_task": query_task]
    }
}
struct MCPAccess: Decodable { let project: String; let folders: [String] }

@MainActor
final class SearchStore: ObservableObject {
    static let shared = SearchStore()
    @Published var status: ServiceStatus?
    @Published var query = ""
    @Published var sourceID = ""
    @Published var assetKind = ""
    @Published var results: [Hit] = []
    @Published var selected: String?
    @Published var busy = false
    @Published var error: String?
    @Published var latency: Double?
    @Published var showConnections = false
    @Published var addingPath: URL?
    var process: Process?
    var timer: Timer?
    let state = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Local Search")
    let base = "http://127.0.0.1:8766"
    var command: String { Bundle.main.object(forInfoDictionaryKey: "SearchServiceExecutable") as? String ?? "" }
    var model: String { Bundle.main.object(forInfoDictionaryKey: "SearchModelPath") as? String ?? "" }
    var selectedHit: Hit? { results.first { $0.id == selected } }

    init() {
        Task { await start() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in await SearchStore.shared.refresh(silent: true) }
        }
    }
    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, params: [String: String] = [:]) async throws -> Data {
        let key = try String(contentsOf: state.appendingPathComponent("access.key"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: base + path)!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.timeoutInterval = 120
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw NSError(domain: "LocalSearch", code: code, userInfo: [NSLocalizedDescriptionKey: value?["detail"] as? String ?? "Le service a retourné \(code)"])
        }
        return data
    }
    func start() async {
        if (try? await request("/status")) != nil { await refresh(); return }
        guard FileManager.default.isExecutableFile(atPath: command), !model.isEmpty else {
            error = "Le moteur local est introuvable. Reconstruis l’application avec scripts/build-mac-app.py."
            return
        }
        do {
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let logURL = state.appendingPathComponent("service.log")
            if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
            let log = try FileHandle(forWritingTo: logURL)
            try log.seekToEnd()
            let child = Process()
            child.executableURL = URL(fileURLWithPath: command)
            child.arguments = ["workspace", "--model", model, "--state", state.path]
            child.standardOutput = log
            child.standardError = log
            child.terminationHandler = { process in
                Task { @MainActor in
                    if process.terminationStatus != 0 { SearchStore.shared.error = "Le moteur s’est arrêté. Consulte \(logURL.path)." }
                }
            }
            try child.run()
            process = child
            for _ in 0..<40 {
                if (try? await request("/status")) != nil { await refresh(); error = nil; return }
                try await Task.sleep(for: .milliseconds(250))
            }
            error = "Le moteur démarre encore. Son état sera actualisé automatiquement."
        } catch { self.error = error.localizedDescription }
    }
    func refresh(silent: Bool = false) async {
        do {
            let data = try await request("/status")
            status = try JSONDecoder().decode(ServiceStatus.self, from: data)
            if !sourceID.isEmpty && !(status?.sources.contains { $0.id == sourceID } ?? false) { sourceID = "" }
        } catch { if !silent { self.error = error.localizedDescription } }
    }
    func search() async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let data = try await request("/search", method: "POST", body: ["query": query, "source_id": sourceID, "asset_kind": assetKind, "limit": 20, "max_chars": 45000])
            let reply = try JSONDecoder().decode(SearchReply.self, from: data)
            results = reply.results; selected = results.first?.id; latency = reply.elapsed_ms
            if let issue = reply.issues.first { error = issue.error }
            else if !reply.stale_paths.isEmpty { error = "Certains fichiers viennent de changer. Relance la recherche après leur indexation." }
        } catch { self.error = error.localizedDescription }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Autoriser un dossier pour Local Search"
        panel.prompt = "Choisir"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { addingPath = panel.url }
    }
    func add(path: URL, name: String, kinds: [String], excludes: String) async -> Bool {
        do {
            _ = try await request("/sources", method: "POST", body: ["path": path.path, "name": name, "kinds": kinds,
                                  "excludes": excludes.split(separator: "\n").map(String.init).filter { !$0.isEmpty }])
            error = nil; await refresh(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func remove(_ source: Source) async {
        do {
            _ = try await request("/sources/\(source.id)", method: "DELETE")
            results.removeAll { $0.source_id == source.id }; selected = nil
            if sourceID == source.id { sourceID = "" }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func reindex() async {
        do { _ = try await request("/reindex", method: "POST", params: ["source_id": sourceID]); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func saveSettings(_ options: ModelOptions) async -> Bool {
        do {
            _ = try await request("/settings", method: "PUT", body: options.body)
            results = []; selected = nil; latency = nil; error = nil
            await refresh()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func shutdown() { timer?.invalidate(); if process?.isRunning == true { process?.terminate() } }
    func connectionCommand(_ client: String, project: String = "") -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let prefix = client == "codex" ? "codex mcp add local-search -- " : "claude mcp add --scope user --transport stdio local-search -- "
        return prefix + quote(command) + " mcp --general --url \(base) --token-file " + quote(state.appendingPathComponent("access.key").path) + (project.isEmpty ? "" : " --project " + quote(project))
    }
}

struct MainView: View {
    @ObservedObject var store = SearchStore.shared
    @FocusState var searchFocus: Bool
    @State var removing: Source?
    @State var managing: Source?
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkle.magnifyingglass").font(.system(size: 27)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading) { Text("Local Search").font(.title3.bold()); Text("Votre Mac, retrouvé.").font(.caption).foregroundStyle(.secondary) }
                }.padding(.top, 14)
                Button { store.sourceID = "" } label: { Label("Toutes les sources", systemImage: "square.stack.3d.up") }.buttonStyle(.plain)
                HStack { Text("DOSSIERS AUTORISÉS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary); Spacer(); Button { store.chooseFolder() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("Ajouter un dossier") }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.status?.sources ?? []) { source in
                            Button { store.sourceID = source.id } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: "folder").foregroundStyle(Color.accentColor).padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(source.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        HStack(spacing: 5) {
                                            Circle().fill(source.phase == "ready" ? Color.green : source.phase == "error" ? .red : .orange).frame(width: 5, height: 5)
                                            Text("\(source.phaseLabel) · \(source.files) fichiers").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }.padding(10).background(store.sourceID == source.id ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain).contextMenu {
                                Text(source.path)
                                Text(source.kinds.joined(separator: ", "))
                                if let error = source.error { Text(error) }
                                Button("Gérer l’accès…") { managing = source }
                                Button("Révéler dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)]) }
                                Button("Retirer l’accès…", role: .destructive) { removing = source }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                Divider()
                SettingsLink { Label("Réglages", systemImage: "gearshape") }.buttonStyle(.plain)
                Button { store.showConnections = true } label: { Label("Connecter un assistant", systemImage: "point.3.connected.trianglepath.dotted") }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 5) {
                    Label("Indexation locale", systemImage: "lock.shield").font(.caption.bold())
                    Text("\(store.status?.chunks ?? 0) éléments · \(store.status?.device.uppercased() ?? "DÉMARRAGE")").font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(18).frame(minWidth: 230).background(Color(nsColor: .windowBackgroundColor))
        } detail: {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("Retrouvez ce que vous avez en tête.").font(.system(size: 22, weight: .semibold)); Spacer() }
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Une fonction, un document, une image…", text: $store.query).textFieldStyle(.plain).focused($searchFocus).onSubmit { Task { await store.search() } }
                        if store.busy { ProgressView().controlSize(.small) }
                        Button("Rechercher") { Task { await store.search() } }.buttonStyle(.borderedProminent).disabled(store.busy || store.query.isEmpty)
                    }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
                    HStack {
                        Picker("Type", selection: $store.assetKind) {
                            Text("Tout").tag(""); Text("Code").tag("code"); Text("Documents").tag("documents"); Text("Images").tag("images")
                        }.pickerStyle(.segmented).frame(maxWidth: 390)
                        Spacer()
                        if let latency = store.latency { Text("\(store.results.count) résultats · \(Int(latency)) ms").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                }.padding(24)
                Divider()
                if store.status?.sources.isEmpty ?? true {
                    ContentUnavailableView {
                        Label("Choisissez où chercher", systemImage: "folder.badge.plus")
                    } description: {
                        Text("Autorisez un dossier et choisissez le code, les documents ou les images à indexer. Vous pourrez retirer cet accès à tout moment.")
                    } actions: { Button("Ajouter un dossier") { store.chooseFolder() }.buttonStyle(.borderedProminent) }
                } else if store.results.isEmpty {
                    ContentUnavailableView {
                        Label(store.latency == nil ? "Cherchez avec vos mots" : "Aucun résultat", systemImage: "sparkle.magnifyingglass")
                    } description: {
                        Text(store.latency == nil ? "« Où est gérée l’authentification ? »\n« Le compte rendu de réunion »\n« Une capture avec un graphique bleu »" : "Essayez une autre description ou vérifiez que l’indexation est terminée.")
                    }
                } else {
                    HSplitView {
                        List(selection: $store.selected) {
                            ForEach(store.results) { hit in
                                HStack(alignment: .top, spacing: 11) {
                                    Image(systemName: hit.asset_kind == "images" ? "photo" : hit.asset_kind == "code" ? "chevron.left.forwardslash.chevron.right" : "doc.text").foregroundStyle(Color.accentColor).frame(width: 20).padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(hit.symbol).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                        Text(hit.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                                        Text(hit.source_name).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 8).tag(hit.id)
                            }
                        }.listStyle(.inset).frame(minWidth: 260, idealWidth: 310)
                        if let hit = store.selectedHit { ResultDetail(hit: hit).id(hit.id).frame(minWidth: 320) }
                        else { Text("Sélectionnez un résultat").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }
                }
            }.background(Color(nsColor: .textBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1020, minHeight: 650)
        .toolbar {
            ToolbarItemGroup {
                if let source = store.status?.sources.first(where: { $0.id == store.sourceID }) {
                    Button { managing = source } label: { Label("Gérer l’accès", systemImage: "slider.horizontal.3") }
                }
                Button { store.chooseFolder() } label: { Label("Ajouter", systemImage: "folder.badge.plus") }
                Button { Task { await store.reindex() } } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
                Button { store.showConnections = true } label: { Label("MCP", systemImage: "point.3.connected.trianglepath.dotted") }
            }
        }
        .sheet(isPresented: $store.showConnections) { ConnectionsView() }
        .sheet(item: $managing) { source in
            VStack(alignment: .leading, spacing: 18) {
                Text(source.name).font(.title2.bold())
                Text(source.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("Types autorisés : \(source.kinds.map { $0 == "code" ? "code" : $0 == "images" ? "images" : "documents" }.joined(separator: ", "))")
                Text("\(source.phaseLabel) · \(source.files) fichiers · \(source.chunks) éléments").foregroundStyle(.secondary)
                if !source.excludes.isEmpty { Text("Exclusions\n" + source.excludes.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                if let error = source.error { Text(error).font(.caption).foregroundStyle(.orange) }
                if let skipped = source.last_sync?.skipped_files, !skipped.isEmpty {
                    Text("\(skipped.count) fichiers n’ont pas pu être lus").font(.headline)
                    ScrollView { Text(skipped.prefix(10).map { "\($0.path) : \($0.error)" }.joined(separator: "\n")).font(.caption).textSelection(.enabled) }.frame(maxHeight: 120)
                }
                Text("Pour modifier les types ou les exclusions, retirez cette source puis ajoutez-la avec les nouveaux réglages.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Retirer l’accès…", role: .destructive) { managing = nil; removing = source }
                    Spacer(); Button("Fermer") { managing = nil }.keyboardShortcut(.cancelAction)
                }
            }.padding(28).frame(width: 550)
        }
        .sheet(isPresented: Binding(get: { store.addingPath != nil }, set: { if !$0 { store.addingPath = nil } })) { if let path = store.addingPath { AddSourceView(path: path) } }
        .alert("Retirer l’accès à ce dossier ?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Annuler", role: .cancel) { removing = nil }
            Button("Retirer", role: .destructive) { if let source = removing { Task { await store.remove(source) } }; removing = nil }
        } message: { Text("Les fichiers restent en place. L’accès MCP sera révoqué et les données de l’index seront supprimées.") }
        .onAppear { searchFocus = true }
        .background(Button("") { searchFocus = true }.keyboardShortcut("k").hidden())
    }
}

struct AddSourceView: View {
    let path: URL
    @ObservedObject var store = SearchStore.shared
    @State var name = ""
    @State var code = true
    @State var documents = true
    @State var images = true
    @State var excludes = ""
    @State var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Autoriser un dossier").font(.title2.bold())
            Text(path.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
            TextField("Nom de la source", text: $name).textFieldStyle(.roundedBorder)
            HStack(spacing: 25) {
                Toggle("Code", isOn: $code); Toggle("Documents", isOn: $documents)
                Toggle("Images", isOn: $images).disabled(!(store.status?.image_search ?? false))
            }
            if !(store.status?.image_search ?? false) {
                Text("Activez l’encodage des images dans Réglages pour autoriser ce type.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Exclusions supplémentaires").font(.headline)
            Text("Un motif par ligne, par exemple archives/ ou **/confidentiel/**. Les fichiers ignorés par Git, les secrets .env et les liens symboliques sont déjà exclus.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $excludes).font(.system(.body, design: .monospaced)).frame(height: 100).border(Color.secondary.opacity(0.25))
            Text("Ce dossier sera disponible dans l’app. Un assistant reste limité à son projet ; autorisez les dossiers supplémentaires dans Connecter un assistant → Accès par projet.").font(.caption).foregroundStyle(.secondary)
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer(); Button("Annuler") { store.addingPath = nil }
                Button(saving ? "Ajout…" : "Autoriser et indexer") {
                    saving = true
                    Task {
                        let kinds = [(code, "code"), (documents, "documents"), (images, "images")].filter { $0.0 }.map { $0.1 }
                        if await store.add(path: path, name: name, kinds: kinds, excludes: excludes) { store.addingPath = nil }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || !(code || documents || images))
            }
        }.padding(28).frame(width: 560).onAppear { name = path.lastPathComponent; images = store.status?.image_search ?? false; store.error = nil }
    }
}

struct ResultDetail: View {
    let hit: Hit
    @ObservedObject var store = SearchStore.shared
    @State var image: NSImage?
    @State var text = ""
    @State var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(hit.symbol).font(.headline).lineLimit(2); Spacer(); Button { NSWorkspace.shared.activateFileViewerSelecting([hit.url]) } label: { Image(systemName: "folder") }.help("Révéler dans le Finder") }
            Text("\(hit.source_name) / \(hit.path)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            if hit.asset_kind != "images" { Text(hit.line_origin == "extracted_text" ? "Extrait du document · lignes \(hit.start_line)–\(hit.end_line) du texte extrait" : "Lignes \(hit.start_line)–\(hit.end_line)").font(.caption2).foregroundStyle(.secondary) }
            Divider()
            if let error { Text(error).foregroundStyle(.orange).font(.caption) }
            ScrollView([.vertical, .horizontal]) {
                if hit.asset_kind == "images" {
                    if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 650, maxHeight: 600) }
                    else { ProgressView().padding() }
                } else { Text(text.isEmpty ? hit.code : text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
            Spacer(minLength: 0)
        }.padding(22).task {
            do {
                if hit.asset_kind == "images" { image = NSImage(data: try await store.request("/image", params: ["source_id": hit.source_id, "path": hit.path])) }
                else {
                    let data: Data
                    if hit.kind == "block" {
                        data = try await store.request("/symbol/\(hit.rawID)", params: ["source_id": hit.source_id])
                    } else {
                        data = try await store.request("/file", params: ["source_id": hit.source_id, "path": hit.path, "start_line": String(hit.start_line), "max_lines": "120"])
                    }
                    text = try JSONDecoder().decode(FileReply.self, from: data).code
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store = SearchStore.shared
    @State var options = ModelOptions()
    @State var loaded = false
    @State var saving = false
    @State var saved = false
    @State var error: String?
    var imageSources: Bool { store.status?.sources.contains { $0.kinds.contains("images") } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Réglages").font(.title2.bold())
            Form {
                Section("Calcul et index") {
                    Picker("Précision du modèle", selection: $options.precision) {
                        Text("Float32 · valeur par défaut").tag("float32")
                        Text("Bfloat16 · mémoire réduite").tag("bfloat16")
                    }
                    Text("Bfloat16 réduit la mémoire des poids de moitié. Le gain de vitesse dépend du Mac. Float16 n’est pas compatible avec ce modèle.").font(.caption).foregroundStyle(.secondary)
                    Picker("Dimensions des vecteurs", selection: $options.dimensions) {
                        Text("768 · qualité maximale").tag(768)
                        Text("512 · vecteurs 1,5× plus petits").tag(512)
                        Text("256 · vecteurs 3× plus petits").tag(256)
                        Text("128 · vecteurs 6× plus petits").tag(128)
                    }
                    Text("Moins de dimensions réduit le stockage et le travail de comparaison. 128 diminue davantage la qualité, surtout pour les images. Le coût d’encodage reste identique.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Tokens par entrée de texte")
                        Spacer()
                        TextField("4096", value: $options.max_tokens, format: .number.grouping(.never))
                            .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 100)
                    }
                    Text("De 256 à 8192. Défaut : 4096. Les longs textes sont découpés ; une limite plus élevée peut augmenter le temps de calcul et la mémoire.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Images") {
                    Toggle("Charger l’encodeur d’images", isOn: $options.images)
                        .disabled(!options.image_encoder_available || imageSources)
                    Text(imageSources ? "Des sources autorisent les images. Retirez ces sources avant de désactiver leur encodeur ; les fichiers restent en place." : options.image_encoder_available ? "Le mode texte seul consomme moins de mémoire. Les autorisations restent propres à chaque dossier." : "Le service a été lancé en mode texte seul. Relancez-le sans --text-only pour activer les images.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Détail des images", selection: $options.image_tokens) {
                        Text("70 tokens · rapide").tag(70)
                        Text("140 tokens").tag(140)
                        Text("280 tokens · valeur par défaut").tag(280)
                        Text("560 tokens").tag(560)
                        Text("1120 tokens · détaillé").tag(1120)
                    }.disabled(!options.images)
                    Text("Plus de tokens peut améliorer les détails visuels, avec davantage de calcul et de mémoire.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Recherche") {
                    Picker("Type de requête", selection: $options.query_task) {
                        Text("Automatique · selon la source").tag("auto")
                        Text("Recherche de code").tag("code")
                        Text("Recherche de documents et d’images").tag("search")
                        Text("Questions et réponses").tag("question_answering")
                        Text("Vérification de faits").tag("fact_checking")
                    }
                    Text("Adapte le préfixe envoyé au modèle. Automatique utilise le préfixe code pour les sources contenant uniquement du code, et le préfixe recherche pour les autres. Aucun texte n’est généré.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            Text("Les changements de précision, dimensions, limite de texte ou encodage des images reconstruisent les index. Le type de requête s’applique immédiatement sans reconstruire les documents.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if saved { Text("Réglages enregistrés.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Valeurs par défaut") {
                    let available = options.image_encoder_available
                    options = ModelOptions(); options.image_encoder_available = available; options.images = available
                }.disabled(!loaded)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Enregistrer") {
                    saving = true; saved = false; error = nil
                    Task {
                        saved = await store.saveSettings(options)
                        if !saved { error = store.error }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || !loaded || !(256...8192).contains(options.max_tokens))
            }
        }.padding(24).frame(width: 660, height: 780)
            .disabled(saving)
            .task {
                await store.refresh()
                do {
                    options = try JSONDecoder().decode(ModelOptions.self, from: await store.request("/settings"))
                    loaded = true
                } catch {
                    self.error = error is DecodingError
                        ? "Le service utilise une ancienne version. Quittez Local Search et relancez l’application reconstruite."
                        : error.localizedDescription
                }
            }
            .onChange(of: options) { saved = false; error = nil }
    }
}

struct ConnectionsView: View {
    @ObservedObject var store = SearchStore.shared
    @State var copied = ""
    @State var tab = "connection"
    @AppStorage("mcpProjectPath") var project = ""
    @State var folders: [String] = []
    @State var saving = false
    @State var loading = false
    @State var accessLoaded = false
    @State var error: String?
    @State var saved = false

    func chooseFolder(title: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = title; panel.prompt = "Choisir"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.resolvingSymlinksInPath().path : nil
    }
    func loadAccess() async {
        guard !project.isEmpty else { return }
        loading = true; accessLoaded = false; error = nil; saved = false; folders = []
        defer { loading = false }
        do {
            let data = try await store.request("/mcp-access", params: ["project": project])
            folders = try JSONDecoder().decode(MCPAccess.self, from: data).folders
            accessLoaded = true
        } catch { self.error = error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Le même moteur, dans vos assistants.").font(.title2.bold())
            Picker("Assistant", selection: $tab) {
                Text("Connexion").tag("connection"); Text("Accès par projet").tag("access")
            }.pickerStyle(.segmented)
            Text("Par défaut, le MCP cherche uniquement dans le dossier du projet. Les autres dossiers nécessitent une autorisation propre à ce projet.").foregroundStyle(.secondary)
            HStack {
                Text(project.isEmpty ? "Projet : dossier de lancement de l’assistant" : project)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                Spacer()
                Button("Choisir le projet…") {
                    if let path = chooseFolder(title: "Choisir le projet de l’assistant") {
                        project = path; copied = ""; Task { await loadAccess() }
                    }
                }.disabled(saving || loading)
            }
            if tab == "connection" {
                Text("Exécutez ces commandes, puis ouvrez une nouvelle session et vérifiez /mcp. Gardez Local Search ouvert. Le projet choisi est fixé dans la commande ; sans choix, le dossier de lancement est utilisé.").font(.callout).foregroundStyle(.secondary)
                ForEach(["codex", "claude"], id: \.self) { client in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(client == "codex" ? "Codex" : "Claude Code").font(.headline); Spacer(); Button(copied == client ? "Copié" : "Copier") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.connectionCommand(client, project: project), forType: .string); copied = client } }
                        Text(store.connectionCommand(client, project: project)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }.padding(15).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
                if !project.isEmpty { Button("Utiliser le dossier de lancement") { project = ""; folders = []; copied = ""; error = nil; saved = false } }
            } else {
                Text("Dossiers supplémentaires autorisés").font(.headline)
                Text("Choisissez un dossier déjà indexé par l’app, ou un sous-dossier. L’autorisation reste enregistrée pour ce projet. Le MCP les recherche seulement sur demande explicite.").font(.caption).foregroundStyle(.secondary)
                if loading { ProgressView().controlSize(.small) }
                else if folders.isEmpty { Text("Aucun : accès au projet uniquement.").font(.callout).foregroundStyle(.secondary) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(folders, id: \.self) { path in
                            HStack {
                                Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                Spacer()
                                Button("Retirer") { folders.removeAll { $0 == path }; saved = false; error = nil }.disabled(saving)
                            }
                        }
                    }
                }.frame(maxHeight: 150)
                HStack {
                    Button("Ajouter un dossier…") {
                        if let path = chooseFolder(title: "Autoriser un dossier supplémentaire pour ce projet"), !folders.contains(path) {
                            folders.append(path); saved = false; error = nil
                        }
                    }
                    Spacer()
                    Button(saving ? "Enregistrement…" : "Enregistrer les autorisations") {
                        saving = true; error = nil; saved = false
                        Task {
                            do {
                                _ = try await store.request("/mcp-access", method: "PUT", body: ["project": project, "folders": folders])
                                saved = true
                            } catch { self.error = error.localizedDescription }
                            saving = false
                        }
                    }.buttonStyle(.borderedProminent)
                }.disabled(project.isEmpty || saving || loading || !accessLoaded)
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                if saved { Text("Autorisations enregistrées. Les retraits prennent effet immédiatement.").font(.caption).foregroundStyle(.secondary) }
                if project.isEmpty { Text("Choisissez d’abord le projet.").font(.caption).foregroundStyle(.secondary) }
            }
            Text("L’index et le calcul restent sur ce Mac. Les extraits et images lus par un assistant peuvent être envoyés à son fournisseur.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Fermer") { store.showConnections = false }.keyboardShortcut(.cancelAction) }
        }.padding(28).frame(width: 670).task { await loadAccess() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Local Search")
        let menu = NSMenu()
        let show = NSMenuItem(title: "Ouvrir Local Search", action: #selector(showWindow), keyEquivalent: "")
        show.target = self; menu.addItem(show)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quitter Local Search", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showWindow() { NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { SearchStore.shared.shutdown() }
}

@main
struct LocalSearchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("Local Search", id: "main") { MainView().tint(Color(red: 0.12, green: 0.40, blue: 0.35)) }
            .defaultSize(width: 1180, height: 760)
            .commands { CommandGroup(after: .newItem) { Button("Ajouter un dossier…") { SearchStore.shared.chooseFolder() }.keyboardShortcut("o") } }
        Settings { SettingsView().tint(Color(red: 0.12, green: 0.40, blue: 0.35)) }
    }
}
