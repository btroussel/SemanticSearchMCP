import SwiftUI
import AppKit
import Combine

struct Source: Decodable, Identifiable {
    let id, name, path, phase: String
    let kinds, excludes: [String]
    let files, chunks: Int
    let error: String?
    let last_sync: SyncStats?
    let last_success: Double?
    var skippedCount: Int { last_sync?.skipped_files?.count ?? 0 }
    var indexedAt: Date? { (last_sync?.completed_at ?? last_success).map { Date(timeIntervalSince1970: $0) } }
    var phaseLabel: String {
        switch phase { case "ready": return L10n.string("phase.ready"); case "indexing": return L10n.string("phase.indexing"); case "error": return L10n.string("phase.error"); default: return L10n.string("phase.starting") }
    }
}
struct SyncStats: Decodable { let skipped_files: [SkippedFile]?; let completed_at: Double? }
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
    let content_id: String?
    let rawID: String
    var id: String { source_id + ":" + rawID }
    var url: URL { URL(fileURLWithPath: source_path).appendingPathComponent(path) }
    var copyCount: Int { (duplicates?.count ?? 0) + (duplicates_omitted ?? 0) }
    var isImage: Bool { asset_kind == "images" }
    /// Changes when the file content changes, so cached thumbnails never go stale.
    var imageKey: String { [source_id, path, content_id ?? ""].joined(separator: "\u{0}") }
    var title: String { symbol == path ? url.lastPathComponent : symbol }
    var icon: String { isImage ? "photo" : asset_kind == "code" ? "chevron.left.forwardslash.chevron.right" : "doc.text" }
    /// First lines of a code result, without their shared indentation.
    func excerpt(lines count: Int) -> [String] {
        var lines = code.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\t", with: "    ") }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        lines = Array(lines.prefix(count))
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return lines.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }
    }
    /// Document text as one flowing paragraph, without Markdown heading, quote and list marks.
    var prose: String {
        code.split(whereSeparator: \.isNewline).map { line -> String in
            var text = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#>")).trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("- ") || text.hasPrefix("* ") { text.removeFirst(2) }
            return text
        }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var snippet: String { code.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !$0.hasPrefix("#!") } ?? "" }
    enum CodingKeys: String, CodingKey {
        case source_id, source_name, source_path, path, symbol, kind, asset_kind, code, start_line, end_line, cosine, line_origin, parent_id, duplicates, duplicates_omitted, content_id
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
struct FileReply: Decodable { let code: String; let start_line, end_line, total_lines: Int? }
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
    // Changing the scope or type reruns the current search so visible results always match the filters.
    @Published var sourceID = "" { didSet { if sourceID != oldValue { filtersChanged() } } }
    @Published var assetKind = "" { didSet { if assetKind != oldValue { filtersChanged() } } }
    @Published var results: [Hit] = []
    @Published var selected: String?
    @Published var busy = false
    @Published var error: String?
    /// nil until the first status check; false while the engine does not answer.
    @Published var connected: Bool?
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
    var searchGeneration = 0
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
            connected = true
            if !sourceID.isEmpty && !(status?.sources.contains { $0.id == sourceID } ?? false) { sourceID = "" }
        } catch {
            connected = false
            if !silent { self.error = error.localizedDescription }
        }
    }
    func retry() async {
        error = nil
        if process?.isRunning == true { await refresh() } else { await start() }
        if connected != true { await refresh(silent: true) }
    }
    // Each search supersedes the previous one; a slower, older reply never replaces newer results.
    func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searchGeneration += 1
        let generation = searchGeneration
        busy = true; error = nil
        defer { if generation == searchGeneration { busy = false } }
        do {
            let data = try await request("/search", method: "POST", body: ["query": text, "source_id": sourceID, "asset_kind": assetKind, "limit": 20, "max_chars": 45000])
            let reply = try JSONDecoder().decode(SearchReply.self, from: data)
            guard generation == searchGeneration else { return }
            results = reply.results; selected = nil; latency = reply.elapsed_ms
            if let issue = reply.issues.first { error = issue.error }
            else if !reply.stale_paths.isEmpty { error = L10n.string("search.stale") }
        } catch { if generation == searchGeneration { self.error = error.localizedDescription } }
    }
    func clearResults() {
        searchGeneration += 1
        busy = false; results = []; selected = nil; latency = nil
    }
    func filtersChanged() {
        guard latency != nil || busy else { return }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clearResults() } else { Task { await search() } }
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
    func reindex(sourceID: String? = nil) async {
        do { _ = try await request("/reindex", method: "POST", params: ["source_id": sourceID ?? self.sourceID]); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func saveSettings(_ options: ModelOptions) async -> Bool {
        do {
            _ = try await request("/settings", method: "PUT", body: options.body)
            clearResults(); error = nil
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

extension Color {
    /// Brand teal, lightened in dark mode so icons and highlights keep their contrast.
    static let brand = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.38, green: 0.76, blue: 0.67, alpha: 1) : NSColor(red: 0.12, green: 0.40, blue: 0.35, alpha: 1)
    })
}

extension Source {
    func statusColor(connected: Bool?) -> Color {
        guard connected != false else { return .secondary }
        return phase == "ready" ? .green : phase == "error" ? .red : .orange
    }
    func statusLine(connected: Bool?) -> String {
        if connected == false { return L10n.string("phase.offline") }
        if phase == "ready", let date = indexedAt { return L10n.string("source.status", L10n.string("count.files", files), L10n.indexed(date)) }
        return L10n.string("source.status", phaseLabel, L10n.string("count.files", files))
    }
}

func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

struct SetupView: View {
    @ObservedObject var store = SearchStore.shared
    var updating: Bool { store.engineInstalled && !store.engineReady && store.modelReady }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "sparkle.magnifyingglass").font(.system(size: 38)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string(updating ? "setup.updated" : "setup.welcome")).font(.largeTitle.bold())
                    Text(L10n.string("setup.tagline")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(L10n.string(updating ? "setup.updateIntro" : "setup.intro")).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                row(icon: "shippingbox", title: L10n.string("setup.engine"), detail: L10n.string("setup.engine.detail"), ready: store.engineReady)
                Divider().padding(.leading, 52)
                row(icon: "cpu", title: L10n.string("setup.model"), detail: store.model == store.defaultModel.path || !store.modelReady ? L10n.string("setup.model.detail") : store.model, ready: store.modelReady) {
                    if !store.modelReady && !store.setupRunning { Button(L10n.string("setup.model.choose")) { store.chooseModelFolder() }.buttonStyle(.link).font(.caption) }
                }
            }.background(.quinary, in: RoundedRectangle(cornerRadius: 12))
            if store.setupRunning {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.setupStep).font(.callout)
                    if let fraction = store.setupFraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                }
            }
            if let error = store.setupError { Banner(text: error) }
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
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(40).frame(maxWidth: 640).frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minWidth: 960, minHeight: 600)
    }
    func row(icon: String, title: String, detail: String, ready: Bool, @ViewBuilder extra: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 24)
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

/// Inline, selectable warning used for service, search and form errors.
struct Banner: View {
    let text: String
    var dismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let dismiss { Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).foregroundStyle(.secondary).help(L10n.string("action.close")) }
        }
        .font(.callout).padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Search-first window: a centered search on launch, then a column of result cards.
/// The preview opens in an inspector on demand; folder management lives in its own sheet.
struct MainView: View {
    @ObservedObject var store = SearchStore.shared
    @ObservedObject var localization = AppLocalization.shared
    @FocusState var searchFocus: Bool
    @State var showFolders = false
    @State var showScope = false
    var sources: [Source] { store.status?.sources ?? [] }
    var selectedSource: Source? { sources.first { $0.id == store.sourceID } }
    var home: Bool { store.results.isEmpty && store.latency == nil && !store.busy }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .animation(.snappy(duration: 0.25), value: home)
            .inspector(isPresented: Binding(get: { store.selectedHit != nil }, set: { if !$0 { store.selected = nil } })) {
                Group {
                    if let hit = store.selectedHit { ResultDetail(hit: hit).id(hit.id) }
                    else { Color.clear }
                }.inspectorColumnWidth(min: 360, ideal: 480, max: 760)
            }
            .frame(minWidth: 820, minHeight: 560)
            .navigationTitle("Local Search")
            .toolbar {
                ToolbarItem(placement: .navigation) { EngineStatus() }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showFolders = true } label: { Label(L10n.string("source.folders"), systemImage: "folder") }
                        .labelStyle(.titleAndIcon).help(L10n.string("folders.manage"))
                    Button { store.showConnections = true } label: { Label(L10n.string("assistant.connect"), systemImage: "point.3.connected.trianglepath.dotted") }
                        .labelStyle(.titleAndIcon).help(L10n.string("assistant.connect"))
                    SettingsLink { Label(L10n.string("settings.title"), systemImage: "gearshape") }.help(L10n.string("settings.title"))
                }
            }
            .sheet(isPresented: $showFolders) { FoldersView() }
            .sheet(isPresented: $store.showConnections) { ConnectionsView() }
            .sheet(isPresented: Binding(get: { store.addingPath != nil && !showFolders }, set: { if !$0 { store.addingPath = nil } })) {
                if let path = store.addingPath { AddSourceView(path: path) }
            }
            .onAppear { searchFocus = true }
            .background(Button("") { searchFocus = true }.keyboardShortcut("k").hidden())
    }

    @ViewBuilder var content: some View {
        if store.connected == nil {
            ProgressView(L10n.string("engine.starting"))
        } else if store.connected == false && store.status == nil {
            ContentUnavailableView {
                Label(L10n.string("engine.offline.title"), systemImage: "bolt.horizontal.circle")
            } description: {
                Text(L10n.string("engine.offline.description"))
            } actions: {
                Button(L10n.string("action.retry")) { Task { await store.retry() } }.buttonStyle(.borderedProminent)
                Button(L10n.string("setup.showLog")) { NSWorkspace.shared.open(store.state.appendingPathComponent("service.log")) }
            }
        } else if sources.isEmpty {
            ContentUnavailableView {
                Label(L10n.string("source.empty.title"), systemImage: "folder.badge.plus")
            } description: {
                Text(L10n.string("source.empty.description"))
            } actions: { Button(L10n.string("action.addFolder.more")) { store.chooseFolder() }.buttonStyle(.borderedProminent) }
        } else if home {
            hero
        } else {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    searchField(large: false)
                    HStack { filters; Spacer(); summary }
                    if let error = store.error { Banner(text: error) { store.error = nil } }
                }
                .frame(maxWidth: 820).padding(.horizontal, 24).padding(.vertical, 14).frame(maxWidth: .infinity)
                Divider()
                ResultsFeed(showSource: store.sourceID.isEmpty && sources.count > 1)
            }
        }
    }

    var hero: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass").font(.system(size: 46, weight: .light)).foregroundStyle(.tint)
                Text(L10n.string("home.title")).font(.system(size: 30, weight: .semibold))
                Text(L10n.string("home.subtitle")).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(spacing: 14) {
                searchField(large: true)
                filters
                if let error = store.error { Banner(text: error) { store.error = nil } }
            }.frame(maxWidth: 660)
            VStack(spacing: 10) {
                Text(L10n.string("search.try")).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(["search.example1", "search.example2", "search.example3"], id: \.self) { key in
                        Chip(title: L10n.string(key), selected: false) { store.query = L10n.string(key); Task { await store.search() } }
                    }
                }
            }
            Spacer(); Spacer()
        }
        .padding(40)
    }

    func searchField(large: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(large ? .title2 : .title3).foregroundStyle(.secondary)
            TextField(L10n.string("search.placeholder"), text: $store.query)
                .textFieldStyle(.plain).font(large ? .title2 : .title3).focused($searchFocus)
                .onSubmit { Task { await store.search() } }
            if store.busy { ProgressView().controlSize(.small) }
            else if !store.query.isEmpty {
                Button { store.query = ""; store.clearResults(); searchFocus = true } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary).help(L10n.string("search.clear"))
            }
        }
        .padding(.horizontal, large ? 18 : 14).padding(.vertical, large ? 15 : 10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: large ? 16 : 10))
        .overlay(RoundedRectangle(cornerRadius: large ? 16 : 10).strokeBorder(searchFocus ? AnyShapeStyle(.tint.opacity(0.7)) : AnyShapeStyle(Color.primary.opacity(0.12)), lineWidth: searchFocus ? 2 : 1))
        .shadow(color: .black.opacity(large ? 0.08 : 0), radius: 12, y: 4)
    }

    var filters: some View {
        HStack(spacing: 8) {
            Chip(title: selectedSource?.name ?? L10n.string("source.all"), icon: "folder", selected: selectedSource != nil, menu: true) { showScope.toggle() }
                .popover(isPresented: $showScope, arrowEdge: .bottom) { scopePicker }
            Divider().frame(height: 16)
            ForEach([("", "type.all", "square.grid.2x2"), ("code", "type.code", "chevron.left.forwardslash.chevron.right"),
                     ("documents", "type.documents", "doc.text"), ("images", "type.images", "photo")], id: \.0) { kind, key, icon in
                Chip(title: L10n.string(key), icon: icon, selected: store.assetKind == kind) { store.assetKind = kind }
            }
        }
    }

    @ViewBuilder var summary: some View {
        if let latency = store.latency {
            Text(L10n.string("search.summary", L10n.string("count.results", store.results.count), Int(latency)))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    var scopePicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            scopeRow(id: "", title: L10n.string("source.all"), detail: L10n.string("count.files", store.status?.files ?? 0), color: nil)
            Divider().padding(.vertical, 4)
            ForEach(sources) { source in
                scopeRow(id: source.id, title: source.name, detail: source.statusLine(connected: store.connected), color: source.statusColor(connected: store.connected))
            }
            Divider().padding(.vertical, 4)
            Button { showScope = false; showFolders = true } label: {
                Label(L10n.string("folders.manage"), systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(8).frame(width: 300)
    }

    func scopeRow(id: String, title: String, detail: String, color: Color?) -> some View {
        Button { store.sourceID = id; showScope = false } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.tint).opacity(store.sourceID == id ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    HStack(spacing: 5) {
                        if let color { Circle().fill(color).frame(width: 6, height: 6) }
                        Text(detail).lineLimit(1)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// Capsule filter used for scope, types and example queries.
struct Chip: View {
    let title: String
    var icon: String?
    let selected: Bool
    var menu = false
    let action: () -> Void
    @State var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.caption) }
                Text(title).lineLimit(1)
                if menu { Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
            }
            .font(.callout)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .background(selected ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.09 : 0.05)), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(Color.clear)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct EngineStatus: View {
    @ObservedObject var store = SearchStore.shared
    @ObservedObject var localization = AppLocalization.shared
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(store.connected == true ? Color.green : store.connected == false ? .red : .orange).frame(width: 7, height: 7)
            if store.connected == true, let status = store.status {
                Text(L10n.string("source.status", L10n.string("count.items", status.chunks), status.device.uppercased()))
            } else {
                Text(L10n.string(store.connected == false ? "engine.offline" : "engine.connecting"))
            }
            if store.connected == false {
                Button(L10n.string("action.retry")) { Task { await store.retry() } }.controlSize(.small)
            }
        }
        .font(.caption).foregroundStyle(.secondary).fixedSize()
        .padding(.horizontal, 8)
        .help(L10n.string("index.local"))
    }
}

struct ResultsFeed: View {
    let showSource: Bool
    @ObservedObject var store = SearchStore.shared
    var images: [Hit] { store.results.filter(\.isImage) }
    var texts: [Hit] { store.results.filter { !$0.isImage } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if store.results.isEmpty && !store.busy {
                    VStack(spacing: 6) {
                        Text(L10n.string("search.noResults.title")).font(.title3.weight(.semibold))
                        Text(L10n.string("search.noResults.description")).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.top, 60)
                }
                if !images.isEmpty {
                    if !texts.isEmpty { Text(L10n.string("type.images")).font(.headline).padding(.top, 4) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 136, maximum: 200), spacing: 12)], alignment: .leading, spacing: 12) {
                        ForEach(images) { hit in ImageTile(hit: hit, selected: store.selected == hit.id) }
                    }.padding(.bottom, texts.isEmpty ? 0 : 10)
                    if !texts.isEmpty { Text(L10n.string("search.textResults")).font(.headline) }
                }
                ForEach(texts) { hit in ResultCard(hit: hit, selected: store.selected == hit.id, showSource: showSource) }
            }
            .frame(maxWidth: 820).padding(.horizontal, 24).padding(.vertical, 18).frame(maxWidth: .infinity)
        }
    }
}

/// Click selects (and opens the preview); a double-click opens the file.
@MainActor func handleClick(on hit: Hit) {
    if NSApp.currentEvent?.clickCount == 2 { NSWorkspace.shared.open(hit.url) }
    else { SearchStore.shared.selected = SearchStore.shared.selected == hit.id ? nil : hit.id }
}

struct ResultCard: View {
    let hit: Hit
    let selected: Bool
    let showSource: Bool
    @State var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: hit.icon).font(.caption).foregroundStyle(.tint)
                Text(showSource ? "\(hit.source_name) › \(hit.path)" : hit.path)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(L10n.string("preview.lines", hit.start_line, hit.end_line)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
            Text(hit.title).font(.headline).lineLimit(1)
            if hit.asset_kind == "code" {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(hit.excerpt(lines: 4).enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line).lineLimit(1)
                    }
                }
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text(hit.prose).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            if hit.copyCount > 0 {
                Label(L10n.string("count.copies", hit.copyCount), systemImage: "doc.on.doc").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? AnyShapeStyle(.tint.opacity(0.07)) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.03 : 0))))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? AnyShapeStyle(.tint.opacity(0.55)) : AnyShapeStyle(Color.primary.opacity(0.09)), lineWidth: selected ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .onTapGesture { handleClick(on: hit) }
        .contextMenu { HitActions(hit: hit) }
    }
}

struct ImageTile: View {
    let hit: Hit
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Thumbnail(hit: hit)
                .frame(height: 104).frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.1)), lineWidth: selected ? 2.5 : 1))
            Text(hit.title).font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onTapGesture { handleClick(on: hit) }
        .contextMenu { HitActions(hit: hit) }
    }
}

struct HitActions: View {
    let hit: Hit
    var body: some View {
        Button(L10n.string("action.open")) { NSWorkspace.shared.open(hit.url) }
        Button(L10n.string("action.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([hit.url]) }
        Divider()
        Button(L10n.string("action.copyPath")) { copyToPasteboard(hit.url.path) }
        if !hit.isImage { Button(L10n.string("action.copySnippet")) { copyToPasteboard(hit.code) } }
    }
}

/// Image preview loaded from the service, cached for the session by file content.
struct Thumbnail: View {
    let hit: Hit
    @State var image: NSImage?
    @MainActor static var cache: [String: NSImage] = [:]
    var body: some View {
        Rectangle().fill(.tint.opacity(0.08))
            .overlay {
                if let image { Image(nsImage: image).resizable().scaledToFill() }
                else { Image(systemName: "photo").font(.title2).foregroundStyle(.tint.opacity(0.6)) }
            }
            .clipped()
            .task(id: hit.imageKey) {
                if let cached = Self.cache[hit.imageKey] { image = cached; return }
                if let data = try? await SearchStore.shared.request("/image", params: ["source_id": hit.source_id, "path": hit.path]),
                   let loaded = NSImage(data: data) {
                    if Self.cache.count >= 200 { Self.cache.removeAll() }
                    Self.cache[hit.imageKey] = loaded; image = loaded
                }
            }
    }
}

struct FoldersView: View {
    @ObservedObject var store = SearchStore.shared
    @ObservedObject var localization = AppLocalization.shared
    @Environment(\.dismiss) var dismiss
    @State var managing: Source?
    @State var removing: Source?
    var sources: [Source] { store.status?.sources ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "folder").font(.system(size: 28)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("source.folders")).font(.title2.bold())
                    Text(L10n.string("folders.subtitle")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ScrollView {
                VStack(spacing: 0) {
                    if sources.isEmpty {
                        Text(L10n.string("source.empty.description")).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }
                    ForEach(sources) { source in
                        row(source)
                        if source.id != sources.last?.id { Divider().padding(.leading, 50) }
                    }
                }
            }
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button(L10n.string("action.addFolder.more")) { store.chooseFolder() }.buttonStyle(.borderedProminent)
                Spacer()
                Button(L10n.string("action.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 600, height: 400)
        .sheet(item: $managing) { source in SourceDetailsView(source: source, removing: $removing) }
        .sheet(isPresented: Binding(get: { store.addingPath != nil }, set: { if !$0 { store.addingPath = nil } })) {
            if let path = store.addingPath { AddSourceView(path: path) }
        }
        .alert(L10n.string("source.revoke.title"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L10n.string("action.cancel"), role: .cancel) { removing = nil }
            Button(L10n.string("action.remove"), role: .destructive) { if let source = removing { Task { await store.remove(source) } }; removing = nil }
        } message: { Text(L10n.string("source.revoke.description")) }
    }

    func row(_ source: Source) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).fontWeight(.medium).lineLimit(1)
                Text(source.path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    Circle().fill(source.statusColor(connected: store.connected)).frame(width: 6, height: 6)
                    Text(source.statusLine(connected: store.connected)).lineLimit(1)
                    if source.skippedCount > 0 {
                        Label(L10n.string("count.unreadableFiles", source.skippedCount), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).lineLimit(1)
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { Task { await store.reindex(sourceID: source.id) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help(L10n.string("action.refresh")).disabled(store.connected != true)
            Button { managing = source } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless).help(L10n.string("action.manageAccess"))
            Menu {
                Button(L10n.string("action.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)]) }
                Divider()
                Button(L10n.string("action.revoke.more"), role: .destructive) { removing = source }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L10n.string("action.more"))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contextMenu {
            Button(L10n.string("action.manageAccess.more")) { managing = source }
            Button(L10n.string("action.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)]) }
            Divider()
            Button(L10n.string("action.revoke.more"), role: .destructive) { removing = source }
        }
    }
}

struct ResultDetail: View {
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let lineHeight = NSLayoutManager().defaultLineHeight(for: codeFont)
    let hit: Hit
    @ObservedObject var store = SearchStore.shared
    @ObservedObject var localization = AppLocalization.shared
    @State var image: NSImage?
    @State var reply: FileReply?
    @State var loading = false
    @State var error: String?

    var shownLines: Int { reply.map { $0.code.components(separatedBy: "\n").count } ?? 0 }
    var firstLine: Int { reply?.start_line ?? hit.start_line }
    var canShowMore: Bool {
        guard let reply, let end = reply.end_line, let total = reply.total_lines else { return false }
        return (firstLine > 1 || end < total) && shownLines < 300
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Divider()
            if let error { Banner(text: error).padding(12) }
            if hit.isImage { imagePreview } else { textPreview }
            if !hit.isImage, let reply, let end = reply.end_line {
                Divider()
                HStack {
                    Text(L10n.string(hit.line_origin == "extracted_text" ? "preview.extractedRange" : "preview.range", firstLine, end, reply.total_lines ?? end))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    if canShowMore {
                        Button(L10n.string("preview.moreContext")) { Task { await load(start: max(1, firstLine - 40), lines: min(300, shownLines + 120)) } }
                            .controlSize(.small).disabled(loading)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .task { await initialLoad() }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Text(hit.title).font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 8)
                if !hit.isImage {
                    Button { copyToPasteboard(hit.code) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help(L10n.string("action.copySnippet"))
                }
                Menu { HitActions(hit: hit) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L10n.string("action.more"))
                Button(L10n.string("action.open")) { NSWorkspace.shared.open(hit.url) }
                Button { store.selected = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help(L10n.string("action.closePreview"))
            }
            Text("\(hit.source_name) › \(hit.path)").font(.callout).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if hit.copyCount > 0 {
                Label(L10n.string("count.copies", hit.copyCount), systemImage: "doc.on.doc").font(.caption).foregroundStyle(.secondary)
                    .help((hit.duplicates ?? []).map(\.path).joined(separator: "\n"))
            }
        }
    }

    var imagePreview: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .padding(24)
            } else if error == nil { ProgressView() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder var textPreview: some View {
        if let reply {
            // Line numbers are only shown for text read from the file, not for the snippet fallback.
            let numbered = reply.end_line != nil
            let lines = shownLines
            let gutter = (firstLine..<(firstLine + lines)).map(String.init).joined(separator: "\n")
            // Matched lines are highlighted; surrounding lines give context.
            let matchStart = max(hit.start_line, firstLine), matchEnd = min(hit.end_line, firstLine + lines - 1)
            GeometryReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    HStack(alignment: .top, spacing: 14) {
                        if numbered { Text(gutter).foregroundStyle(.tertiary).multilineTextAlignment(.trailing) }
                        Text(reply.code).textSelection(.enabled)
                    }
                    .font(Font(Self.codeFont)).lineSpacing(0).fixedSize()
                    .padding(.vertical, 12).padding(.horizontal, 14)
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
                    .background(alignment: .topLeading) {
                        if numbered && matchEnd >= matchStart {
                            Rectangle().fill(.tint.opacity(0.10))
                                .frame(height: CGFloat(matchEnd - matchStart + 1) * Self.lineHeight)
                                .offset(y: 12 + CGFloat(matchStart - firstLine) * Self.lineHeight)
                        }
                    }
                }
            }
        } else if error == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else { Spacer() }
    }

    func initialLoad() async {
        if hit.isImage {
            do {
                if let cached = Thumbnail.cache[hit.imageKey] { image = cached; return }
                image = NSImage(data: try await store.request("/image", params: ["source_id": hit.source_id, "path": hit.path]))
            } catch { self.error = error.localizedDescription }
            return
        }
        // Start a few lines before the match and include the whole match where the service allows it.
        let start = max(1, hit.start_line - 3)
        await load(start: start, lines: min(300, max(80, hit.end_line - start + 21)))
    }

    func load(start: Int, lines: Int) async {
        loading = true; defer { loading = false }
        do {
            let data = try await store.request("/file", params: ["source_id": hit.source_id, "path": hit.path, "start_line": String(start), "max_lines": String(lines)])
            reply = try JSONDecoder().decode(FileReply.self, from: data)
            error = nil
        } catch {
            self.error = error.localizedDescription
            if reply == nil { reply = FileReply(code: hit.code, start_line: hit.start_line, end_line: nil, total_lines: nil) }
        }
    }
}

struct SourceDetailsView: View {
    let source: Source
    @Binding var removing: Source?
    @Environment(\.dismiss) var dismiss
    @ObservedObject var store = SearchStore.shared
    @ObservedObject var localization = AppLocalization.shared
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "folder.fill").font(.system(size: 30)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name).font(.title2.bold())
                    Text(source.path).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
            }.padding([.horizontal, .top], 24).padding(.bottom, 8)
            Form {
                Section {
                    LabeledContent(L10n.string("source.statusLabel")) {
                        HStack(spacing: 6) { Circle().fill(source.statusColor(connected: store.connected)).frame(width: 7, height: 7); Text(store.connected == false ? L10n.string("phase.offline") : source.phaseLabel) }
                    }
                    LabeledContent(L10n.string("source.lastIndexed"), value: source.indexedAt.map(L10n.indexed) ?? L10n.string("source.never"))
                    LabeledContent(L10n.string("source.contents"), value: L10n.string("source.status", L10n.string("count.files", source.files), L10n.string("count.items", source.chunks)))
                    LabeledContent(L10n.string("source.typesLabel"), value: source.kinds.map { L10n.assetKind($0) }.joined(separator: ", "))
                }
                Section(L10n.string("source.exclusions")) {
                    if source.excludes.isEmpty { Text(L10n.string("source.noExclusions")).foregroundStyle(.secondary) }
                    else { Text(source.excludes.joined(separator: "\n")).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
                }
                if let error = source.error { Section { Banner(text: error) } }
                if let skipped = source.last_sync?.skipped_files, !skipped.isEmpty {
                    Section(L10n.string("count.unreadableFiles", skipped.count)) {
                        ForEach(skipped.prefix(10), id: \.path) { file in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.path).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Text(file.error).font(.caption).foregroundStyle(.secondary)
                            }.textSelection(.enabled)
                        }
                    }
                }
                Section { Text(L10n.string("source.changeHelp")).font(.callout).foregroundStyle(.secondary) }
            }.formStyle(.grouped)
            HStack {
                Button(L10n.string("action.revoke.more"), role: .destructive) { dismiss(); removing = source }
                Spacer()
                Button(L10n.string("action.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)]) }
                Button(L10n.string("action.close")) { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 4)
        }.frame(width: 540, height: 580)
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
    var imagesAvailable: Bool { store.status?.image_search ?? false }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "folder.badge.plus").font(.system(size: 28)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("folder.authorize")).font(.title2.bold())
                    Text(path.path).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
            }.padding([.horizontal, .top], 24).padding(.bottom, 8)
            Form {
                Section {
                    TextField(L10n.string("source.name"), text: $name)
                }
                Section {
                    Toggle(isOn: $code) { Label(L10n.string("type.code"), systemImage: "chevron.left.forwardslash.chevron.right") }
                    Toggle(isOn: $documents) { Label(L10n.string("type.documents"), systemImage: "doc.text") }
                    Toggle(isOn: $images) { Label(L10n.string("type.images"), systemImage: "photo") }.disabled(!imagesAvailable)
                } header: { Text(L10n.string("source.indexTypes")) } footer: {
                    if !imagesAvailable { Text(L10n.string("source.enableImages")).font(.caption).foregroundStyle(.secondary) }
                }
                Section {
                    TextEditor(text: $excludes).font(.system(.body, design: .monospaced)).frame(height: 70).scrollContentBackground(.hidden)
                } header: { Text(L10n.string("source.extraExclusions")) } footer: {
                    Text(L10n.string("source.exclusionsHelp")).font(.caption).foregroundStyle(.secondary)
                }
                Section { Text(L10n.string("source.scopeHelp")).font(.callout).foregroundStyle(.secondary) }
            }.formStyle(.grouped)
            if let error = store.error { Banner(text: error).padding(.horizontal, 24).padding(.bottom, 8) }
            HStack {
                Spacer(); Button(L10n.string("action.cancel")) { store.addingPath = nil }.keyboardShortcut(.cancelAction)
                Button(saving ? L10n.string("action.adding") : L10n.string("action.authorizeIndex")) {
                    saving = true
                    Task {
                        let kinds = [(code, "code"), (documents, "documents"), (images, "images")].filter { $0.0 }.map { $0.1 }
                        if await store.add(path: path, name: name, kinds: kinds, excludes: excludes) { store.addingPath = nil }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || !(code || documents || images))
            }.padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 4)
        }.frame(width: 540, height: 640).onAppear { name = path.lastPathComponent; images = imagesAvailable; store.error = nil }
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
        VStack(alignment: .leading, spacing: 0) {
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
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.string("settings.rebuildHelp")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error { Banner(text: error) }
                HStack {
                    Button(L10n.string("action.defaults")) {
                        let available = options.image_encoder_available
                        options = ModelOptions(); options.image_encoder_available = available; options.images = available
                    }.disabled(!loaded)
                    Spacer()
                    if saving { ProgressView().controlSize(.small) }
                    if saved { Label(L10n.string("settings.saved"), systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green) }
                    Button(L10n.string("action.save")) {
                        saving = true; saved = false; error = nil
                        Task {
                            saved = await store.saveSettings(options)
                            if !saved { error = store.error }
                            saving = false
                        }
                    }.buttonStyle(.borderedProminent).disabled(saving || !loaded || !(256...8192).contains(options.max_tokens))
                }
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }.frame(width: 620, height: 720)
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 28)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("assistant.heading")).font(.title2.bold())
                    Text(L10n.string("assistant.scopeHelp")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Picker(L10n.string("assistant.picker"), selection: $tab) {
                Text(L10n.string("assistant.connection")).tag("connection"); Text(L10n.string("assistant.projectAccess")).tag("access")
            }.pickerStyle(.segmented).labelsHidden()
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(project.isEmpty ? L10n.string("assistant.launchProject") : project)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                if !project.isEmpty && tab == "connection" {
                    Button(L10n.string("assistant.useLaunchFolder")) { project = ""; folders = []; copied = ""; error = nil; saved = false }
                }
                Button(L10n.string("assistant.chooseProject")) {
                    if let path = chooseFolder(title: L10n.string("assistant.chooseProject.title")) {
                        project = path; copied = ""; Task { await loadAccess() }
                    }
                }.disabled(saving || loading)
            }
            .padding(12).background(.quinary, in: RoundedRectangle(cornerRadius: 10))
            if tab == "connection" {
                Text(L10n.string("assistant.commandsHelp")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(["claude", "codex"], id: \.self) { client in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(client == "codex" ? "Codex" : "Claude Code").font(.headline)
                            Spacer()
                            Button {
                                copyToPasteboard(store.connectionCommand(client, project: project)); copied = client
                            } label: {
                                Label(copied == client ? L10n.string("action.copied") : L10n.string("action.copy"), systemImage: copied == client ? "checkmark" : "doc.on.doc")
                            }.controlSize(.small)
                        }
                        Text(store.connectionCommand(client, project: project)).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)))
                    }.padding(12).background(.quinary, in: RoundedRectangle(cornerRadius: 10))
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("assistant.extraFolders")).font(.headline)
                    Text(L10n.string("assistant.extraFoldersHelp")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    if project.isEmpty { placeholder(L10n.string("assistant.chooseProjectFirst")) }
                    else if loading { ProgressView().controlSize(.small).padding(14) }
                    else if folders.isEmpty { placeholder(L10n.string("assistant.projectOnly")) }
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(folders, id: \.self) { path in
                                HStack {
                                    Image(systemName: "folder").foregroundStyle(.tint)
                                    Text(path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                    Spacer()
                                    Button { folders.removeAll { $0 == path }; saved = false; error = nil } label: { Image(systemName: "minus.circle.fill") }
                                        .buttonStyle(.borderless).foregroundStyle(.secondary).help(L10n.string("action.remove")).disabled(saving)
                                }.padding(.horizontal, 12).padding(.vertical, 8)
                                if path != folders.last { Divider().padding(.leading, 36) }
                            }
                        }
                    }.frame(maxHeight: 160).fixedSize(horizontal: false, vertical: true)
                }.background(.quinary, in: RoundedRectangle(cornerRadius: 10))
                HStack {
                    Button(L10n.string("action.addFolder.more")) {
                        if let path = chooseFolder(title: L10n.string("assistant.authorizeFolder.title")), !folders.contains(path) {
                            folders.append(path); saved = false; error = nil
                        }
                    }
                    Spacer()
                    if saved { Label(L10n.string("assistant.accessSaved"), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
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
                if let error { Banner(text: error) }
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.string("assistant.privacyHelp"), systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("action.close")) { store.showConnections = false }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 640, height: 600).task { await loadAccess() }
    }

    func placeholder(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12)
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
        Window("Local Search", id: "main") { RootView().environment(\.locale, localization.locale).tint(.brand) }
            .defaultSize(width: 1180, height: 760)
            .commands { CommandGroup(after: .newItem) { Button(L10n.string("action.addFolder.more")) { SearchStore.shared.chooseFolder() }.keyboardShortcut("o") } }
        Settings { SettingsView().environment(\.locale, localization.locale).tint(.brand) }
    }
}
