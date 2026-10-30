import XCTest
@testable import Canvas

final class UninstallFlowTests: XCTestCase {
    private typealias Step = UninstallFlow.Step

    private let full = UninstallFlow.Status(addOnPresent: true, bootArguments: ["-arm64e_preview_abi"], helperRegistered: true,
                                            loginItem: true, takeoverApplied: true, sipPartlyOff: true)

    private func states(_ status: UninstallFlow.Status, skipped: Set<Step> = []) -> [UninstallFlow.Entry.State] {
        UninstallFlow.entries(for: status, skipped: skipped).map(\.state)
    }

    func testAFullInstallWalksBackInOrder() {
        XCTAssertEqual(UninstallFlow.current(for: full, skipped: []), .addOn)
        XCTAssertEqual(states(full), [.current, .todo, .todo, .todo, .todo])

        var status = full
        status.addOnPresent = false
        XCTAssertEqual(UninstallFlow.current(for: status, skipped: []), .bootArgument)
        status.bootArguments = []
        XCTAssertEqual(UninstallFlow.current(for: status, skipped: []), .helper)
        status.helperRegistered = false
        XCTAssertEqual(UninstallFlow.current(for: status, skipped: []), .helper, "the login item and takeover count too")
        status.loginItem = false
        status.takeoverApplied = false
        XCTAssertEqual(UninstallFlow.current(for: status, skipped: []), .protection)
        status.sipPartlyOff = false
        XCTAssertEqual(UninstallFlow.current(for: status, skipped: []), .trash)
        XCTAssertEqual(states(status), [.done, .done, .done, .done, .current])
    }

    func testTheTrashIsAlwaysLastAndNeverDone() {
        XCTAssertEqual(UninstallFlow.current(for: .clean, skipped: []), .trash)
        XCTAssertFalse(UninstallFlow.isDone(.trash, status: .clean))
        XCTAssertEqual(UninstallFlow.current(for: .clean, skipped: [.trash]), .trash)
    }

    func testASkippedStepIsLeftAsItIs() {
        var status = full
        status.addOnPresent = false
        XCTAssertEqual(UninstallFlow.current(for: status, skipped: [.bootArgument]), .helper)
        XCTAssertEqual(states(status, skipped: [.bootArgument]), [.done, .skipped, .current, .todo, .todo])
        // Leaving SIP partly off goes straight to the Trash.
        status.bootArguments = []
        status.helperRegistered = false
        status.loginItem = false
        status.takeoverApplied = false
        XCTAssertEqual(UninstallFlow.current(for: status, skipped: [.protection]), .trash)
    }

    func testTheStoredBootArgumentsComeFromNvram() {
        XCTAssertEqual(UninstallFlow.bootArguments(fromNvram: "boot-args\t-arm64e_preview_abi -v\n", status: 0), ["-arm64e_preview_abi", "-v"])
        XCTAssertEqual(UninstallFlow.bootArguments(fromNvram: "boot-args\t-arm64e_preview_abi", status: 0), ["-arm64e_preview_abi"])
        XCTAssertEqual(UninstallFlow.bootArguments(fromNvram: "nvram: Error getting variable - 'boot-args': (iokit/common) data was not found\n", status: 1), [])
        XCTAssertEqual(UninstallFlow.bootArguments(fromNvram: "", status: 0), [])
        var status = UninstallFlow.Status.clean
        status.bootArguments = ["-v"]
        XCTAssertFalse(status.bootArgumentStored)
        status.bootArguments = ["-v", "-arm64e_preview_abi"]
        XCTAssertTrue(status.bootArgumentStored)
    }

    func testTheTerminalLinesKeepOtherBootArguments() {
        XCTAssertEqual(UninstallFlow.terminalCommands(bootArguments: ["-arm64e_preview_abi"]),
                       "sudo nvram -d boot-args\nsudo rm -f /private/etc/sudoers.d/sunlight-live-windows")
        XCTAssertEqual(UninstallFlow.terminalCommands(bootArguments: []),
                       "sudo nvram -d boot-args\nsudo rm -f /private/etc/sudoers.d/sunlight-live-windows")
        XCTAssertEqual(UninstallFlow.terminalCommands(bootArguments: ["-v", "-arm64e_preview_abi", "debug=0x100"]),
                       "sudo nvram boot-args='-v debug=0x100'\nsudo rm -f /private/etc/sudoers.d/sunlight-live-windows")
    }
}
