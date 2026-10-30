import XCTest
@testable import Canvas

final class DesktopPlacementTests: XCTestCase {
    private let windows = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let block = CGSize(width: 200, height: 100)
    private let gap = DesktopPlacement.gap

    private func rect(_ x: CGFloat, _ y: CGFloat, _ size: CGSize? = nil) -> CGRect {
        DesktopPlacement(x: x, y: y).rect(size: size ?? block, around: windows)
    }

    func testInsideTheWindowsTheBlockIsCentredUnderTheSpot() {
        XCTAssertEqual(rect(0.5, 0.5), CGRect(x: 400, y: 250, width: 200, height: 100))
        XCTAssertEqual(rect(0, 0), CGRect(x: -100, y: -50, width: 200, height: 100))   // straddles the corner
    }

    func testFarEnoughOutTheBlockIsCentredOnTheSpot() {
        // 1.5 windows across is 500 pt past the right edge: well clear.
        XCTAssertEqual(rect(1.5, 0.5), CGRect(x: 1400, y: 250, width: 200, height: 100))
        XCTAssertEqual(rect(-0.5, -0.5), CGRect(x: -600, y: -350, width: 200, height: 100))
    }

    func testNearTheWindowsTheBlockIsPushedStraightOutOnEachSide() {
        XCTAssertEqual(rect(1.05, 0.3), CGRect(x: 1000 + gap, y: 130, width: 200, height: 100))
        XCTAssertEqual(rect(-0.05, 0.3), CGRect(x: -gap - 200, y: 130, width: 200, height: 100))
        XCTAssertEqual(rect(0.3, -0.05), CGRect(x: 200, y: -gap - 100, width: 200, height: 100))
        XCTAssertEqual(rect(0.3, 1.05), CGRect(x: 200, y: 600 + gap, width: 200, height: 100))
    }

    func testOffACornerItGoesOutAlongTheAxisFurthestOut() {
        let r = rect(1.1, 1.02)   // 0.1 out across, 0.02 down: pushed right, stays where it is down
        XCTAssertEqual(r.minX, 1000 + gap)
        XCTAssertEqual(r.midY, 612)
    }

    func testNothingOutsideTheWindowsOverlapsThem() {
        let spots: [CGFloat] = [-0.5, -0.25, -0.01, 0.5, 1.01, 1.25, 1.5]
        for x in spots {
            for y in spots where !(0...1).contains(x) || !(0...1).contains(y) {
                XCTAssertFalse(rect(x, y).intersects(windows.insetBy(dx: -gap + 1, dy: -gap + 1)), "\(x), \(y)")
            }
        }
    }

    func testSpotsStayWithinFiveWindowsOfThem() {
        XCTAssertEqual(DesktopPlacement(x: 9, y: -9), DesktopPlacement(x: 6, y: -5))
        XCTAssertEqual(DesktopPlacement(stored: "-40,2"), DesktopPlacement(x: -5, y: 2))
        XCTAssertEqual(DesktopPlacement(x: 3.5, y: -2.5).x, 3.5)   // far out, but kept
    }

    func testSpotsAndWorldPointsRoundTrip() {
        let p = DesktopPlacement(world: CGPoint(x: 1250, y: -150), around: windows)
        XCTAssertEqual(p, DesktopPlacement(x: 1.25, y: -0.25))
        XCTAssertEqual(p.world(around: windows), CGPoint(x: 1250, y: -150))
    }

    func testTheMapIsTheWindowsAndBlocksPaddedToItsAspect() {
        // 1000 × 600 padded by half on each side is 2000 × 1200; at 2:1 it widens to 2400, centred.
        let r = DesktopPlacement.mapWorld(around: windows, blocks: [], aspect: 2)
        XCTAssertEqual(r, CGRect(x: -700, y: -300, width: 2400, height: 1200))
        // At 1:1 it heightens instead.
        XCTAssertEqual(DesktopPlacement.mapWorld(around: windows, blocks: [], aspect: 1),
                       CGRect(x: -500, y: -700, width: 2000, height: 2000))
    }

    func testTheMapTakesInBlocksFarOut() {
        let far = CGRect(x: 3000, y: 200, width: 300, height: 400)
        let r = DesktopPlacement.mapWorld(around: windows, blocks: [far], aspect: 5.0 / 3)
        XCTAssertTrue(r.contains(far))
        XCTAssertTrue(r.contains(windows))
        XCTAssertEqual(r.width / r.height, 5.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(r.minX, -500)
        XCTAssertEqual(r.maxX, 3300 + 500)
    }

    func testFilesMoveClearOfTheWidgetsTheWayTheirDotLies() {
        let files = CGSize(width: 300, height: 400)
        let w = (size: block, at: DesktopPlacement(x: 1.2, y: 0.5))
        let right = DesktopPlacement.rects(widgets: w, files: (files, DesktopPlacement(x: 1.25, y: 0.5)), around: windows)
        XCTAssertEqual(right.widgets, rect(1.2, 0.5))
        XCTAssertEqual(right.files?.minX, right.widgets!.maxX + gap)
        let below = DesktopPlacement.rects(widgets: w, files: (files, DesktopPlacement(x: 1.2, y: 0.6)), around: windows)
        XCTAssertEqual(below.files?.minY, below.widgets!.maxY + gap)
        let apart = DesktopPlacement.rects(widgets: w, files: (files, DesktopPlacement(x: -0.25, y: 0.5)), around: windows)
        XCTAssertEqual(apart.files, rect(-0.25, 0.5, files))
    }

    func testEitherBlockMayBeMissing() {
        let none = DesktopPlacement.rects(widgets: nil, files: (block, .filesDefault), around: windows)
        XCTAssertNil(none.widgets)
        XCTAssertEqual(none.files, DesktopPlacement.filesDefault.rect(size: block, around: windows))
        XCTAssertNil(DesktopPlacement.rects(widgets: (block, .widgetsDefault), files: nil, around: windows).files)
    }

    func testStoredRoundTripsAndRejectsJunk() {
        for p in [DesktopPlacement(x: 1.25, y: 0.3), DesktopPlacement(x: -0.125, y: 1.5), DesktopPlacement(x: 0, y: 0)] {
            XCTAssertEqual(DesktopPlacement(stored: p.stored), p)
        }
        XCTAssertNil(DesktopPlacement(stored: "beside.right"))
        XCTAssertNil(DesktopPlacement(stored: "1"))
        XCTAssertNil(DesktopPlacement(stored: "nan,0"))
    }

    func testDefaultsAreFilesRightWidgetsLeft() {
        XCTAssertEqual(DesktopPlacement.filesDefault, DesktopPlacement(x: 1.25, y: 0.3))
        XCTAssertEqual(DesktopPlacement.widgetsDefault, DesktopPlacement(x: -0.25, y: 0.3))
        XCTAssertGreaterThan(rect(1.25, 0.3).minX, windows.maxX)
        XCTAssertLessThan(rect(-0.25, 0.3).maxX, windows.minX)
    }

    func testTitles() {
        XCTAssertEqual(DesktopPlacement(x: 0.5, y: 0.5).title, "Under the windows")
        XCTAssertEqual(DesktopPlacement(x: 1.2, y: 0.5).title, "Right of the windows")
        XCTAssertEqual(DesktopPlacement(x: 0.5, y: -0.2).title, "Above the windows")
        XCTAssertEqual(DesktopPlacement(x: -0.2, y: 1.2).title, "Off the bottom-left corner")
    }

    func testSettingsDefaultAndRoundTrip() async {
        await MainActor.run {
            let defaults = UserDefaults.standard
            let saved = defaults.object(forKey: "WidgetsSpot")
            defer { defaults.set(saved, forKey: "WidgetsSpot") }
            defaults.removeObject(forKey: "WidgetsSpot")
            XCTAssertEqual(Settings.widgetsPlacement, .widgetsDefault)
            Settings.widgetsPlacement = DesktopPlacement(x: 0.5, y: -0.25)
            XCTAssertEqual(Settings.widgetsPlacement, DesktopPlacement(x: 0.5, y: -0.25))
            defaults.set("nonsense", forKey: "WidgetsSpot")
            XCTAssertEqual(Settings.widgetsPlacement, .widgetsDefault)
        }
    }

    func testFilesContentIsWhatTheFilesCoverWithAMargin() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let icons = [CGRect(x: 1400, y: 40, width: 100, height: 100), CGRect(x: 1400, y: 160, width: 100, height: 100)]
        XCTAssertEqual(DesktopPlacement.filesContent(hitRects: icons, screen: screen, margin: 10),
                       CGRect(x: 1390, y: 30, width: 120, height: 240))
    }

    func testFilesContentStaysOnTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let icons = [CGRect(x: 1450, y: 0, width: 100, height: 100)]
        let r = DesktopPlacement.filesContent(hitRects: icons, screen: screen)
        XCTAssertTrue(screen.contains(r))
    }

    func testAnEmptyDesktopKeepsAPatchOfGroundTopRight() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let r = DesktopPlacement.filesContent(hitRects: [], screen: screen)
        XCTAssertEqual(r.maxX, screen.maxX)
        XCTAssertGreaterThan(r.width, 0)
        XCTAssertGreaterThan(r.height, 0)
        XCTAssertLessThan(r.minY, 100)
    }
}
