import AppKit
import os.log

/// The Dock answers an activation of an app on another Space with its full
/// slide; an instant switch to the same Space posted as soon as the
/// activation lands preempts that slide.
@MainActor
final class AppActivationFollower {
    struct WindowCandidate: Equatable {
        let spaceIDs: [Int]
        let isOnScreen: Bool
        let isMinimized: Bool
        /// Closed, yet kept alive in the window server by the app
        var isClosed = false
    }

    /// A repeat activation of the app just followed, within this window, is
    /// the system finishing that activation rather than a new request, and
    /// chasing it could hop on to another of the app's windows.
    static let echoWindow: TimeInterval = 0.3

    /// An activation this soon after a Space change the user made is the app
    /// landing in focus on the arrival Space, not a request to go elsewhere.
    static let spaceChangeWindow: TimeInterval = 0.3

    /// How long a Space change onto the followed Space is credited to the
    /// follow. The change notification only arrives once the transition
    /// settles, so the window is generous.
    static let followSettleWindow: TimeInterval = 1.5

    /// An activation this soon after a click inside one of the app's visible
    /// windows was caused by that click, and the user is already there.
    static let clickWindow: TimeInterval = 0.5

    private static let logger = Logger(subsystem: "io.gechr.WhichSpace", category: "AppActivationFollower")

    private let store: DefaultsStore
    private var observers: [NSObjectProtocol] = []
    private var lastFollow: (pid: pid_t, spaceID: Int, date: Date)?
    /// `SpaceSwitcher.lastSwitchDate` as the last follow left it, so the
    /// follow's own switch never reads as the user switching
    private var followSwitchDate: Date?
    private var lastUserSpaceChange: Date?

    init(store: DefaultsStore) {
        self.store = store
    }

    /// Block observers on the main queue rather than async sequences: every
    /// run loop turn lost here is a frame of the Dock's slide on screen.
    func start() {
        guard observers.isEmpty else {
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated {
                self?.handleActivation(pid: pid)
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSpaceChange()
            }
        })
    }

    func stop() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    // MARK: - Activation

    private func handleActivation(pid: pid_t?) {
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier, shouldConsiderActivations else {
            return
        }
        let now = Date()
        if let lastFollow, lastFollow.pid == pid, now.timeIntervalSince(lastFollow.date) < Self.echoWindow {
            return
        }
        if let lastUserSpaceChange, now.timeIntervalSince(lastUserSpaceChange) < Self.spaceChangeWindow {
            return
        }
        // A switch this app posted itself, e.g. a hotkey or a menu bar click,
        // lands some app in focus on the arrival Space
        if let switchDate = SpaceSwitcher.lastSwitchDate, switchDate != followSwitchDate,
           now.timeIntervalSince(switchDate) < Self.spaceChangeWindow
        {
            return
        }
        // A held button is a window drag, which swallows synthetic swipes
        guard NSEvent.pressedMouseButtons == 0 else {
            return
        }

        let conn = _CGSDefaultConnection()
        let onScreen = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        // Mission Control navigates by itself, and a swipe posted into it is
        // judged against the overview rather than the desktop
        guard !Self.isOverviewShowing(in: onScreen) else {
            return
        }
        if Self.secondsSinceLastClick < Self.clickWindow, Self.pointerIsInsideWindow(ownedBy: pid, in: onScreen) {
            return
        }

        let layout = Self.spaceLayout(connection: conn)
        guard let target = Self.targetSpaceID(
            for: Self.windowCandidates(ownedBy: pid, connection: conn),
            activeSpaceIDs: layout.active,
            followableSpaceIDs: layout.followable
        ) else {
            return
        }
        Self.logger.info("following pid=\(pid) to space \(target)")
        guard SpaceSwitcher.switchToSpace(id: target) else {
            return
        }
        lastFollow = (pid, target, now)
        followSwitchDate = SpaceSwitcher.lastSwitchDate
    }

    /// Classic switching is excluded: it slides just like the Dock, so it
    /// would only add a second, racing switch.
    private var shouldConsiderActivations: Bool {
        store.followAppActivation
            && !store.classicSpaceSwitching
            && AXIsProcessTrusted()
            && SpaceSwitcher.spaceSwipeGestureSettingEnabled
    }

    private func handleSpaceChange() {
        let now = Date()
        if let lastFollow, now.timeIntervalSince(lastFollow.date) < Self.followSettleWindow,
           Self.spaceLayout(connection: _CGSDefaultConnection()).active.contains(lastFollow.spaceID)
        {
            return
        }
        lastUserSpaceChange = now
    }

    // MARK: - Target Decision

    /// Nil when the app is already within reach or its Space cannot be
    /// reached instantly. `candidates` must be front to back: the first
    /// placed window decides the target.
    static func targetSpaceID(
        for candidates: [WindowCandidate],
        activeSpaceIDs: Set<Int>,
        followableSpaceIDs: Set<Int>
    ) -> Int? {
        // A closed window still reports the Space it was closed on, and with
        // no window left open that is where the Dock slides to. While any
        // window is open, closed ones are stale and would mislead.
        let live = candidates.filter { !$0.isClosed }
        let considered = live.isEmpty ? candidates : live
        // A window in view, or one assigned to every Space, is already where
        // the user is
        if considered.contains(where: { $0.isOnScreen || $0.spaceIDs.count > 1 }) {
            return nil
        }
        // Activation never unminimizes, so the Dock does not navigate for a
        // minimized window and neither should a follow
        let placed = considered.filter { !$0.isMinimized && $0.spaceIDs.count == 1 }
        // A hidden app's window on a visible Space reappears right there
        if placed.contains(where: { activeSpaceIDs.contains($0.spaceIDs[0]) }) {
            return nil
        }
        // Only the menu bar display's Spaces take instant switches; anything
        // else stays with the Dock's native switch
        guard let target = placed.first?.spaceIDs.first, followableSpaceIDs.contains(target) else {
            return nil
        }
        return target
    }

    // MARK: - Window Server Reads

    /// `active` holds the current Space of every display, `followable` every
    /// Space of the menu bar display, the only one instant switches reach.
    private static func spaceLayout(connection: Int32) -> (active: Set<Int>, followable: Set<Int>) {
        guard let displays = CGSCopyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return ([], [])
        }
        let menuBarDisplay = CGSCopyActiveMenuBarDisplayIdentifier(connection)?.takeRetainedValue() as String?
        var active: Set<Int> = []
        var followable: Set<Int> = []
        for display in displays {
            if let current = display["Current Space"] as? [String: Any],
               let id = current["ManagedSpaceID"] as? Int
            {
                active.insert(id)
            }
            guard display["Display Identifier"] as? String == menuBarDisplay,
                  let spaces = display["Spaces"] as? [[String: Any]]
            else {
                continue
            }
            followable.formUnion(spaces.compactMap { $0["ManagedSpaceID"] as? Int })
        }
        return (active, followable)
    }

    /// The app's regular windows front to back, including closed ones the
    /// app keeps alive in the window server.
    private static func windowCandidates(ownedBy pid: pid_t, connection: Int32) -> [WindowCandidate] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var windows: [(id: Int, isOnScreen: Bool)] = []
        for window in windowList {
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
                  width > 5, height > 5,
                  let id = window[kCGWindowNumber as String] as? Int
            else {
                continue
            }
            windows.append((id, window[kCGWindowIsOnscreen as String] as? Bool ?? false))
        }
        let states = CGSDisplaySpaceProvider.windowServerStates(windows.map(\.id), connection: connection)
        return windows.compactMap { window in
            var isMinimized = false
            var isClosed = false
            if let states {
                // Unknown to the window server: gone, not merely closed
                guard let state = states[window.id] else {
                    return nil
                }
                isClosed = !CGSDisplaySpaceProvider.isSpaceOccupant(attributes: state.attributes, tags: state.tags)
                isMinimized = state.tags & CGSDisplaySpaceProvider.minimizedTags != 0
            }
            // Selector 0x7 = all spaces the window is on
            let spaces = SLSCopySpacesForWindows(connection, 0x7, [window.id] as CFArray)?
                .takeRetainedValue() as? [Int] ?? []
            return WindowCandidate(
                spaceIDs: spaces,
                isOnScreen: window.isOnScreen,
                isMinimized: isMinimized,
                isClosed: isClosed
            )
        }
    }

    private static var secondsSinceLastClick: TimeInterval {
        min(
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .rightMouseDown)
        )
    }

    /// Any layer counts: clicking a floating panel of the app must not chase
    /// the app's main window to another Space.
    private static func pointerIsInsideWindow(ownedBy pid: pid_t, in onScreen: [[String: Any]]) -> Bool {
        guard let location = CGEvent(source: nil)?.location else {
            return false
        }
        return onScreen.contains { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else {
                return false
            }
            return frame.contains(location)
        }
    }

    /// Whether Mission Control, App Exposé or Show Desktop is up, read from
    /// the display-sized overlay its owner puts on screen: the Dock at layer
    /// 18 through macOS 26, WindowManager at layer 18 or 19 from macOS 27.
    private static func isOverviewShowing(in onScreen: [[String: Any]]) -> Bool {
        let modern = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        let displaySizes = NSScreen.screens.map { CGDisplayBounds($0.displayID).size }
        return onScreen.contains { window in
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  let layer = window[kCGWindowLayer as String] as? Int
            else {
                return false
            }
            if !modern {
                return owner == "Dock" && layer == 18
            }
            guard owner == "WindowManager", layer == 18 || layer == 19,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else {
                return false
            }
            return displaySizes.contains { abs($0.width - frame.width) <= 1 && abs($0.height - frame.height) <= 1 }
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? kCGNullDirectDisplay
    }
}
