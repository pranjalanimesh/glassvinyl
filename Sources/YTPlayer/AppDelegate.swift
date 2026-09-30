import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = PlayerModel()
    private let log = ListenLog()
    private let analyzer = AudioAnalyzer()
    private var bridge: PlayerBridge!
    private var recommender: Recommender!
    private var library: LibraryStore!
    private var karaoke: KaraokeEngine!
    private var widget: NSPanel!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        bridge = PlayerBridge()
        bridge.onPoll = { [weak self] state, upNext in
            guard let self else { return }
            if self.model.state != state { self.model.state = state }
            if let upNext {
                if self.model.queue != upNext.queue { self.model.queue = upNext.queue }
                if self.model.autoplay != upNext.autoplay { self.model.autoplay = upNext.autoplay }
            }
            self.log.record(state)
        }
        bridge.onProblem = { [weak self] problem in
            if self?.model.problem != problem { self?.model.problem = problem }
        }

        recommender = Recommender(model: model, bridge: bridge, log: log)
        library = LibraryStore(bridge: bridge, directory: log.fileURL.deletingLastPathComponent())
        karaoke = KaraokeEngine(bridge: bridge, model: model)
        widget = makeWidget()
        statusItem = makeStatusItem()
        applySettings()
        widget.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.flush()
        analyzer.stop()
    }

    /// Applies the settings that live outside SwiftUI. Runs on every UserDefaults change.
    private func applySettings() {
        let defaults = UserDefaults.standard

        // Audio capture runs only while a visualizer is switched on.
        let style = defaults.string(forKey: SettingKey.visualizer).flatMap(VisualizerStyle.init(rawValue:)) ?? .bars
        style == .off ? analyzer.stop() : analyzer.start()

        bridge.applyEQSoon()

        let allSpaces = defaults.object(forKey: SettingKey.allSpaces) as? Bool ?? true
        let behavior: NSWindow.CollectionBehavior = allSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        if widget.collectionBehavior != behavior {
            widget.collectionBehavior = behavior
            // Re-show so the widget attaches to the current desktop when leaving "All desktops".
            if widget.isVisible {
                widget.orderOut(nil)
                widget.orderFrontRegardless()
            }
        }
    }

    // MARK: - Widget

    /// Translucent, borderless, always-on-top player card.
    private func makeWidget() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: PlayerLayout.compact.defaultWidth, height: 124),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .vibrantDark)

        let host = NSHostingView(rootView: PlayerView(
            model: model, bridge: bridge, recommender: recommender, library: library, analyzer: analyzer,
            openMusicWindow: { [weak self] in self?.bridge.showWindow() },
            openSettings: { [weak self] in self?.showSettings() },
            // Captures the panel directly: the first resize arrives before `widget` is assigned.
            resize: { [weak panel] size in
                guard let panel else { return }
                Self.resize(panel, to: size)
            },
            drawerWillAnimate: { [weak panel] duration in
                guard let panel else { return }
                Self.trackShadow(of: panel, for: duration)
            }
        ))
        // The window size is driven by resizeWidget, not by SwiftUI's layout.
        host.sizingOptions = []
        panel.contentView = host

        if !panel.setFrameUsingName("PlayerWidget"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - PlayerLayout.compact.defaultWidth - 20, y: screen.maxY - 124 - 20))
        }
        panel.setFrameAutosaveName("PlayerWidget")
        return panel
    }

    /// Sets the size in one step, keeping the top-left corner in place.
    private static func resize(_ panel: NSPanel, to size: CGSize) {
        var frame = panel.frame
        guard frame.size != size else { return }
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    /// The window shadow follows the drawn content, but only when recomputed. Recompute it
    /// every frame while the drawer animates.
    private static func trackShadow(of panel: NSPanel, for duration: TimeInterval) {
        let end = Date().addingTimeInterval(duration + 0.05)
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak panel] timer in
            MainActor.assumeIsolated {
                panel?.invalidateShadow()
                if panel == nil || Date() > end { timer.invalidate() }
            }
        }
    }

    // MARK: - Settings

    /// Opens Settings beside the widget, or closes it if it's already open.
    @objc private func showSettings() {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.close()
            return
        }
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(analyzer: analyzer, karaoke: karaoke, model: model))
            // The window follows each tab's height.
            controller.sizingOptions = .preferredContentSize
            let window = TopAnchoredWindow(contentViewController: controller)
            window.title = "YTPlayer Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // Floats like the widget, so the two stay side by side.
            window.level = .floating
            settingsWindow = window
        }
        guard let settingsWindow, let content = settingsWindow.contentViewController?.view else { return }
        // Size to the content now; a new window hasn't laid out yet, and placement needs its size.
        settingsWindow.setContentSize(content.fittingSize)
        placeBesideWidget(settingsWindow)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    /// Next to the widget, on whichever side has more room, top edges aligned.
    private func placeBesideWidget(_ window: NSWindow) {
        guard let screen = widget.screen?.visibleFrame else { return window.center() }
        let gap: CGFloat = 12
        let size = window.frame.size
        let roomLeft = widget.frame.minX - screen.minX
        let roomRight = screen.maxX - widget.frame.maxX
        var x = roomLeft >= roomRight ? widget.frame.minX - gap - size.width : widget.frame.maxX + gap
        x = min(max(x, screen.minX), screen.maxX - size.width)
        let y = max(min(widget.frame.maxY, screen.maxY) - size.height, screen.minY)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Menu bar

    @objc private func showMusicWindow() {
        bridge.showWindow()
    }

    @objc private func toggleWidget() {
        widget.isVisible ? widget.orderOut(nil) : widget.orderFrontRegardless()
    }

    @objc private func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([log.fileURL])
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "YT Player")

        let menu = NSMenu()
        menu.addItem(withTitle: "Show/Hide Player", action: #selector(toggleWidget), keyEquivalent: "")
        menu.addItem(withTitle: "Open YouTube Music", action: #selector(showMusicWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Reveal Listening Log", action: #selector(revealLog), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for menuItem in menu.items where menuItem.action != #selector(NSApplication.terminate(_:)) {
            menuItem.target = self
        }
        item.menu = menu
        return item
    }
}

/// Borderless panels can't take keyboard focus by default; the search field needs it.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Grows and shrinks from the bottom edge when its content changes size (Settings tabs),
/// instead of AppKit's default of keeping the bottom edge fixed.
private final class TopAnchoredWindow: NSWindow {
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if isVisible, frame.origin == self.frame.origin, frame.height != self.frame.height {
            frame.origin.y = self.frame.maxY - frame.height
        }
        super.setFrame(frame, display: flag)
    }
}
