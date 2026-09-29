import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = PlayerModel()
    private let log = ListenLog()
    private let analyzer = AudioAnalyzer()
    private var bridge: PlayerBridge!
    private var widget: NSPanel!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        bridge = PlayerBridge()
        bridge.onPoll = { [weak self] state, queue in
            guard let self else { return }
            if self.model.state != state { self.model.state = state }
            if let queue, self.model.queue != queue { self.model.queue = queue }
            self.log.record(state)
        }
        bridge.onProblem = { [weak self] problem in
            if self?.model.problem != problem { self?.model.problem = problem }
        }

        widget = makeWidget()
        statusItem = makeStatusItem()
        widget.orderFrontRegardless()

        updateAnalyzer()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAnalyzer() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.flush()
        analyzer.stop()
    }

    /// Audio capture runs only while a visualizer is switched on.
    private func updateAnalyzer() {
        let style = UserDefaults.standard.string(forKey: SettingKey.visualizer)
            .flatMap(VisualizerStyle.init(rawValue:)) ?? .bars
        style == .off ? analyzer.stop() : analyzer.start()
    }

    // MARK: - Widget

    /// Translucent, borderless, always-on-top player card.
    private func makeWidget() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: PlayerView.width(for: .compact), height: 124),
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .vibrantDark)

        let host = NSHostingView(rootView: PlayerView(
            model: model, bridge: bridge, analyzer: analyzer,
            openMusicWindow: { [weak self] in self?.bridge.showWindow() },
            openSettings: { [weak self] in self?.showSettings() },
            // Captures the panel directly: the first resize arrives before `widget` is assigned.
            resize: { [weak panel] size, completion in
                guard let panel else { return }
                Self.resize(panel, to: size, completion: completion)
            }
        ))
        // The window size is driven by resizeWidget, not by SwiftUI's layout.
        host.sizingOptions = []
        panel.contentView = host

        if !panel.setFrameUsingName("PlayerWidget"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - PlayerView.width(for: .compact) - 20, y: screen.maxY - 124 - 20))
        }
        panel.setFrameAutosaveName("PlayerWidget")
        return panel
    }

    /// Animates to `size` while keeping the top-left corner in place, so the drawer
    /// slides open downward. Jumps straight there while the panel is still hidden.
    private static func resize(_ panel: NSPanel, to size: CGSize, completion: (() -> Void)?) {
        var frame = panel.frame
        guard frame.size != size else { completion?(); return }
        frame.origin.y += frame.height - size.height
        frame.size = size
        guard panel.isVisible else {
            panel.setFrame(frame, display: false)
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.invalidateShadow()
                completion?()
            }
        })
    }

    // MARK: - Settings

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "YTPlayer Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
