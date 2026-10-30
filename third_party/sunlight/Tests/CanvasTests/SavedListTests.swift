import XCTest
@testable import Canvas

final class SavedListTests: XCTestCase {
    private struct Thing: Codable, Equatable {
        var name: String
        var size: Int
    }

    private var folder: URL!
    private var url: URL { folder.appendingPathComponent("Things.json") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SavedListTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: url)
    }

    func testNoFileIsAnIntactEmptyList() {
        let read = SavedList.read(Thing.self, from: url)
        XCTAssertEqual(read.items, [])
        XCTAssertTrue(read.intact)
    }

    func testAWholeFileIsReadWhole() throws {
        try write(#"[{"name": "a", "size": 1}, {"name": "b", "size": 2}]"#)
        let read = SavedList.read(Thing.self, from: url)
        XCTAssertEqual(read.items, [Thing(name: "a", size: 1), Thing(name: "b", size: 2)])
        XCTAssertTrue(read.intact)
    }

    func testAnEntryThatCantBeReadCostsOnlyItself() throws {
        try write(#"[{"name": "a", "size": 1}, {"name": "b", "size": "big"}, {"name": "c", "size": 3}]"#)
        let read = SavedList.read(Thing.self, from: url)
        XCTAssertEqual(read.items.map(\.name), ["a", "c"])
        XCTAssertFalse(read.intact)
    }

    func testAFileThatIsntAListIsNotIntact() throws {
        try write(#"[{"name": "a", "size": 1},"#)   // cut short by a hand edit
        let read = SavedList.read(Thing.self, from: url)
        XCTAssertEqual(read.items, [])
        XCTAssertFalse(read.intact)
    }

    func testSettingAsideKeepsTheFileAsItWas() throws {
        let text = #"[{"name": "a", "size": 1},"#
        try write(text)
        let date = Date(timeIntervalSince1970: 0)
        let copy = try XCTUnwrap(SavedList.setAside(url, at: date))
        XCTAssertEqual(copy.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertTrue(copy.lastPathComponent.hasPrefix("Things (unreadable "))
        XCTAssertEqual(copy.pathExtension, "json")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), text)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
    }

    func testSettingAsideTwiceAtTheSameMomentRefusesTheSecond() throws {
        try write("x")
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertNotNil(SavedList.setAside(url, at: date))
        XCTAssertNil(SavedList.setAside(url, at: date))   // the copy is there: nothing may be written over
    }
}
