import AppKit
import ArgumentParser
import Foundation

@main
struct Parrot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parrot",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Install.self],
        defaultSubcommand: Run.self
    )

    static func main() {
        AppBundle.reexecThroughSymlinkIfNeeded()
        Self.main(nil)
    }

    /// Another process with Parrot's bundle id, if any. A bare `swift run`
    /// binary has no bundle id and so is not seen by other instances, but it
    /// does see (and defers to) an installed Parrot.app.
    static func otherRunningInstance() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: AppBundle.identifier)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Launched by launchd / Launch Services there is no terminal; keep
        // stderr somewhere `tail -f` can find it.
        if isatty(STDERR_FILENO) == 0 {
            freopen(KeepAliveAgent.errLog, "a", stderr)
        }

        // Single instance: a second launch (Spotlight, Launchpad, the CLI,
        // a stray LaunchAgent) must never start a second recorder.
        if let other = Parrot.otherRunningInstance() {
            FileHandle.standardError.write(Data("Parrot is already running (pid \(other.processIdentifier)); showing it\n".utf8))
            if let url = other.bundleURL {
                // Launch Services delivers this as a reopen to the running
                // instance, which pops the menu-bar menu.
                NSWorkspace.shared.open(url)
            } else {
                other.activate()
            }
            throw ExitCode(0)
        }

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        UserNotifier.shared.install()

        let controller = AppController(root: root)
        let delegate = AppDelegate(controller: controller)
        app.delegate = delegate

        // ^C in a terminal and SIGTERM from launchd both go through the same
        // path as Quit / logout: NSApp.terminate -> applicationShouldTerminate.
        let signals = [SIGINT, SIGTERM].map { sig in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                FileHandle.standardError.write(Data("\nshutting down\n".utf8))
                MainActor.assumeIsolated { controller.shutdown() }
            }
            source.resume()
            signal(sig, SIG_IGN)
            return source
        }
        delegate.signalSources = signals

        FileHandle.standardError.write(
            Data(
                "parrot up · recordings → \(root.path) · \(AppBundle.isBundled ? "Quit from the menu bar" : "^C to quit")\n".utf8
            ))
        app.run()
    }
}

/// Application lifecycle glue: reopen pops the menu, termination finalizes a
/// live recording first.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller: AppController
    var signalSources: [DispatchSourceSignal] = []

    init(controller: AppController) {
        self.controller = controller
    }

    /// Spotlight / Launchpad / `open -a Parrot` while already running: there
    /// is no window to show, so show where the app lives instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.showMenu()
        return false
    }

    /// Quit, logout, shutdown, SIGINT/SIGTERM all land here. RecordingSession
    /// .stop() is synchronous (it tears down the tracks and writes meta.json
    /// before returning), so the stop never needs the run loop and we can
    /// answer .terminateNow; a pending transcript is picked up by the
    /// filesystem queue on next launch. Switch to .terminateLater + reply if
    /// stop ever becomes asynchronous.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.stopForTermination()
        return .terminateNow
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private var session: RecordingSession?
    private var captureStatus = RecordingSession.CaptureStatus.allHealthy
    private var ticker: Timer?

    init(root: URL) {
        self.root = root
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.onToggleLaunchAtLogin = { [weak self] in self?.toggleLaunchAtLogin() }
        menuBar.onOpenLoginItems = { LoginItem.openSettings() }
        menuBar.onMenuWillOpen = { [weak self] in self?.refreshLaunchAtLogin() }
        menuBar.update(.idle)
        menuBar.updateLaunchAtLogin(LoginItem.status)

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Quit. The live session (if any) is finalized in
    /// applicationShouldTerminate, which this triggers.
    func shutdown() {
        NSApp.terminate(nil)
    }

    /// Stop a live session cleanly (finalizing files) ahead of process exit.
    /// Idempotent; safe when nothing is recording.
    func stopForTermination() {
        stopSession()
    }

    /// Pop the status-bar menu (reopen from Spotlight / Launchpad).
    func showMenu() {
        menuBar.showMenu()
    }

    private func toggleLaunchAtLogin() {
        do {
            if LoginItem.isEnabled {
                try LoginItem.unregister()
            } else {
                LegacyAgent.remove()
                try KeepAliveAgent.remove()
                try LoginItem.register()
            }
        } catch {
            FileHandle.standardError.write(Data("launch at login change failed: \(error)\n".utf8))
            notifyUser(title: "Parrot — launch at login", body: "\(error.localizedDescription)")
        }
        menuBar.updateLaunchAtLogin(LoginItem.status)
    }

    /// Called when the menu is about to open so the checkmark reflects a
    /// change made in System Settings.
    private func refreshLaunchAtLogin() {
        menuBar.updateLaunchAtLogin(LoginItem.status)
    }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startSession() {
        do {
            let newSession = try RecordingSession(root: root)
            newSession.onStatus = { [weak self] status in
                self?.captureStatus = status
                self?.refreshMenu()
            }
            newSession.onDegraded = { kind in
                // The session fires this once per degradation episode, so the
                // user gets one notification, not one per watchdog tick.
                notifyUser(
                    title: "Parrot — \(kind.label) capture lost",
                    body: "Recovery failed; the recording will be marked incomplete."
                )
            }
            try newSession.start()
            session = newSession
            captureStatus = .allHealthy
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "Parrot — recording failed", body: "\(error)")
            return
        }

        refreshMenu()
        // Explicitly .common so the elapsed counter and menu state keep
        // updating while the menu is open (event-tracking run-loop mode).
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopSession() {
        guard let session else { return }
        let result = session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(
            Data(
                "○ stopped · \(elapsed) · \(result.status.rawValue) · \(session.dir.path)\n".utf8
            ))
        self.session = nil
        captureStatus = .allHealthy
        ticker?.invalidate()
        ticker = nil
        menuBar.update(.idle)

        // Warn about a gap before the later "transcript ready" notification
        // implies everything went fine. Transcription still runs — recovered
        // and incomplete sessions keep whatever audio they have.
        switch result.status {
        case .complete:
            break
        case .recovered:
            notifyUser(
                title: "Parrot — recording recovered",
                body: "Capture was interrupted and resumed; see meta.json for the gap."
            )
        case .incomplete:
            notifyUser(
                title: "Parrot — recording incomplete",
                body: "Part of the session was not captured; see meta.json."
            )
        }
        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    /// Rebuild the menu presentation from capture status plus elapsed time.
    private func refreshMenu() {
        guard let session else { return }
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        let display: MenuBarController.Display
        switch captureStatus.display {
        case .healthy:
            display = .recording(elapsed: elapsed)
        case .recovering(let kind):
            display = .recovering(track: kind.label, elapsed: elapsed)
        case .degraded(let kind):
            display = .degraded(track: kind.label, elapsed: elapsed)
        }
        menuBar.update(display, signalWarning: captureStatus.signalWarning)
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        refreshMenu()
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
