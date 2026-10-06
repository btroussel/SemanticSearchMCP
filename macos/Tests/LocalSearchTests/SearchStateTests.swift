import XCTest
@testable import LocalSearch

@MainActor
final class SearchStateTests: XCTestCase {
    var store: SearchStore!

    override func setUp() async throws {
        // Same isolation as SetupTests: the shared store must never reach the live state or service.
        setenv("LOCAL_SEARCH_STATE", SetupTests.state.path, 0)
        setenv("LOCAL_SEARCH_PORT", "1", 0)
        try FileManager.default.createDirectory(at: SetupTests.state, withIntermediateDirectories: true)
        store = SearchStore.shared
        store.timer?.invalidate()
        store.clearResults(); store.query = ""; store.error = nil
    }

    func hit() throws -> Hit {
        let json = """
        {"id": "a", "source_id": "s", "source_name": "Notes", "source_path": "/tmp/notes", "path": "a.md", "symbol": "a.md",
         "kind": "file", "asset_kind": "documents", "code": "text", "start_line": 1, "end_line": 1, "line_origin": "file"}
        """
        return try JSONDecoder().decode(Hit.self, from: Data(json.utf8))
    }

    func testChangingFiltersDoesNotLeaveStaleResults() throws {
        store.results = [try hit()]; store.latency = 3
        store.assetKind = "images"
        XCTAssertTrue(store.results.isEmpty)
        XCTAssertNil(store.latency)
        store.assetKind = ""
    }

    func testSupersededSearchDoesNotPublishItsReply() async throws {
        // Never write a key outside this test's own temporary state.
        guard store.state.path == SetupTests.state.path else { throw XCTSkip("The shared store uses another state folder") }
        // A readable key lets the request reach the (closed) port, so the search is still in flight when superseded.
        try "test-key".write(to: store.state.appendingPathComponent("access.key"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: store.state.appendingPathComponent("access.key")) }
        store.query = "meeting notes"
        let older = Task { await store.search() }
        while !store.busy { await Task.yield() }
        store.clearResults()
        await older.value
        XCTAssertNil(store.error)
        XCTAssertFalse(store.busy)
        XCTAssertNil(store.latency)
    }
}
