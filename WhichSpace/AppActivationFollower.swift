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

    /// Whether the Dock switches to an activated app's Space itself, which
    /// System Settings calls "When switching to an application, switch to a
    /// Space with open windows for the application". It starts its own slide
    /// on every activation: one instant swipe still beats it, but a jump
    /// across several Spaces needs a swipe per Space and loses the race, so
    /// long follows animate. Absent means on, the macOS default.
    static var dockSwitchesSpacesOnActivation: Bool {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("workspaces-auto-swoosh" as CFString, domain) as? Bool ?? true
    }

    /// Opens Desktop & Dock scrolled to that switch. Turning it off there
    /// takes effect at once, whereas a defaults write only reaches the Dock
    /// on its next launch.
    static let dockSwitchingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
            + "?whenSwitchingToAnApplicationSwitchToASpaceWithOpenWindowsForTheApplication"
    )

    private let store: DefaultsStore
    private var observers: [NSObjectProtocol] = []
    private var lastFollow: (pid: pid_t, spaceID: Int, date: Date)?
    /// Every follow still settling. Rapid switches land their Space change
    /// notifications after the next follow, so crediting the last alone
    /// mistakes the earlier ones for the user's own switches.
    private var settlingFollows: [(spaceID: Int, date: Date)] = []
    /// `SpaceSwitcher.lastSwitchDate` as the last follow left it, so the
    /// follow's own switch never reads as the user switching
    private var followSwitchDate: Date?
    private var lastUserSpaceChange: Date?
    /// Focus switches between windows of the frontmost app, e.g. through
    /// AltTab, activate nothing, so they are only seen through Accessibility
    private var focusObserver: (pid: pid_t, observer: AXObserver)?
    private var lastFocusFollow: (windowID: CGWindowID, date: Date)?
    /// The window the last focus notification named, nil until one arrives
    /// for the observed app
    private var lastFocusedWindowID: CGWindowID?
    /// Apps whose Accessibility connection this process has opened
    private var warmedPIDs: Set<pid_t> = []

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
                // The switch goes out before the focus observer is set up,
                // which messages the app and would delay it
                self?.handleActivation(pid: pid)
                self?.observeFocus(of: pid)
                self?.warmAccessibilityConnections()
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // A launching app answers Accessibility only once it is up
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    self?.warmAccessibilityConnections()
                }
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSpaceChange()
            }
        })
        observeFocus(of: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        warmAccessibilityConnections()
    }

    /// The first Accessibility message this process sends an app sets up the
    /// connection and takes 8–30 ms, later ones ~0.1 ms. Paid during an
    /// activation, that is long enough for the Dock's slide to start, so the
    /// first follow to each app animated. One cheap query per app, off the
    /// main thread, pays it ahead of time.
    private func warmAccessibilityConnections() {
        guard AXIsProcessTrusted() else {
            return
        }
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let pids = Set(running.map(\.processIdentifier))
        warmedPIDs.formIntersection(pids)
        let cold = pids.subtracting(warmedPIDs).subtracting([ProcessInfo.processInfo.processIdentifier])
        guard !cold.isEmpty else {
            return
        }
        warmedPIDs.formUnion(cold)
        DispatchQueue.global(qos: .utility).async {
            for pid in cold {
                let application = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(application, 0.25)
                var value: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value)
            }
        }
    }

    func stop() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        observeFocus(of: nil)
    }

    // MARK: - Activation

    /// Decides at once: the Dock marks the target Space current as soon as
    /// its own slide starts, and a later look finds nothing left to switch.
    private func handleActivation(pid: pid_t?) {
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier, shouldConsiderActivations else {
            return
        }
        let now = Date()
        if let lastFollow, lastFollow.pid == pid, now.timeIntervalSince(lastFollow.date) < Self.echoWindow {
            return
        }
        let conn = _CGSDefaultConnection()
        guard let onScreen = onScreenWindowsIfFollowable(pid: pid, now: now) else {
            return
        }
        let layout = Self.spaceLayout(connection: conn)
        // The focused window is where the Dock is headed, and the frontmost
        // may sit on another Space: a switcher like AltTab focuses its pick
        // before activating, so no focus notification reports it either.
        // Without one, as for an app with every window closed, the frontmost
        // window stands in.
        let candidates = SystemFrontWindowLocator.focusedWindowID(ofApplication: pid)
            .flatMap { Self.windowCandidate($0, connection: conn, onScreen: onScreen) }
            .map { [$0] } ?? Self.windowCandidates(ownedBy: pid, connection: conn)
        guard let target = Self.targetSpaceID(
            for: candidates,
            activeSpaceIDs: layout.active,
            followableSpaceIDs: layout.followable
        ) else {
            Self.logger.debug("""
            activation of pid=\(pid) needs no switch: \(String(describing: candidates), privacy: .public) \
            active=\(layout.active.sorted(), privacy: .public)
            """)
            return
        }
        Self.logger.info("following pid=\(pid) to space \(target)")
        follow(pid: pid, to: target, now: now)
    }

    /// The on-screen window list, or nil when something rules a follow out
    /// right now. Shared by activations and focus switches within an app.
    private func onScreenWindowsIfFollowable(pid: pid_t, now: Date) -> [[String: Any]]? {
        // Both Space change guards only cover the app landing in focus on
        // its own; a key or a click since the change, like a switcher's
        // Enter, is the user asking for something new
        let lastInput = Self.lastInputDate
        if let lastUserSpaceChange, now.timeIntervalSince(lastUserSpaceChange) < Self.spaceChangeWindow,
           lastInput <= lastUserSpaceChange
        {
            Self.logger.debug("pid=\(pid) ruled out: user changed Space")
            return nil
        }
        // A switch this app posted itself, e.g. a hotkey or a menu bar click,
        // lands some app in focus on the arrival Space
        if let switchDate = SpaceSwitcher.lastSwitchDate, switchDate != followSwitchDate,
           now.timeIntervalSince(switchDate) < Self.spaceChangeWindow, lastInput <= switchDate
        {
            Self.logger.debug("pid=\(pid) ruled out: own switch")
            return nil
        }
        // A held button is a window drag, which swallows synthetic swipes
        guard NSEvent.pressedMouseButtons == 0 else {
            Self.logger.debug("pid=\(pid) ruled out: mouse button held")
            return nil
        }
        let onScreen = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        // Mission Control navigates by itself, and a swipe posted into it is
        // judged against the overview rather than the desktop
        guard !Self.isOverviewShowing(in: onScreen) else {
            Self.logger.debug("pid=\(pid) ruled out: overview showing")
            return nil
        }
        if Self.secondsSinceLastClick < Self.clickWindow, Self.pointerIsInsideWindow(ownedBy: pid, in: onScreen) {
            Self.logger.debug("pid=\(pid) ruled out: click inside its window")
            return nil
        }
        return onScreen
    }

    private func follow(pid: pid_t, to target: Int, now: Date) {
        guard SpaceSwitcher.switchToSpace(id: target) else {
            return
        }
        lastFollow = (pid, target, now)
        settlingFollows.removeAll { now.timeIntervalSince($0.date) >= Self.followSettleWindow }
        settlingFollows.append((target, now))
        followSwitchDate = SpaceSwitcher.lastSwitchDate
    }

    // MARK: - Focus Within an App

    /// Replaces the focus observer with one on `pid`. The run loop source
    /// sits on the main run loop, so the callback arrives on the main thread.
    private func observeFocus(of pid: pid_t?) {
        guard pid != focusObserver?.pid else {
            return
        }
        if let focusObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusObserver.observer), .defaultMode
            )
            self.focusObserver = nil
            lastFocusedWindowID = nil
        }
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier, AXIsProcessTrusted() else {
            return
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.focusCallback, &created) == .success, let observer = created else {
            return
        }
        // Unretained: the follower outlives its observer, which `stop` removes
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let application = AXUIElementCreateApplication(pid)
        // Switching back to a window on another Space may only change the
        // main window: Ghostty reports nothing else then
        let notifications = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]
        var subscribed = false
        for notification in notifications {
            subscribed = AXObserverAddNotification(observer, application, notification as CFString, refcon)
                == .success || subscribed
        }
        guard subscribed else {
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        focusObserver = (pid, observer)
    }

    private static let focusCallback: AXObserverCallback = { _, element, _, refcon in
        var windowID: CGWindowID = 0
        guard let refcon, _AXUIElementGetWindow(element, &windowID) == .success else {
            return
        }
        let follower = Unmanaged<AppActivationFollower>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated {
            follower.handleFocusedWindowChange(windowID)
        }
    }

    private func handleFocusedWindowChange(_ windowID: CGWindowID) {
        // A focus change and a main window change name the same window
        // back to back
        let previousWindowID = lastFocusedWindowID
        lastFocusedWindowID = windowID
        guard windowID != previousWindowID, let pid = focusObserver?.pid, shouldConsiderActivations else {
            return
        }
        let now = Date()
        if let lastFocusFollow, lastFocusFollow.windowID == windowID,
           now.timeIntervalSince(lastFocusFollow.date) < Self.echoWindow
        {
            return
        }
        let conn = _CGSDefaultConnection()
        guard let onScreen = onScreenWindowsIfFollowable(pid: pid, now: now) else {
            return
        }
        // A switch leaves the previous window in view until the Space goes;
        // closing or minimizing it hands focus on with the window already
        // gone, and following then would carry the user off to another Space
        if let previousWindowID,
           !onScreen.contains(where: { $0[kCGWindowNumber as String] as? Int == Int(previousWindowID) })
        {
            Self.logger.debug("focus of wid=\(windowID) ruled out: wid=\(previousWindowID) closed or minimized")
            return
        }
        let layout = Self.spaceLayout(connection: conn)
        // The focused window alone decides: the app's other windows say
        // nothing about where this one lives
        guard let candidate = Self.windowCandidate(windowID, connection: conn, onScreen: onScreen),
              let target = Self.targetSpaceID(
                  for: [candidate],
                  activeSpaceIDs: layout.active,
                  followableSpaceIDs: layout.followable
              )
        else {
            Self.logger.debug("focus of wid=\(windowID) needs no switch")
            return
        }
        Self.logger.info("following focus of pid=\(pid) wid=\(windowID) to space \(target)")
        lastFocusFollow = (windowID, now)
        follow(pid: pid, to: target, now: now)
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
        settlingFollows.removeAll { now.timeIntervalSince($0.date) >= Self.followSettleWindow }
        let active = Self.spaceLayout(connection: _CGSDefaultConnection()).active
        if settlingFollows.contains(where: { active.contains($0.spaceID) }) {
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
        // the user is. In view on a Space that is not current means the
        // Dock's slide there has begun and is drawing it, which is exactly
        // the slide to preempt.
        let isInView = { (window: WindowCandidate) in
            window.isOnScreen && (window.spaceIDs.isEmpty || !activeSpaceIDs.isDisjoint(with: window.spaceIDs))
        }
        if considered.contains(where: { isInView($0) || $0.spaceIDs.count > 1 }) {
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
            candidate(window.id, isOnScreen: window.isOnScreen, states: states, connection: connection)
        }
    }

    private static func windowCandidate(
        _ windowID: CGWindowID,
        connection: Int32,
        onScreen: [[String: Any]]
    ) -> WindowCandidate? {
        let id = Int(windowID)
        let isOnScreen = onScreen.contains { $0[kCGWindowNumber as String] as? Int == id }
        let states = CGSDisplaySpaceProvider.windowServerStates([id], connection: connection)
        return candidate(id, isOnScreen: isOnScreen, states: states, connection: connection)
    }

    /// Nil for a window the window server no longer knows. `states` nil
    /// means the query failed, and the window then counts as open.
    private static func candidate(
        _ id: Int,
        isOnScreen: Bool,
        states: [Int: (attributes: UInt64, tags: UInt64)]?,
        connection: Int32
    ) -> WindowCandidate? {
        var isMinimized = false
        var isClosed = false
        if let states {
            guard let state = states[id] else {
                return nil
            }
            isClosed = !CGSDisplaySpaceProvider.isSpaceOccupant(attributes: state.attributes, tags: state.tags)
            isMinimized = state.tags & CGSDisplaySpaceProvider.minimizedTags != 0
        }
        // Selector 0x7 = all spaces the window is on
        let spaces = SLSCopySpacesForWindows(connection, 0x7, [id] as CFArray)?
            .takeRetainedValue() as? [Int] ?? []
        return WindowCandidate(spaceIDs: spaces, isOnScreen: isOnScreen, isMinimized: isMinimized, isClosed: isClosed)
    }

    /// From the session's HID state, so it covers input to every app
    private static var lastInputDate: Date {
        let seconds = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown].map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? .infinity
        return Date(timeIntervalSinceNow: -seconds)
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
