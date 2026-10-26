import Testing
@testable import WhichSpace

@MainActor
struct AppActivationFollowerTests {
    private typealias Candidate = AppActivationFollower.WindowCandidate

    private func window(
        _ spaceIDs: [Int],
        onScreen: Bool = false,
        minimized: Bool = false,
        closed: Bool = false
    ) -> Candidate {
        Candidate(spaceIDs: spaceIDs, isOnScreen: onScreen, isMinimized: minimized, isClosed: closed)
    }

    private func target(_ candidates: [Candidate], active: Set<Int> = [1], followable: Set<Int> = [1, 3, 4]) -> Int? {
        AppActivationFollower.targetSpaceID(for: candidates, activeSpaceIDs: active, followableSpaceIDs: followable)
    }

    @Test("follows the frontmost window on another Space")
    func followsFrontmostWindow() {
        #expect(target([window([3]), window([4])]) == 3)
    }

    @Test("stays when a window is already on screen")
    func staysForOnScreenWindow() {
        #expect(target([window([3]), window([1], onScreen: true)]) == nil)
    }

    @Test("stays for a window assigned to every Space")
    func staysForAllSpacesWindow() {
        #expect(target([window([1, 3]), window([3])]) == nil)
    }

    @Test("stays when a hidden window lives on a visible Space")
    func staysForHiddenWindowOnVisibleSpace() {
        #expect(target([window([3]), window([1])]) == nil)
    }

    @Test("skips minimized windows")
    func skipsMinimizedWindows() {
        #expect(target([window([3], minimized: true), window([4])]) == 4)
        #expect(target([window([3], minimized: true)]) == nil)
    }

    @Test("skips windows whose Space is unknown")
    func skipsUnresolvedWindows() {
        #expect(target([window([]), window([3])]) == 3)
    }

    @Test("leaves Spaces off the menu bar display to the Dock")
    func leavesOtherDisplaysNative() {
        #expect(target([window([7])], active: [1, 6]) == nil)
    }

    @Test("follows the last closed window when none is open")
    func followsClosedWindowWithoutOpenOnes() {
        #expect(target([window([], closed: true), window([3], closed: true), window([4], closed: true)]) == 3)
    }

    @Test("ignores closed windows while one is open")
    func ignoresClosedWindowsBesideOpenOnes() {
        #expect(target([window([3], closed: true), window([4])]) == 4)
        #expect(target([window([3], closed: true), window([1], onScreen: true)]) == nil)
    }

    @Test("stays when the last closed window was on a visible Space")
    func staysForClosedWindowOnVisibleSpace() {
        #expect(target([window([1], closed: true), window([3], closed: true)]) == nil)
    }

    @Test("stays for an app without windows")
    func staysWithoutWindows() {
        #expect(target([]) == nil)
    }
}
