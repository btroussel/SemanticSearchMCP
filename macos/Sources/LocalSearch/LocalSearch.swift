import SwiftUI
import AppKit
import Combine

struct Source: Decodable, Identifiable {
    let id, name, path, phase: String
    let kinds, excludes: [String]
    let files, chunks: Int
    let error: String?
    let last_sync: SyncStats?
    var phaseLabel: String {
        switch phase { case "ready": return L10n.string("phase.ready"); case "indexing": return L10n.string("phase.indexing"); case "error": return L10n.string("phase.error"); default: return L10n.string("phase.starting") }
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
    let duplicates: [Duplicate]?
    let duplicates_omitted: Int?
    let rawID: String
    var id: String { source_id + ":" + rawID }
    var url: URL { URL(fileURLWithPath: source_path).appendingPathComponent(path) }
    var copyCount: Int { (duplicates?.count ?? 0) + (duplicates_omitted ?? 0) }
    enum CodingKeys: String, CodingKey {
        case source_id, source_name, source_path, path, symbol, kind, asset_kind, code, start_line, end_line, cosine, line_origin, parent_id, duplicates, duplicates_omitted
        case rawID = "id"
    }
}
struct Duplicate: Decodable, Hashable { let source_id, path: String }
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
    @Published var setupNeeded = false
    @Published var setupRunning = false
    @Published var setupStep = ""
    @Published var setupFraction: Double?
    @Published var setupError: String?
    var process: Process?
    var setupProcess: Process?
    var setupCancelled = false
    var timer: Timer?
    // LOCAL_SEARCH_STATE and LOCAL_SEARCH_PORT isolate experiments from the live state and service.
    let state = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCAL_SEARCH_STATE"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Local Search").path)
    let port = ProcessInfo.processInfo.environment["LOCAL_SEARCH_PORT"] ?? "8766"
    var base: String { "http://127.0.0.1:\(port)" }
    var runtime: URL { state.appendingPathComponent("runtime") }
    var setupLog: URL { state.appendingPathComponent("setup.log") }
    var defaultModel: URL { state.appendingPathComponent("models/embeddinggemma-2") }
    var modelChoice: URL { state.appendingPathComponent("model-path") }
    var backend: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("backend"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("uv").path) else { return nil }
        return url
    }
    var devCommand: String? { Bundle.main.object(forInfoDictionaryKey: "SearchServiceExecutable") as? String }
    var command: String { devCommand ?? runtime.appendingPathComponent("venv/bin/code-search").path }
    var model: String {
        if let chosen = try? String(contentsOf: modelChoice, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !chosen.isEmpty { return chosen }
        return Bundle.main.object(forInfoDictionaryKey: "SearchModelPath") as? String ?? defaultModel.path
    }
    var bundleVersion: String? { backend.flatMap { try? String(contentsOf: $0.appendingPathComponent("version"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) } }
    var installedVersion: String? { try? String(contentsOf: runtime.appendingPathComponent("version"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }
    var engineInstalled: Bool { FileManager.default.isExecutableFile(atPath: command) }
    var engineReady: Bool { devCommand != nil ? engineInstalled : engineInstalled && installedVersion == bundleVersion }
    var modelReady: Bool { Self.isModel(URL(fileURLWithPath: model)) }
    var selectedHit: Hit? { results.first { $0.id == selected } }

    static func isModel(_ url: URL) -> Bool {
        ["config.json", "model.safetensors", "tokenizer.json"].allSatisfy { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

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
            throw NSError(domain: "LocalSearch", code: code, userInfo: [NSLocalizedDescriptionKey: value?["detail"] as? String ?? L10n.string("service.response", code)])
        }
        return data
    }
    func start() async {
        if (try? await request("/status")) != nil { setupNeeded = false; await refresh(); return }
        guard devCommand != nil || backend != nil else {
            error = L10n.string("service.missing")
            return
        }
        guard engineReady, modelReady else { setupNeeded = true; return }
        setupNeeded = false
        do {
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let logURL = state.appendingPathComponent("service.log")
            if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
            let log = try FileHandle(forWritingTo: logURL)
            try log.seekToEnd()
            let child = Process()
            child.executableURL = URL(fileURLWithPath: command)
            child.arguments = ["workspace", "--model", model, "--state", state.path, "--port", port]
            child.standardOutput = log
            child.standardError = log
            child.terminationHandler = { process in
                Task { @MainActor in
                    if process.terminationStatus != 0 { SearchStore.shared.error = L10n.string("service.stopped", logURL.path) }
                }
            }
            try child.run()
            process = child
            for _ in 0..<40 {
                if (try? await request("/status")) != nil { await refresh(); error = nil; return }
                try await Task.sleep(for: .milliseconds(250))
            }
            error = L10n.string("service.starting")
        } catch { self.error = error.localizedDescription }
    }

    // First-launch setup: bundled uv installs Python and hash-locked libraries into runtime/,
    // then the engine downloads the pinned model. Both steps resume or restart safely.
    func install() async {
        setupRunning = true; setupError = nil; setupCancelled = false; setupFraction = nil
        defer { setupRunning = false; setupProcess = nil; setupStep = "" }
        do {
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let needed = Int64(engineReady ? 0 : 2_000_000_000) + Int64(modelReady ? 0 : 1_600_000_000)
            if let free = try state.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage, free < needed {
                throw NSError(domain: "LocalSearch", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.string("setup.diskSpace", needed / 1_000_000_000 + 1, Int64(free / 1_000_000_000))])
            }
            if !engineReady { try await installEngine() }
            if !modelReady { try await downloadModel() }
            await start()
        } catch {
            setupError = setupCancelled ? nil : error.localizedDescription
        }
    }
    func installEngine() async throws {
        guard let backend, let version = bundleVersion else { throw NSError(domain: "LocalSearch", code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.string("service.missing")]) }
        let manager = FileManager.default
        let staging = runtime.appendingPathComponent("venv-new"), final = runtime.appendingPathComponent("venv")
        try manager.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? manager.removeItem(at: staging)
        let uv = backend.appendingPathComponent("uv")
        let environment = ["UV_PYTHON_INSTALL_DIR": runtime.appendingPathComponent("python").path,
                           "UV_CACHE_DIR": runtime.appendingPathComponent("cache").path,
                           "UV_PYTHON_PREFERENCE": "only-managed", "UV_NO_CONFIG": "1", "UV_NO_PROGRESS": "1"]
        let python = staging.appendingPathComponent("bin/python").path
        setupStep = L10n.string("setup.step.python")
        try await run(uv, ["venv", "--relocatable", "--python", "3.12", staging.path], environment: environment)
        setupStep = L10n.string("setup.step.libraries")
        try await run(uv, ["pip", "install", "--python", python, "--require-hashes", "-r", backend.appendingPathComponent("requirements.txt").path], environment: environment)
        setupStep = L10n.string("setup.step.app")
        guard let wheel = try manager.contentsOfDirectory(atPath: backend.path).first(where: { $0.hasSuffix(".whl") }) else { throw CocoaError(.fileNoSuchFile) }
        try await run(uv, ["pip", "install", "--python", python, "--no-deps", "--reinstall", backend.appendingPathComponent(wheel).path], environment: environment)
        // Downloaded runtimes must not inherit a quarantine flag that would block them from loading.
        try? await run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", staging.path, runtime.appendingPathComponent("python").path])
        if process?.isRunning == true { process?.terminate() }
        try? manager.removeItem(at: final)
        try manager.moveItem(at: staging, to: final)
        try (version + "\n").write(to: runtime.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        try? await run(uv, ["cache", "prune"], environment: environment)
    }
    func downloadModel() async throws {
        setupStep = L10n.string("setup.step.model")
        setupFraction = 0
        try await run(URL(fileURLWithPath: command), ["download-model", "--dest", defaultModel.path, "--json"]) { line in
            guard let data = line.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let done = value["downloaded"] as? Double, let total = value["total"] as? Double, total > 0 else { return }
            self.setupFraction = done / total
            self.setupStep = L10n.string("setup.step.modelProgress", done / 1e9, total / 1e9)
        }
        if model != defaultModel.path { try (defaultModel.path + "\n").write(to: modelChoice, atomically: true, encoding: .utf8) }
    }
    func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:], onLine: ((String) -> Void)? = nil) async throws {
        if setupCancelled { throw CancellationError() }
        let manager = FileManager.default
        if !manager.fileExists(atPath: setupLog.path) { manager.createFile(atPath: setupLog.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let log = try FileHandle(forWritingTo: setupLog)
        try log.seekToEnd()
        log.write(Data("\n$ \(executable.lastPathComponent) \(arguments.joined(separator: " "))\n".utf8))
        let child = Process(), output = Pipe(), errors = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        child.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        child.standardOutput = output
        child.standardError = errors
        let tail = Task.detached { () -> [String] in
            var lines: [String] = []
            for try await line in errors.fileHandleForReading.bytes.lines {
                log.write(Data((line + "\n").utf8))
                lines.append(line); if lines.count > 8 { lines.removeFirst() }
            }
            return lines
        }
        let progress = Task.detached {
            for try await line in output.fileHandleForReading.bytes.lines {
                if let onLine { await MainActor.run { onLine(line) } } else { log.write(Data((line + "\n").utf8)) }
            }
        }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            child.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try child.run(); setupProcess = child } catch { continuation.resume(throwing: error) }
        }
        setupProcess = nil
        // A cancelled step may leave grandchildren holding the pipes open; don't wait for them.
        if setupCancelled { throw CancellationError() }
        _ = try? await progress.value
        let lines = (try? await tail.value) ?? []
        try? log.close()
        guard status == 0 else {
            let reason = lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "exit status \(status)"
            throw NSError(domain: "LocalSearch", code: Int(status), userInfo: [NSLocalizedDescriptionKey: L10n.string("setup.failed", reason)])
        }
    }
    func cancelSetup() { setupCancelled = true; if setupProcess?.isRunning == true { setupProcess?.terminate() } }
    func chooseModelFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("setup.model.panel")
        panel.prompt = L10n.string("setup.model.panelPrompt")
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url?.resolvingSymlinksInPath() else { return }
        guard Self.isModel(url) else {
            setupError = L10n.string("setup.model.invalid")
            return
        }
        do {
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try (url.path + "\n").write(to: modelChoice, atomically: true, encoding: .utf8)
            setupError = nil
            objectWillChange.send()
        } catch { setupError = error.localizedDescription }
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
            else if !reply.stale_paths.isEmpty { error = L10n.string("search.stale") }
        } catch { self.error = error.localizedDescription }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("folder.authorize.title")
        panel.prompt = L10n.string("action.choose")
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
    func shutdown() {
        timer?.invalidate()
        cancelSetup()
        if process?.isRunning == true { process?.terminate() }
    }
    func connectionCommand(_ client: String, project: String = "") -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let prefix = client == "codex" ? "codex mcp add local-search -- " : "claude mcp add --scope user --transport stdio local-search -- "
        return prefix + quote(command) + " mcp --general --url \(base) --token-file " + quote(state.appendingPathComponent("access.key").path) + (project.isEmpty ? "" : " --project " + quote(project))
    }
}

struct SetupView: View {
    @ObservedObject var store = SearchStore.shared
    var updating: Bool { store.engineInstalled && !store.engineReady && store.modelReady }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "sparkle.magnifyingglass").font(.system(size: 38)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string(updating ? "setup.updated" : "setup.welcome")).font(.largeTitle.bold())
                    Text(L10n.string("setup.tagline")).foregroundStyle(.secondary)
                }
            }
            Text(L10n.string(updating ? "setup.updateIntro" : "setup.intro"))
            VStack(spacing: 0) {
                row(icon: "shippingbox", title: L10n.string("setup.engine"), detail: L10n.string("setup.engine.detail"), ready: store.engineReady)
                Divider().padding(.leading, 52)
                row(icon: "cpu", title: L10n.string("setup.model"), detail: store.model == store.defaultModel.path || !store.modelReady ? L10n.string("setup.model.detail") : store.model, ready: store.modelReady) {
                    if !store.modelReady && !store.setupRunning { Button(L10n.string("setup.model.choose")) { store.chooseModelFolder() }.buttonStyle(.link).font(.caption) }
                }
            }.background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            if store.setupRunning {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.setupStep).font(.callout)
                    if let fraction = store.setupFraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                }
            }
            if let error = store.setupError { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                if FileManager.default.fileExists(atPath: store.setupLog.path) {
                    Button(L10n.string("setup.showLog")) { NSWorkspace.shared.open(store.setupLog) }
                }
                Spacer()
                if store.setupRunning { Button(L10n.string("action.cancel")) { store.cancelSetup() } }
                else {
                    Button(L10n.string(store.setupError != nil ? "setup.retry" : updating ? "setup.update" : store.engineReady ? "setup.downloadModel" : "setup.install")) { Task { await store.install() } }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                }
            }
            Text(L10n.string("setup.footer"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(40).frame(maxWidth: 640).frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minWidth: 1020, minHeight: 650)
    }
    func row(icon: String, title: String, detail: String, ready: Bool, @ViewBuilder extra: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(Color.accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                extra()
            }
            Spacer()
            if ready { Label(L10n.string("setup.ready"), systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout) }
        }.padding(14)
    }
}

struct RootView: View {
    @ObservedObject var store = SearchStore.shared
    var body: some View { if store.setupNeeded { SetupView() } else { MainView() } }
}

struct MainView: View {
    @ObservedObject var store = SearchStore.shared
    @ObservedObject var localization = AppLocalization.shared
    @FocusState var searchFocus: Bool
    @State var removing: Source?
    @State var managing: Source?
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkle.magnifyingglass").font(.system(size: 27)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading) { Text("Local Search").font(.title3.bold()); Text(L10n.string("app.tagline")).font(.caption).foregroundStyle(.secondary) }
                }.padding(.top, 14)
                Button { store.sourceID = "" } label: { Label(L10n.string("source.all"), systemImage: "square.stack.3d.up") }.buttonStyle(.plain)
                HStack { Text(L10n.string("source.authorized")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary); Spacer(); Button { store.chooseFolder() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help(L10n.string("action.addFolder")) }
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
                                            Text(L10n.string("source.status", source.phaseLabel, L10n.string("count.files", source.files))).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }.padding(10).background(store.sourceID == source.id ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain).contextMenu {
                                Text(source.path)
                                Text(source.kinds.map { L10n.assetKind($0) }.joined(separator: ", "))
                                if let error = source.error { Text(error) }
                                Button(L10n.string("action.manageAccess.more")) { managing = source }
                                Button(L10n.string("action.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)]) }
                                Button(L10n.string("action.revoke.more"), role: .destructive) { removing = source }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                Divider()
                SettingsLink { Label(L10n.string("settings.title"), systemImage: "gearshape") }.buttonStyle(.plain)
                Button { store.showConnections = true } label: { Label(L10n.string("assistant.connect"), systemImage: "point.3.connected.trianglepath.dotted") }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 5) {
                    Label(L10n.string("index.local"), systemImage: "lock.shield").font(.caption.bold())
                    Text(L10n.string("source.status", L10n.string("count.items", store.status?.chunks ?? 0), store.status?.device.uppercased() ?? L10n.string("index.starting"))).font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(18).frame(minWidth: 230).background(Color(nsColor: .windowBackgroundColor))
        } detail: {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text(L10n.string("search.heading")).font(.system(size: 22, weight: .semibold)); Spacer() }
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(L10n.string("search.placeholder"), text: $store.query).textFieldStyle(.plain).focused($searchFocus).onSubmit { Task { await store.search() } }
                        if store.busy { ProgressView().controlSize(.small) }
                        Button(L10n.string("action.search")) { Task { await store.search() } }.buttonStyle(.borderedProminent).disabled(store.busy || store.query.isEmpty)
                    }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
                    HStack {
                        Picker(L10n.string("search.type"), selection: $store.assetKind) {
                            Text(L10n.string("type.all")).tag(""); Text(L10n.string("type.code")).tag("code"); Text(L10n.string("type.documents")).tag("documents"); Text(L10n.string("type.images")).tag("images")
                        }.pickerStyle(.segmented).frame(maxWidth: 390)
                        Spacer()
                        if let latency = store.latency { Text(L10n.string("search.summary", L10n.string("count.results", store.results.count), Int(latency))).font(.caption).foregroundStyle(.secondary) }
                    }
                    if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                }.padding(24)
                Divider()
                if store.status?.sources.isEmpty ?? true {
                    ContentUnavailableView {
                        Label(L10n.string("source.empty.title"), systemImage: "folder.badge.plus")
                    } description: {
                        Text(L10n.string("source.empty.description"))
                    } actions: { Button(L10n.string("action.addFolder")) { store.chooseFolder() }.buttonStyle(.borderedProminent) }
                } else if store.results.isEmpty {
                    ContentUnavailableView {
                        Label(store.latency == nil ? L10n.string("search.empty.title") : L10n.string("search.noResults.title"), systemImage: "sparkle.magnifyingglass")
                    } description: {
                        Text(store.latency == nil ? L10n.string("search.examples") : L10n.string("search.noResults.description"))
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
                        else { Text(L10n.string("search.selectResult")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }
                }
            }.background(Color(nsColor: .textBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1020, minHeight: 650)
        .toolbar {
            ToolbarItemGroup {
                if let source = store.status?.sources.first(where: { $0.id == store.sourceID }) {
                    Button { managing = source } label: { Label(L10n.string("action.manageAccess"), systemImage: "slider.horizontal.3") }
                }
                Button { store.chooseFolder() } label: { Label(L10n.string("action.add"), systemImage: "folder.badge.plus") }
                Button { Task { await store.reindex() } } label: { Label(L10n.string("action.refresh"), systemImage: "arrow.clockwise") }
                Button { store.showConnections = true } label: { Label("MCP", systemImage: "point.3.connected.trianglepath.dotted") }
            }
        }
        .sheet(isPresented: $store.showConnections) { ConnectionsView() }
        .sheet(item: $managing) { source in
            VStack(alignment: .leading, spacing: 18) {
                Text(source.name).font(.title2.bold())
                Text(source.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text(L10n.string("source.types", source.kinds.map { L10n.assetKind($0) }.joined(separator: ", ")))
                Text(L10n.string("source.summary", source.phaseLabel, L10n.string("count.files", source.files), L10n.string("count.items", source.chunks))).foregroundStyle(.secondary)
                if !source.excludes.isEmpty { Text(L10n.string("source.exclusions") + "\n" + source.excludes.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                if let error = source.error { Text(error).font(.caption).foregroundStyle(.orange) }
                if let skipped = source.last_sync?.skipped_files, !skipped.isEmpty {
                    Text(L10n.string("count.unreadableFiles", skipped.count)).font(.headline)
                    ScrollView { Text(skipped.prefix(10).map { "\($0.path) : \($0.error)" }.joined(separator: "\n")).font(.caption).textSelection(.enabled) }.frame(maxHeight: 120)
                }
                Text(L10n.string("source.changeHelp")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L10n.string("action.revoke.more"), role: .destructive) { managing = nil; removing = source }
                    Spacer(); Button(L10n.string("action.close")) { managing = nil }.keyboardShortcut(.cancelAction)
                }
            }.padding(28).frame(width: 550)
        }
        .sheet(isPresented: Binding(get: { store.addingPath != nil }, set: { if !$0 { store.addingPath = nil } })) { if let path = store.addingPath { AddSourceView(path: path) } }
        .alert(L10n.string("source.revoke.title"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L10n.string("action.cancel"), role: .cancel) { removing = nil }
            Button(L10n.string("action.remove"), role: .destructive) { if let source = removing { Task { await store.remove(source) } }; removing = nil }
        } message: { Text(L10n.string("source.revoke.description")) }
        .onAppear { searchFocus = true }
        .background(Button("") { searchFocus = true }.keyboardShortcut("k").hidden())
    }
}

struct AddSourceView: View {
    let path: URL
    @ObservedObject var store = SearchStore.shared
    @ObservedObject var localization = AppLocalization.shared
    @State var name = ""
    @State var code = true
    @State var documents = true
    @State var images = true
    @State var excludes = ""
    @State var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("folder.authorize")).font(.title2.bold())
            Text(path.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
            TextField(L10n.string("source.name"), text: $name).textFieldStyle(.roundedBorder)
            HStack(spacing: 25) {
                Toggle(L10n.string("type.code"), isOn: $code); Toggle(L10n.string("type.documents"), isOn: $documents)
                Toggle(L10n.string("type.images"), isOn: $images).disabled(!(store.status?.image_search ?? false))
            }
            if !(store.status?.image_search ?? false) {
                Text(L10n.string("source.enableImages")).font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.string("source.extraExclusions")).font(.headline)
            Text(L10n.string("source.exclusionsHelp")).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $excludes).font(.system(.body, design: .monospaced)).frame(height: 100).border(Color.secondary.opacity(0.25))
            Text(L10n.string("source.scopeHelp")).font(.caption).foregroundStyle(.secondary)
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer(); Button(L10n.string("action.cancel")) { store.addingPath = nil }
                Button(saving ? L10n.string("action.adding") : L10n.string("action.authorizeIndex")) {
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
    @ObservedObject var localization = AppLocalization.shared
    @State var image: NSImage?
    @State var text = ""
    @State var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(hit.symbol).font(.headline).lineLimit(2); Spacer(); Button { NSWorkspace.shared.activateFileViewerSelecting([hit.url]) } label: { Image(systemName: "folder") }.help(L10n.string("action.reveal")) }
            Text("\(hit.source_name) / \(hit.path)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            if hit.copyCount > 0 {
                Label(L10n.string("count.copies", hit.copyCount), systemImage: "doc.on.doc").font(.caption2).foregroundStyle(.secondary)
                    .help((hit.duplicates ?? []).map(\.path).joined(separator: "\n"))
            }
            if hit.asset_kind != "images" { Text(hit.line_origin == "extracted_text" ? L10n.string("preview.extractedLines", hit.start_line, hit.end_line) : L10n.string("preview.lines", hit.start_line, hit.end_line)).font(.caption2).foregroundStyle(.secondary) }
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
    @ObservedObject var localization = AppLocalization.shared
    @State var options = ModelOptions()
    @State var loaded = false
    @State var saving = false
    @State var saved = false
    @State var error: String?
    var imageSources: Bool { store.status?.sources.contains { $0.kinds.contains("images") } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("settings.title")).font(.title2.bold())
            Form {
                Section(L10n.string("settings.languageSection")) {
                    Picker(L10n.string("settings.language"), selection: $localization.language) {
                        Text(L10n.string("settings.languageSystem")).tag("")
                        ForEach(localization.supportedLanguages, id: \.self) { language in
                            Text(localization.name(for: language)).tag(language)
                        }
                    }
                    Text(L10n.string("settings.languageHelp")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.string("settings.compute")) {
                    Picker(L10n.string("settings.precision"), selection: $options.precision) {
                        Text(L10n.string("settings.float32")).tag("float32")
                        Text(L10n.string("settings.bfloat16")).tag("bfloat16")
                    }
                    Text(L10n.string("settings.precisionHelp")).font(.caption).foregroundStyle(.secondary)
                    Picker(L10n.string("settings.dimensions"), selection: $options.dimensions) {
                        Text(L10n.string("settings.dimensions768")).tag(768)
                        Text(L10n.string("settings.dimensions512")).tag(512)
                        Text(L10n.string("settings.dimensions256")).tag(256)
                        Text(L10n.string("settings.dimensions128")).tag(128)
                    }
                    Text(L10n.string("settings.dimensionsHelp")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(L10n.string("settings.textTokens"))
                        Spacer()
                        TextField("4096", value: $options.max_tokens, format: .number.grouping(.never))
                            .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 100)
                    }
                    Text(L10n.string("settings.textTokensHelp")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.string("type.images")) {
                    Toggle(L10n.string("settings.loadImages"), isOn: $options.images)
                        .disabled(!options.image_encoder_available || imageSources)
                    Text(imageSources ? L10n.string("settings.imageSourcesHelp") : options.image_encoder_available ? L10n.string("settings.textOnlyHelp") : L10n.string("settings.textOnlyServiceHelp"))
                        .font(.caption).foregroundStyle(.secondary)
                    Picker(L10n.string("settings.imageDetail"), selection: $options.image_tokens) {
                        Text(L10n.string("settings.image70")).tag(70)
                        Text(L10n.string("settings.image140")).tag(140)
                        Text(L10n.string("settings.image280")).tag(280)
                        Text(L10n.string("settings.image560")).tag(560)
                        Text(L10n.string("settings.image1120")).tag(1120)
                    }.disabled(!options.images)
                    Text(L10n.string("settings.imageDetailHelp")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.string("settings.search")) {
                    Picker(L10n.string("settings.queryType"), selection: $options.query_task) {
                        Text(L10n.string("settings.queryAuto")).tag("auto")
                        Text(L10n.string("settings.queryCode")).tag("code")
                        Text(L10n.string("settings.querySearch")).tag("search")
                        Text(L10n.string("settings.queryQA")).tag("question_answering")
                        Text(L10n.string("settings.queryFacts")).tag("fact_checking")
                    }
                    Text(L10n.string("settings.queryHelp")).font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            Text(L10n.string("settings.rebuildHelp")).font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if saved { Text(L10n.string("settings.saved")).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button(L10n.string("action.defaults")) {
                    let available = options.image_encoder_available
                    options = ModelOptions(); options.image_encoder_available = available; options.images = available
                }.disabled(!loaded)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(L10n.string("action.save")) {
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
                        ? L10n.string("service.oldVersion")
                        : error.localizedDescription
                }
            }
            .onChange(of: options) { saved = false; error = nil }
    }
}

struct ConnectionsView: View {
    @ObservedObject var store = SearchStore.shared
    @ObservedObject var localization = AppLocalization.shared
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
        panel.title = title; panel.prompt = L10n.string("action.choose")
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
            Text(L10n.string("assistant.heading")).font(.title2.bold())
            Picker(L10n.string("assistant.picker"), selection: $tab) {
                Text(L10n.string("assistant.connection")).tag("connection"); Text(L10n.string("assistant.projectAccess")).tag("access")
            }.pickerStyle(.segmented)
            Text(L10n.string("assistant.scopeHelp")).foregroundStyle(.secondary)
            HStack {
                Text(project.isEmpty ? L10n.string("assistant.launchProject") : project)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                Spacer()
                Button(L10n.string("assistant.chooseProject")) {
                    if let path = chooseFolder(title: L10n.string("assistant.chooseProject.title")) {
                        project = path; copied = ""; Task { await loadAccess() }
                    }
                }.disabled(saving || loading)
            }
            if tab == "connection" {
                Text(L10n.string("assistant.commandsHelp")).font(.callout).foregroundStyle(.secondary)
                ForEach(["codex", "claude"], id: \.self) { client in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(client == "codex" ? "Codex" : "Claude Code").font(.headline); Spacer(); Button(copied == client ? L10n.string("action.copied") : L10n.string("action.copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.connectionCommand(client, project: project), forType: .string); copied = client } }
                        Text(store.connectionCommand(client, project: project)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }.padding(15).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
                if !project.isEmpty { Button(L10n.string("assistant.useLaunchFolder")) { project = ""; folders = []; copied = ""; error = nil; saved = false } }
            } else {
                Text(L10n.string("assistant.extraFolders")).font(.headline)
                Text(L10n.string("assistant.extraFoldersHelp")).font(.caption).foregroundStyle(.secondary)
                if loading { ProgressView().controlSize(.small) }
                else if folders.isEmpty { Text(L10n.string("assistant.projectOnly")).font(.callout).foregroundStyle(.secondary) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(folders, id: \.self) { path in
                            HStack {
                                Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                Spacer()
                                Button(L10n.string("action.remove")) { folders.removeAll { $0 == path }; saved = false; error = nil }.disabled(saving)
                            }
                        }
                    }
                }.frame(maxHeight: 150)
                HStack {
                    Button(L10n.string("action.addFolder.more")) {
                        if let path = chooseFolder(title: L10n.string("assistant.authorizeFolder.title")), !folders.contains(path) {
                            folders.append(path); saved = false; error = nil
                        }
                    }
                    Spacer()
                    Button(saving ? L10n.string("action.saving") : L10n.string("assistant.saveAccess")) {
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
                if saved { Text(L10n.string("assistant.accessSaved")).font(.caption).foregroundStyle(.secondary) }
                if project.isEmpty { Text(L10n.string("assistant.chooseProjectFirst")).font(.caption).foregroundStyle(.secondary) }
            }
            Text(L10n.string("assistant.privacyHelp")).font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button(L10n.string("action.close")) { store.showConnections = false }.keyboardShortcut(.cancelAction) }
        }.padding(28).frame(width: 670).task { await loadAccess() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var languageSubscription: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Local Search")
        languageSubscription = AppLocalization.shared.$language
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.updateMenu() }
        updateMenu()
        NSApp.activate(ignoringOtherApps: true)
    }
    func updateMenu() {
        let menu = NSMenu()
        let show = NSMenuItem(title: L10n.string("menu.open"), action: #selector(showWindow), keyEquivalent: "")
        show.target = self; menu.addItem(show)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.string("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
    @objc func showWindow() { NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { SearchStore.shared.shutdown() }
}

@main
struct LocalSearchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var localization = AppLocalization.shared
    var body: some Scene {
        Window("Local Search", id: "main") { RootView().environment(\.locale, localization.locale).tint(Color(red: 0.12, green: 0.40, blue: 0.35)) }
            .defaultSize(width: 1180, height: 760)
            .commands { CommandGroup(after: .newItem) { Button(L10n.string("action.addFolder.more")) { SearchStore.shared.chooseFolder() }.keyboardShortcut("o") } }
        Settings { SettingsView().environment(\.locale, localization.locale).tint(Color(red: 0.12, green: 0.40, blue: 0.35)) }
    }
}
