import XCTest
@testable import LocalSearch

@MainActor
final class SetupTests: XCTestCase {
    static let state = FileManager.default.temporaryDirectory.appendingPathComponent("LocalSearchTests-" + UUID().uuidString)
    var store: SearchStore!

    override func setUp() async throws {
        // The shared store reads its state folder once; keep it away from the live state and service.
        setenv("LOCAL_SEARCH_STATE", Self.state.path, 0)
        setenv("LOCAL_SEARCH_PORT", "1", 0)
        try FileManager.default.createDirectory(at: Self.state, withIntermediateDirectories: true)
        store = SearchStore.shared
        store.setupCancelled = false
        XCTAssertEqual(store.state.path, Self.state.path)
    }

    func shell(_ script: String, onLine: ((String) -> Void)? = nil) async throws {
        try await store.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script], onLine: onLine)
    }

    func testStepStreamsStdoutLinesAndLogsStderr() async throws {
        var lines: [String] = []
        try await shell("echo '{\"downloaded\": 1}'; echo diagnostic >&2; echo '{\"downloaded\": 2}'") { lines.append($0) }
        XCTAssertEqual(lines, ["{\"downloaded\": 1}", "{\"downloaded\": 2}"])
        XCTAssertTrue(try String(contentsOf: store.setupLog, encoding: .utf8).contains("diagnostic"))
    }

    func testFailedStepReportsItsLastErrorLine() async {
        do {
            try await shell("echo first >&2; echo 'network unreachable' >&2; echo >&2; exit 3")
            XCTFail("A failing step must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("network unreachable"), error.localizedDescription)
        }
    }

    func testCancelStopsTheRunningStepWithoutAnError() async {
        let started = Date()
        let task = Task { try await shell("sleep 30") }
        try? await Task.sleep(for: .milliseconds(300))
        store.cancelSetup()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testChosenModelFolderMustContainTheCheckpoint() throws {
        XCTAssertFalse(SearchStore.isModel(Self.state))
        for name in ["config.json", "model.safetensors", "tokenizer.json"] {
            FileManager.default.createFile(atPath: Self.state.appendingPathComponent(name).path, contents: Data())
        }
        XCTAssertTrue(SearchStore.isModel(Self.state))
    }
}
