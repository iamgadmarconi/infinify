import XCTest
@testable import Canvas

@MainActor
final class PreviewModeTests: XCTestCase {
    func testPreviewModeIsAFreshInstallWithoutScreenCaptureMode() {
        XCTAssertTrue(Settings.previewMode(liveWindowsEverLoaded: false, screenCapture: false))
        XCTAssertFalse(Settings.previewMode(liveWindowsEverLoaded: true, screenCapture: false))
        XCTAssertFalse(Settings.previewMode(liveWindowsEverLoaded: false, screenCapture: true))
        XCTAssertFalse(Settings.previewMode(liveWindowsEverLoaded: true, screenCapture: true))
    }

    /// Through the defaults, as the canvas reads them: a fresh install streams up to eight windows, a Mac
    /// that has had live windows streams nothing, and screen capture mode on by choice streams again.
    func testStreamsFollowPreviewMode() {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        var arguments = original
        arguments["ScreenCaptureMode"] = "NO"
        arguments["LiveWindowsEverLoaded"] = "NO"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        XCTAssertTrue(Settings.previewMode)
        XCTAssertTrue(Settings.capturesStream)
        XCTAssertEqual(CanvasController.maxStreams, 8)

        arguments["LiveWindowsEverLoaded"] = "YES"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        XCTAssertFalse(Settings.previewMode)
        XCTAssertFalse(Settings.capturesStream)
        XCTAssertEqual(CanvasController.maxStreams, 0)

        arguments["ScreenCaptureMode"] = "YES"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        XCTAssertFalse(Settings.previewMode)
        XCTAssertTrue(Settings.capturesStream)
        XCTAssertEqual(CanvasController.maxStreams, 8)
    }

    /// Preview mode never asks for live windows itself: the preferred renderer stays live, so the canvas
    /// switches over the moment the add-on answers, but nothing is loaded without being asked.
    func testPreviewModeStillPrefersLiveWindows() {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        var arguments = original
        arguments["ScreenCaptureMode"] = "NO"
        arguments["LiveWindowsEverLoaded"] = "NO"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        XCTAssertEqual(Settings.renderer, .realWindows)
    }
}
