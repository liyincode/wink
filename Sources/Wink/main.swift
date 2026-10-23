import AppKit
import Carbon
import Darwin
import ScreenCore

let journalURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("ScreenPause/restore.json")

func report(_ error: Error) {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
}

let arguments = CommandLine.arguments
let commandArguments = Array(arguments.dropFirst())
if commandArguments.first == "--help" || commandArguments.first == "-h" {
    print("Usage: wink <blackout|restore|status> [--json]\nRequires Wink.app to be running. All commands return JSON. blackout/restore wait for completion.")
    exit(0)
}
if let first = commandArguments.first,
   AgentCommand(rawValue: first) != nil || !["--probe", "--restore", "--cycle-test", "--settings", "-AppleLanguages", "-AppleLocale", "-NSDocumentRevisionsDebugMode"].contains(first) {
    let response: AgentResponse
    if let command = AgentCommand.parse(commandArguments) { response = AgentIPC.request(command) }
    else { response = .failure("invalid_arguments", "Usage: wink <blackout|restore|status> [--json]") }
    do { FileHandle.standardOutput.write(try response.json()) }
    catch { report(error); exit(1) }
    exit(response.ok ? 0 : 1)
}
if arguments.contains("--probe") {
    do {
        for screen in try SystemGamma().capture() {
            print("display=\(screen.id) samples=\(screen.red.count) gammaPeak=\(screen.peak)")
        }
        exit(0)
    } catch { report(error); exit(1) }
}

let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "local.liyin.screenpause")
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if !existing.isEmpty {
    report(ScreenError(L10n.text("Wink is already running. Use the menu bar or shortcut.")))
    exit(1)
}

// Also exclude concurrent command-line sessions, which need not appear in NSWorkspace.
do {
    try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
} catch { report(error); exit(1) }
let lockFD = open(journalURL.deletingLastPathComponent().appendingPathComponent("session.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
    report(ScreenError(L10n.text("Another Wink session is running. Displays were not changed.")))
    exit(1)
}

if arguments.contains("--restore") || arguments.contains("--cycle-test") {
    let session = BlackoutSession(journal: journalURL)
    do {
        try session.recover()
        if arguments.contains("--cycle-test") {
            let before = try SystemGamma().capture()
            try session.blackout()
            print("BLACKOUT: \(before.count) displays; restoring in 10 seconds")
            Thread.sleep(forTimeInterval: 10)
            try session.restore()
            let after = try SystemGamma().capture()
            guard before.count == after.count else { throw ScreenError(L10n.text("The number of displays changed after restoration.")) }
            for original in before {
                guard let restored = after.first(where: { $0.id == original.id }), restored.red.count == original.red.count else {
                    throw ScreenError(L10n.text("The displays or Gamma table sizes do not match after restoration."))
                }
                let originalSamples = original.red + original.green + original.blue
                let restoredSamples = restored.red + restored.green + restored.blue
                let delta: Float = zip(originalSamples, restoredSamples)
                    .map { abs($0 - $1) }.max() ?? 0
                guard delta < 0.002 else { throw ScreenError(L10n.text("Gamma differs too much after restoration: %@.", String(delta))) }
                print("RESTORED: \(original.id), maxDelta=\(delta)")
            }
        }
        print("PASS")
        exit(0)
    } catch { report(error); exit(1) }
}

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { display, flags, context in
    guard let context else { return }
    let owner = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
    let beginning = flags.contains(.beginConfigurationFlag)
    NSLog("Wink display event: id=%u flags=%u", display, flags.rawValue)
    DispatchQueue.main.async { owner.displayConfigurationChanged(beginning: beginning) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = BlackoutSession(journal: journalURL)
    var status: NSStatusItem!
    var toggleItem: NSMenuItem!
    var hotKeys: [EventHotKeyRef] = []
    var eventHandler: EventHandlerRef?
    var fade = ScreenFade()
    var fadeTimer: Timer?
    var lastFadeTime: TimeInterval = 0
    var monitor: Timer?
    var displaySettleTimer: Timer?
    var displayCallbackRegistered = false
    var showingError = false
    var reportedDisplayError: String?
    let awake = KeepAwake()
    let lidMonitor = LidMonitor()
    var observers: [NSObjectProtocol] = []
    var contextMenu: NSMenu!
    var shortcutItem: NSMenuItem!
    var toggleShortcut = KeyboardShortcut.load()
    var toggleHotKey: EventHotKeyRef?
    var settings: ShortcutSettings?
    var panel: ScreenPanel?
    var schedule = BlackoutSchedule.load()
    var scheduleRunner = ScheduleRunner(skippedUntil: UserDefaults.standard.object(forKey: "scheduleSkippedUntil") as? Date)
    var scheduleTimer: Timer?
    let agentServer = AgentServer()
    var agentReplies: [(AgentResponse) -> Void] = []
    var agentTargetBlack: Bool?


    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = Mascot.wink
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        toggleItem = menu.addItem(withTitle: L10n.text("Black Out"), action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        shortcutItem = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        let controls = menu.addItem(withTitle: L10n.text("Open Wink…"), action: #selector(showPanel), keyEquivalent: "")
        controls.target = self
        let preferences = menu.addItem(withTitle: L10n.text("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(.separator())
        let restore = menu.addItem(withTitle: L10n.text("Restore Display"), action: #selector(restoreScreens), keyEquivalent: "")
        restore.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: L10n.text("Restore and Quit"), action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.insertItem(withTitle: L10n.text("About Wink"), action: #selector(showAbout), keyEquivalent: "", at: menu.items.count - 1).target = self
        contextMenu = menu
        status.button?.target = self
        status.button?.action = #selector(statusClicked)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatus()
        do { try session.recover() } catch { showError(error) }
        updateStatus()
        startMonitor()
        displayCallbackRegistered = CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()) == .success
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.displayConfigurationChanged(beginning: false) })
        registerShortcuts()
        if arguments.contains("--settings") { showSettings() } else { showPanel() }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            do { try self.awake.didWake(lidClosed: self.lidMonitor.isClosed()) }
            catch {
                try? self.awake.didWake(lidClosed: true)
                self.showError(error)
            }
            self.displayConfigurationChanged(beginning: false)
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displayConfigurationChanged(beginning: false)
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if name == NSWorkspace.willSleepNotification { self?.awake.willSleep() }
                self?.cancelScheduleOccurrence()
                self?.performRestore()
            })
        }
        do {
            let closed = try lidMonitor.start { [weak self] closed in
                guard let self else { return }
                do { try self.awake.lidChanged(closed: closed) } catch { self.showError(error) }
            }
            try awake.start(lidClosed: closed)
        } catch { showError(error) }
        scheduleTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkSchedule() }
        RunLoop.main.add(scheduleTimer!, forMode: .common)
        do {
            try agentServer.start { [weak self] command, reply in
                guard let self else { reply(.failure("unavailable", "Wink is shutting down.")); return }
                self.handleAgentCommand(command, reply: reply)
            }
        } catch { report(error) }
    }

    @objc func showAbout() {
        if session.isActive, performRestore() != nil { return }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: AppInfo.aboutOptions)
    }

    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            guard let button = status.button else { return }
            contextMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        } else { toggle() }
    }

    @objc func showSettings() {
        if session.isActive { cancelScheduleOccurrence(); if performRestore() != nil { return } }
        if settings == nil {
            settings = ShortcutSettings(current: toggleShortcut, schedule: schedule)
            settings?.apply = { [weak self] value in self?.setToggleShortcut(value) }
            settings?.applySchedule = { [weak self] value in
                guard let self else { return nil }
                do { try value.save() } catch { return error.localizedDescription }
                self.schedule = value
                self.updateStatus()
                return nil
            }
        }
        showPanel()
        if let settings { panel?.showSettings(settings) }
    }

    @objc func showPanel() {
        if panel == nil {
            panel = ScreenPanel()
            panel?.toggle = { [weak self] in
                self?.toggle()
            }
            panel?.openSettings = { [weak self] in self?.showSettings() }
        }
        updateStatus()
        panel?.present()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func setToggleShortcut(_ value: KeyboardShortcut) -> String? {
        if let error = value.validationError { return error }
        if value.keyCode == toggleShortcut.keyCode && value.modifiers == toggleShortcut.modifiers && toggleHotKey != nil { return nil }
        var next: EventHotKeyRef?
        let result = RegisterEventHotKey(value.keyCode, value.modifiers, EventHotKeyID(signature: 0x53505253, id: 3),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &next)
        guard result == noErr, let next else {
            return L10n.text("%@ is unavailable or could not be registered. Choose another combination. Your existing shortcut has been kept.", String(value.display))
        }
        do { try value.save() } catch { UnregisterEventHotKey(next); return error.localizedDescription }
        if let old = toggleHotKey { UnregisterEventHotKey(old) }
        toggleHotKey = next
        toggleShortcut = value
        updateStatus()
        return nil
    }

    func registerShortcuts() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard result == noErr else { return result }
            let owner = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            if owner.settings?.isRecording == true {
                if hotKey.id == 3 { owner.settings?.select(owner.toggleShortcut) }
                else { owner.settings?.reservedShortcutPressed() }
                return noErr
            }
            switch hotKey.id {
            case 1, 3: owner.toggle()
            case 2: owner.restoreScreens()
            default: return OSStatus(eventNotHandledErr)
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard installed == noErr else { showError(ScreenError(L10n.text("Unable to register global shortcuts. Use the menu bar."))); return }
        for (id, key) in [(UInt32(1), UInt32(kVK_ANSI_B)), (UInt32(2), UInt32(kVK_ANSI_R))] {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(key, UInt32(controlKey | optionKey | cmdKey),
                                            EventHotKeyID(signature: 0x53505253, id: id), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
            if result == noErr, let ref { hotKeys.append(ref) }
            else { showError(ScreenError(L10n.text("The shortcut is unavailable or could not be registered. Use the menu bar."))) }
        }
        if let error = setToggleShortcut(toggleShortcut) {
            showSettings()
            settings?.update(message: error + L10n.text(" Use ⌃⌥⌘R to restore your displays."), error: true)
        }
    }

    @objc func toggle() {
        if fade.targetBlack || (session.isActive && fadeTimer == nil) {
            restoreScreens()
        } else {
            startFade(toBlack: true)
        }
    }

    func startFade(toBlack: Bool) {
        if let target = agentTargetBlack, target != toBlack {
            finishAgentRequests(.failure("interrupted", "Another action changed the target. Query status before retrying."))
        }
        if !toBlack && !session.isActive {
            if session.hasPendingRecovery { performRestore() }
            return
        }
        do {
            if toBlack && !session.isActive {
                try awake.refresh()
                guard awake.isActive else { throw ScreenError(L10n.text("Unable to keep the display session active. Displays were not darkened.")) }
                try session.prepareDimming()
            }
            fade.target(toBlack)
            fadeTimer?.invalidate()
            lastFadeTime = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.advanceFade() }
            fadeTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            updateStatus()
        } catch {
            handleFadeFailure(error)
        }
    }

    func advanceFade() {
        guard !session.isReconfiguringDisplays else { return }
        let now = ProcessInfo.processInfo.systemUptime
        fade.advance(seconds: now - lastFadeTime)
        lastFadeTime = now
        do {
            try session.setDimming(fade.dimming)
            panel?.setEyeClosure(fade.eyeClosure)
            if !fade.isRunning {
                fadeTimer?.invalidate(); fadeTimer = nil
                if !fade.targetBlack {
                    try session.restore()
                }
                updateStatus()
                if !agentReplies.isEmpty { finishAgentRequests(agentStatusResponse()) }
            }
        } catch let error as DisplayUnavailableError {
            if !fade.isRunning { fadeTimer?.invalidate(); fadeTimer = nil }
            updateStatus()
            finishAgentRequests(.failure("display_unavailable", error.localizedDescription))
            reportDisplayUnavailable(error)
        } catch {
            handleFadeFailure(error)
        }
    }

    func startMonitor() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkDisplays() }
        monitor = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func displayConfigurationChanged(beginning: Bool) {
        NSLog("Wink display configuration: %@, blackout=%d", beginning ? "begin" : "changed", session.isDimming)
        session.displayConfigurationChanged(beginning: beginning)
        startDisplaySettling()
        if !beginning { checkDisplays() }
    }

    func startDisplaySettling() {
        guard displaySettleTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.checkDisplays()
            if !self.session.isSettlingDisplays {
                self.displaySettleTimer?.invalidate(); self.displaySettleTimer = nil
            }
        }
        displaySettleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func checkDisplays() {
        guard fadeTimer == nil, !showingError else { return } // Fade frames reconcile connections themselves.
        do {
            let wasActive = session.isActive
            try session.synchronizeDisplays()
            if session.isSettlingDisplays { startDisplaySettling() }
            if session.isDimming { try session.verifyBlackout() }
            if !session.hasUnavailableDisplays { reportedDisplayError = nil }
            if session.isActive != wasActive {
                fade.reset(isBlack: session.isActive)
                updateStatus()
            }
        } catch let error as DisplayUnavailableError {
            reportDisplayUnavailable(error)
        } catch {
            guard reportedDisplayError != error.localizedDescription else { return }
            reportedDisplayError = error.localizedDescription
            cancelScheduleOccurrence()
            let recoveryError = performRestore(reportErrors: false)
            showError(recoveryError ?? error)
        }
    }

    func reportDisplayUnavailable(_ error: DisplayUnavailableError) {
        guard reportedDisplayError != error.localizedDescription else { return }
        reportedDisplayError = error.localizedDescription
        showError(error)
    }

    func cancelScheduleOccurrence() {
        scheduleRunner.cancel(at: Date(), schedule: schedule)
        saveScheduleSkip()
    }

    @objc func restoreScreens() {
        cancelScheduleOccurrence()
        startFade(toBlack: false)
    }

    @discardableResult
    func performRestore(reportErrors: Bool = true) -> Error? {
        finishAgentRequests(.failure("interrupted", "Immediate restoration interrupted the operation. Query status before retrying."))
        fadeTimer?.invalidate(); fadeTimer = nil
        var failure: Error?
        do { try session.restore() } catch { failure = error }
        fade.reset(isBlack: session.isActive)
        updateStatus()
        if reportErrors, let failure { showError(failure) }
        return failure
    }

    func handleFadeFailure(_ error: Error) {
        let replies = agentReplies
        agentReplies = []; agentTargetBlack = nil
        cancelScheduleOccurrence()
        let recoveryError = performRestore(reportErrors: false)
        if replies.isEmpty { showError(recoveryError ?? error) }
        else {
            let message = (recoveryError ?? error).localizedDescription
            for reply in replies { reply(.failure("operation_failed", message)) }
        }
    }

    func agentStatusResponse() -> AgentResponse {
        let state: String
        if fadeTimer != nil { state = fade.targetBlack ? "darkening" : "restoring" }
        else if session.isActive {
            do { state = try session.isBlack() ? "black" : "recovery_required" }
            catch { return .failure("display_error", error.localizedDescription) }
        } else { state = "visible" }
        return .success(AgentStatus(state: state, target: fade.targetBlack ? "black" : "visible",
                                   progress: fade.progress, recoveryPending: session.hasPendingRecovery,
                                   scheduleEnabled: schedule.enabled))
    }

    func finishAgentRequests(_ response: AgentResponse) {
        let replies = agentReplies
        agentReplies = []; agentTargetBlack = nil
        for reply in replies { reply(response) }
    }

    func handleAgentCommand(_ command: AgentCommand, reply: @escaping (AgentResponse) -> Void) {
        if command == .status { reply(agentStatusResponse()); return }
        let black = command == .blackout
        if agentTargetBlack == black {
            guard agentReplies.count < 64 else { reply(.failure("busy", "Too many pending requests.")); return }
            agentReplies.append(reply)
            return
        }
        if !agentReplies.isEmpty {
            finishAgentRequests(.failure("interrupted", "Another command changed the target. Query status before retrying."))
        }
        if !black {
            cancelScheduleOccurrence()
            if fadeTimer == nil && !session.isActive && session.hasPendingRecovery {
                if let error = performRestore(reportErrors: false) { reply(.failure("recovery_required", error.localizedDescription)) }
                else { reply(agentStatusResponse()) }
                return
            }
        }
        if fadeTimer == nil && session.isActive == black {
            let response = agentStatusResponse()
            if black && response.status?.state == "recovery_required" {
                reply(.failure("recovery_required", "Display state changed. Restore before requesting blackout again."))
            } else { reply(response) }
            return
        }
        agentTargetBlack = black
        agentReplies = [reply]
        // A matching transition already in flight must not restart on a retry.
        if fadeTimer != nil && fade.targetBlack == black { return }
        startFade(toBlack: black)
    }

    func saveScheduleSkip() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "scheduleSkippedUntil") as? Date != scheduleRunner.skippedUntil {
            defaults.set(scheduleRunner.skippedUntil, forKey: "scheduleSkippedUntil")
        }
    }

    func checkSchedule() {
        // Never darken the screen while the user is editing settings.
        guard !(panel?.settingsExpanded == true && panel?.window?.isVisible == true), fadeTimer == nil else { return }
        let action = scheduleRunner.step(at: Date(), schedule: schedule, isBlack: session.isActive)
        saveScheduleSkip()
        switch action {
        case .blackout:
            toggle()
            if !session.isActive {
                scheduleRunner.cancel(at: Date(), schedule: schedule)
                saveScheduleSkip()
            }
        case .restore: startFade(toBlack: false)
        case .none: break
        }
    }

    func updateStatus() {
        status.button?.image = Mascot.menuIcon(isBlack: session.isActive)
        let recovery = toggleHotKey == nil ? "⌃⌥⌘B" : toggleShortcut.display
        let targetBlack = fadeTimer == nil ? session.isActive : fade.targetBlack
        panel?.update(isBlack: targetBlack, recovery: recovery, schedule: schedule)
        panel?.setEyeClosure(fade.eyeClosure)
        status.button?.toolTip = targetBlack ? L10n.text("Click or press %@ to restore displays; right-click for the menu", String(recovery)) : L10n.text("Click or press %@ to black out; right-click for the menu", String(recovery))
        shortcutItem.title = L10n.text("Toggle: %@ · Backup restore: ⌃⌥⌘R", String(recovery))
        toggleItem.title = targetBlack ? L10n.text("Restore Display") : L10n.text("Black Out")
    }

    func showError(_ error: Error) {
        NSLog("Wink display error: %@", error.localizedDescription)
        showingError = true
        defer { showingError = false }
        let alert = NSAlert()
        alert.messageText = "Wink"
        alert.informativeText = error.localizedDescription
        let canRetry = session.hasPendingRecovery && !session.isDimming
        if canRetry { alert.addButton(withTitle: L10n.text("Retry Restore")) }
        alert.addButton(withTitle: L10n.text("OK"))
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if canRetry && response == .alertFirstButtonReturn {
            if let failure = performRestore(reportErrors: false) { showError(failure) }
        }
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        awake.stop()
        lidMonitor.stop()
        displaySettleTimer?.invalidate()
        if displayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        cancelScheduleOccurrence()
        performRestore()
        if !session.isActive { awake.stop(); agentServer.stop() }
        return session.isActive ? .terminateCancel : .terminateNow
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
