import Foundation

/// Where the running executable lives. Parrot behaves slightly differently
/// when it runs from Parrot.app (the installed, signed bundle) than from a
/// bare `swift run parrot` binary during development: UserNotifications and
/// SMAppService both require a bundle, so their users feature-detect here.
enum AppBundle {
    static let identifier = "com.suujia.parrot"

    static let defaultInstallURL = URL(fileURLWithPath: "/Applications/Parrot.app", isDirectory: true)

    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// If we were started through a symlink (`/usr/local/bin/parrot` ->
    /// `Parrot.app/Contents/MacOS/parrot`), Foundation resolves `Bundle.main`
    /// from the symlink path and cannot see the bundle. Re-exec the real
    /// executable so the process has its bundle identity (TCC attribution,
    /// SMAppService, notifications) regardless of how it was invoked.
    static func reexecThroughSymlinkIfNeeded() {
        guard !isBundled, let invoked = Bundle.main.executableURL else { return }
        let real = invoked.resolvingSymlinksInPath()
        guard real.path != invoked.path, real.pathComponents.contains("Contents"),
            real.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().pathExtension == "app"
        else { return }
        var args = CommandLine.arguments.map { strdup($0) }
        args[0] = strdup(real.path)
        args.append(nil)
        execv(real.path, args)
        // execv only returns on failure; carry on as the bare binary.
        FileHandle.standardError.write(Data("warning: could not re-exec \(real.path): \(String(cString: strerror(errno)))\n".utf8))
    }
}
