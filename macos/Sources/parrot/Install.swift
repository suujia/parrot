import ArgumentParser
import Foundation
import ServiceManagement

/// Launch at login.
///
/// Default mechanism: `SMAppService.mainApp` (System Settings > General >
/// Login Items shows "Parrot" with its icon; survives reboots; the user can
/// toggle it there or from the menu-bar menu). It only exists for a real
/// bundle, so this command must run from Parrot.app — the `/usr/local/bin/
/// parrot` symlink is fine, a `swift run` binary is not.
///
/// SMAppService does not relaunch the app after a crash. The pre-0.2 hand-
/// written LaunchAgent did (KeepAlive). That behaviour is kept, opt-in, as
/// `install --launch-at-login --keep-alive`, which writes a LaunchAgent that
/// points at the bundle's executable instead of registering a login item.
/// Exactly one of the two mechanisms is active at a time.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Register or remove Parrot as a login item."
    )

    @Flag(name: .long, help: "Start Parrot at login (System Settings > Login Items).")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "With --launch-at-login: use a KeepAlive LaunchAgent that also restarts Parrot after a crash.")
    var keepAlive: Bool = false

    @Flag(name: .long, help: "Stop starting Parrot at login (removes both mechanisms).")
    var uninstall: Bool = false

    func run() throws {
        if launchAtLogin == uninstall {
            FileHandle.standardError.write(Data("specify exactly one of --launch-at-login or --uninstall\n".utf8))
            throw ExitCode(64)
        }
        if keepAlive && uninstall {
            FileHandle.standardError.write(Data("--keep-alive only applies to --launch-at-login\n".utf8))
            throw ExitCode(64)
        }

        // Two copies must never start: whatever we are about to install, the
        // pre-rename agent goes first.
        LegacyAgent.remove()

        if uninstall {
            try KeepAliveAgent.remove()
            try LoginItem.unregister()
            print("✓ launch at login removed")
            return
        }

        guard AppBundle.isBundled else {
            FileHandle.standardError.write(
                Data("launch at login needs Parrot.app; run ./scripts/build-macos-app && ./scripts/install-macos first\n".utf8))
            throw ExitCode(1)
        }

        if keepAlive {
            try LoginItem.unregister()
            let url = try KeepAliveAgent.write()
            print("✓ launch at login installed (KeepAlive LaunchAgent)")
            print("  plist:  \(url.path)")
            print("  app:    \(Bundle.main.bundleURL.path)")
            print("  logs:   \(KeepAliveAgent.outLog), \(KeepAliveAgent.errLog)")
        } else {
            try KeepAliveAgent.remove()
            try LoginItem.register()
            print("✓ launch at login installed (\(LoginItem.describe()))")
            print("  app:    \(Bundle.main.bundleURL.path)")
            if LoginItem.status == .requiresApproval {
                print("  approve Parrot under System Settings > General > Login Items")
            }
        }
    }
}

/// SMAppService.mainApp, guarded so a bare binary never touches it.
enum LoginItem {
    static var status: SMAppService.Status {
        guard AppBundle.isBundled else { return .notFound }
        return SMAppService.mainApp.status
    }

    static var isEnabled: Bool { status == .enabled }

    static func register() throws {
        try SMAppService.mainApp.register()
    }

    static func unregister() throws {
        guard AppBundle.isBundled, SMAppService.mainApp.status != .notRegistered else { return }
        try SMAppService.mainApp.unregister()
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func describe() -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval in Login Items"
        case .notRegistered: return "not registered"
        case .notFound: return AppBundle.isBundled ? "not found" : "unavailable outside Parrot.app"
        @unknown default: return "unknown"
        }
    }
}

/// Opt-in KeepAlive LaunchAgent pointing at the bundle executable.
enum KeepAliveAgent {
    static let label = AppBundle.identifier
    static let outLog = "/tmp/parrot.out.log"
    static let errLog = "/tmp/parrot.err.log"

    static var plistURL: URL {
        LaunchAgents.directory.appendingPathComponent("\(label).plist")
    }

    static func write() throws -> URL {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [Bundle.main.executableURL!.path, "run"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ProcessType": "Interactive",
            "StandardOutPath": outLog,
            "StandardErrorPath": errLog,
        ]
        let url = plistURL
        try FileManager.default.createDirectory(at: LaunchAgents.directory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)

        _ = LaunchAgents.launchctl(["bootout", LaunchAgents.domain, url.path])
        let result = LaunchAgents.launchctl(["bootstrap", LaunchAgents.domain, url.path])
        if result.status != 0 {
            FileHandle.standardError.write(Data("warning: launchctl bootstrap exited \(result.status):\n\(result.stderr)\n".utf8))
        }
        return url
    }

    static func remove() throws {
        let url = plistURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        _ = LaunchAgents.launchctl(["bootout", LaunchAgents.domain, url.path])
        try FileManager.default.removeItem(at: url)
        print("✓ removed KeepAlive agent \(url.path)")
    }
}

/// The pre-rename LaunchAgent (quill). Booted out and deleted whenever launch
/// at login is (re)configured so the old copy can't start next to Parrot.
enum LegacyAgent {
    static let label = "com.digimata.quill"

    static func remove() {
        let url = LaunchAgents.directory.appendingPathComponent("\(label).plist")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        _ = LaunchAgents.launchctl(["bootout", LaunchAgents.domain, url.path])
        do {
            try FileManager.default.removeItem(at: url)
            print("✓ removed legacy agent \(url.path)")
        } catch {
            FileHandle.standardError.write(Data("warning: could not remove \(url.path): \(error)\n".utf8))
        }
    }
}

enum LaunchAgents {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    static var domain: String { "gui/\(getuid())" }

    static func launchctl(_ args: [String]) -> (status: Int32, stderr: String) {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            return (-1, "\(error)")
        }
        task.waitUntilExit()
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (task.terminationStatus, err)
    }
}
