import XCTest
@testable import Canvas

final class PolarityPersistenceTests: XCTestCase {
    func testMagneticPolarityIsOffByDefaultAndRoundTrips() async {
        await MainActor.run {
            let defaults = UserDefaults.standard
            let saved = defaults.object(forKey: "CanvasMagneticPolarity")
            defer { defaults.set(saved, forKey: "CanvasMagneticPolarity") }
            defaults.removeObject(forKey: "CanvasMagneticPolarity")
            XCTAssertFalse(Settings.magneticPolarity)
            Settings.magneticPolarity = true
            XCTAssertTrue(Settings.magneticPolarity)
            Settings.magneticPolarity = false
            XCTAssertFalse(Settings.magneticPolarity)
        }
    }

    /// An entry as a build before polarity wrote it.
    private let entryJSON = """
    {"kind":"window","appName":"Notes","title":"Groceries","windowID":42,"frame":{"x":1,"y":2,"width":300,"height":200}}
    """

    func testEntryWithoutPolarityOrGroupDecodes() throws {
        let entry = try JSONDecoder().decode(Layout.Entry.self, from: Data(entryJSON.utf8))
        XCTAssertNil(entry.polarity)
        XCTAssertNil(entry.group)
        XCTAssertEqual(entry.windowID, 42)
        XCTAssertEqual(entry.frame.cgRect, CGRect(x: 1, y: 2, width: 300, height: 200))
    }

    func testEntryWithUnknownPolarityStringStillDecodes() throws {
        let json = entryJSON.replacingOccurrences(of: "\"windowID\"", with: "\"polarity\":\"sideways\",\"windowID\"")
        let entry = try JSONDecoder().decode(Layout.Entry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.polarity, "sideways")
        XCTAssertNil(Polarity(rawValue: entry.polarity!), "not a pole, and nothing else is lost")
    }

    func testPolarityAndGroupRoundTripAndChangeTheArrangement() throws {
        var entry = try JSONDecoder().decode(Layout.Entry.self, from: Data(entryJSON.utf8))
        entry.polarity = Polarity.minus.rawValue
        entry.group = 3
        let back = try JSONDecoder().decode(Layout.Entry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(back, entry)
        XCTAssertEqual(Polarity(rawValue: back.polarity!), .minus)
        XCTAssertEqual(back.group, 3)
        var flipped = entry
        flipped.polarity = Polarity.plus.rawValue
        XCTAssertNotEqual(flipped, entry, "a flip is a different arrangement, worth writing down")
        var regrouped = entry
        regrouped.group = nil
        XCTAssertNotEqual(regrouped, entry, "so is leaving a group")
    }
}
