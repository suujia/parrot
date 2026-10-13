import AppKit
import ServiceManagement

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// What the menu communicates about capture. Recovering and degraded are
    /// distinct from healthy recording so a user glancing mid-meeting can see
    /// that something happened; elapsed time stays visible in every recording
    /// state.
    enum Display: Equatable {
        case idle
        case recording(elapsed: String)
        case recovering(track: String, elapsed: String)
        case degraded(track: String, elapsed: String)
    }

    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let warningLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let launchAtLoginItem: NSMenuItem
    private let approvalLabel: NSMenuItem
    private let openLoginItemsItem: NSMenuItem

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var onOpenLoginItems: (() -> Void)?
    var onMenuWillOpen: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        warningLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        warningLabel.isEnabled = false
        warningLabel.isHidden = true
        menu.addItem(warningLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        menu.addItem(.separator())

        launchAtLoginItem = NSMenuItem(
            title: "Launch at login",
            action: #selector(launchAtLoginClicked),
            keyEquivalent: ""
        )
        menu.addItem(launchAtLoginItem)

        approvalLabel = NSMenuItem(title: "Approve Parrot in Login Items to finish", action: nil, keyEquivalent: "")
        approvalLabel.isEnabled = false
        approvalLabel.isHidden = true
        approvalLabel.indentationLevel = 1
        menu.addItem(approvalLabel)

        openLoginItemsItem = NSMenuItem(
            title: "Open Login Items settings…",
            action: #selector(openLoginItemsClicked),
            keyEquivalent: ""
        )
        openLoginItemsItem.isHidden = true
        openLoginItemsItem.indentationLevel = 1
        menu.addItem(openLoginItemsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Parrot",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        super.init()

        for item in [toggleItem, openFolder, launchAtLoginItem, openLoginItemsItem, quit] {
            item.target = self
        }

        menu.delegate = self
        statusItem.menu = menu

        if let button = statusItem.button {
            let image = Self.featherImage()
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
        }
    }

    /// Reflect capture state in the icon tint and menu item titles. The menu
    /// bar shows only the feather (red while healthy, orange while capture is
    /// recovering or lost); the elapsed counter lives in the menu's state
    /// label. Call once a second while recording and on every status change.
    /// `signalWarning` is a secondary diagnostic (exact digital silence on a
    /// track that is still delivering callbacks) — its own line, never the
    /// same visual state as stopped callbacks.
    func update(_ display: Display, signalWarning: Bool = false) {
        switch display {
        case .idle:
            stateLabel.title = "idle"
            toggleItem.title = "Start recording"
            statusItem.button?.contentTintColor = nil
        case .recording(let elapsed):
            stateLabel.title = "● recording · \(elapsed)"
            toggleItem.title = "Stop recording"
            statusItem.button?.contentTintColor = .systemRed
        case .recovering(let track, let elapsed):
            stateLabel.title = "◐ recovering \(track) · \(elapsed)"
            toggleItem.title = "Stop recording"
            statusItem.button?.contentTintColor = .systemOrange
        case .degraded(let track, let elapsed):
            stateLabel.title = "⚠ \(track) capture lost · \(elapsed)"
            toggleItem.title = "Stop recording"
            statusItem.button?.contentTintColor = .systemOrange
        }
        let warn = signalWarning && display != .idle
        warningLabel.title = warn ? "△ system audio silent" : ""
        warningLabel.isHidden = !warn
    }

    /// Reflect SMAppService's view of the login item. Outside Parrot.app
    /// (`swift run`) the item is disabled — there is no bundle to register.
    func updateLaunchAtLogin(_ status: SMAppService.Status) {
        let bundled = AppBundle.isBundled
        launchAtLoginItem.isEnabled = bundled
        launchAtLoginItem.title = bundled ? "Launch at login" : "Launch at login (needs Parrot.app)"
        launchAtLoginItem.state = status == .enabled ? .on : .off
        let needsApproval = status == .requiresApproval
        approvalLabel.isHidden = !needsApproval
        openLoginItemsItem.isHidden = !needsApproval
    }

    /// Open the status-bar menu as if the feather had been clicked.
    func showMenu() {
        statusItem.button?.performClick(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        onMenuWillOpen?()
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    // Inlined Lucide feather SVG. Keeping it in source means the executable
    // has no separate resource bundle to install alongside it — true
    // single-binary.
    private static let featherSVG = """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
        viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
        stroke-linecap="round" stroke-linejoin="round">\
        <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
        <path d="M16 8 2 22"/>\
        <path d="M17.5 15H9"/>\
        </svg>
        """

    private static func featherImage() -> NSImage? {
        guard let data = featherSVG.data(using: .utf8),
            let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
    @objc private func launchAtLoginClicked() { onToggleLaunchAtLogin?() }
    @objc private func openLoginItemsClicked() { onOpenLoginItems?() }
}
