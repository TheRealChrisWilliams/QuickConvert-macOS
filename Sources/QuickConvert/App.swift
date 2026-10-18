import AppKit
import SwiftUI
import ConvertCore

@main
enum QuickConvertMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") { exit(SelfTest.run()) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class TrayPanel: NSPanel {
    var onEscape: () -> Void = {}

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: TrayView.width, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    required init?(coder: NSCoder) { fatalError("TrayPanel is created in code") }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape() }
}

// Receives drags for the whole tray; SwiftUI reports tile frames for hit testing.
final class DropHostView: NSView {
    weak var controller: AppDelegate?
    override var isFlipped: Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragEntered(sender, at: point(sender)) ?? []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragUpdated(at: point(sender)) ?? []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.dragExited() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.model.canDrop ?? false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.performDrop(sender, at: point(sender)) ?? false
    }

    private func point(_ sender: NSDraggingInfo) -> CGPoint { convert(sender.draggingLocation, from: nil) }
}

// NSWindow forwards dragging-destination messages to its delegate; used for the status item's window.
final class StatusDropReceiver: NSObject, NSWindowDelegate, NSDraggingDestination {
    weak var controller: AppDelegate?

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated { controller?.dragEntered(sender, at: nil) ?? [] }
    }
    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated { controller?.dragUpdated(at: nil) ?? [] }
    }
    func draggingExited(_ sender: NSDraggingInfo?) { MainActor.assumeIsolated { controller?.dragExited() } }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated { controller?.performDrop(sender, at: nil) ?? false }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = TrayModel()
    private var statusItem: NSStatusItem!
    private let statusReceiver = StatusDropReceiver()
    private let panel = TrayPanel()
    private var dragSequence: Int?
    private var openedByDrag = false
    private var pendingLeave: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = StatusIcon.image
            button.setAccessibilityLabel("QuickConvert")
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusReceiver.controller = self
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = statusReceiver
        }

        let host = DropHostView()
        host.controller = self
        host.registerForDraggedTypes([.fileURL])
        let actions = TrayActions(chooseFiles: { [weak self] in self?.chooseFiles() },
                                  chooseFolder: { [weak self] retry in self?.chooseFolder(thenRetry: retry) },
                                  dismiss: { [weak self] in self?.hidePanel() },
                                  resized: { [weak self] height in self?.resize(height) })
        let hosting = NSHostingView(rootView: TrayView(model: model, actions: actions))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        host.addSubview(hosting)
        panel.contentView = host
        hosting.frame = host.bounds
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.hidePanel() }

        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        showPanel(activate: true)
    }

    // Files opened at launch arrive before didFinishLaunching, which shows the tray.
    func application(_ application: NSApplication, open urls: [URL]) {
        receive(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel(activate: true)
        return false
    }

    // Finder Services entry, declared as NSMessage "convertFiles" in Info.plist.
    @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        receive(Self.fileURLs(pasteboard))
    }

    private func receive(_ urls: [URL]) {
        let files = urls.filter { !(Self.isDirectory($0)) }
        if model.isBusy {
            model.notice = "Finish or cancel the current conversion first."
        } else if !files.isEmpty {
            model.stage(files)
        }
        if statusItem != nil { showPanel(activate: true) }
    }

    // MARK: Status item

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Choose Files…", action: #selector(chooseFilesFromMenu), keyEquivalent: "o").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "About QuickConvert", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Quit QuickConvert", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if panel.isVisible {
            hidePanel()
        } else {
            showPanel(activate: true)
        }
    }

    @objc private func chooseFilesFromMenu() { chooseFiles() }

    // MARK: Drag session

    func dragEntered(_ info: NSDraggingInfo, at point: CGPoint?) -> NSDragOperation {
        pendingLeave?.cancel()
        if dragSequence != info.draggingSequenceNumber {
            dragSequence = info.draggingSequenceNumber
            if !model.isBusy { model.beginHover(Self.fileURLs(info.draggingPasteboard)) }
        }
        if !panel.isVisible {
            openedByDrag = true
            showPanel(activate: false)
        }
        return dragUpdated(at: point)
    }

    func dragUpdated(at point: CGPoint?) -> NSDragOperation {
        guard model.canDrop, model.hovering != nil else { return [] }
        let target = point.flatMap(model.target(at:))
        if model.hoverTarget != target { model.hoverTarget = target }
        return .copy
    }

    func dragExited() {
        model.hoverTarget = nil
        pendingLeave?.cancel()
        // Grace period for crossing the gap between the status icon and the tray.
        let leave = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dragSequence = nil
            self.model.endHover()
            if self.openedByDrag, self.model.staged.isEmpty, !self.model.isBusy { self.hidePanel() }
            self.openedByDrag = false
        }
        pendingLeave = leave
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: leave)
    }

    func performDrop(_ info: NSDraggingInfo, at point: CGPoint?) -> Bool {
        pendingLeave?.cancel()
        dragSequence = nil
        openedByDrag = false
        let urls = Self.fileURLs(info.draggingPasteboard)
        guard model.canDrop, model.hovering == urls, !urls.isEmpty else {
            model.endHover()
            return false
        }
        model.commitDrop(urls, target: point.flatMap(model.target(at:)))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        return true
    }

    // MARK: Panel

    private func showPanel(activate: Bool) {
        position(height: panel.frame.height)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        if model.phase == .ready || model.phase == .idle { model.endHover() }
    }

    private func resize(_ height: CGFloat) {
        guard height > 0, abs(height - panel.frame.height) > 0.5 else { return }
        position(height: height)
    }

    // Anchors the tray's top edge under the status item, or centers it when the item is hidden.
    private func position(height: CGFloat) {
        let size = NSSize(width: TrayView.width, height: height)
        var origin: NSPoint
        if let anchor = statusItem?.button?.window?.frame, let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) {
            let visible = screen.visibleFrame
            origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - 6 - size.height)
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        } else {
            let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking elsewhere dismisses the tray; a running job keeps going.
        if model.hovering == nil, !NSApp.windows.contains(where: { $0 is NSOpenPanel && $0.isVisible }) { hidePanel() }
    }

    // MARK: Pickers

    private func chooseFiles() {
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.message = "Choose images, PDFs, audio or video to convert."
        NSApp.activate(ignoringOtherApps: true)
        if picker.runModal() == .OK { receive(picker.urls) } else { showPanel(activate: true) }
    }

    private func chooseFolder(thenRetry: Bool) {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.prompt = "Save Here"
        NSApp.activate(ignoringOtherApps: true)
        if picker.runModal() == .OK, let folder = picker.url {
            model.options.destination = folder
            if thenRetry { model.retry() }
        }
        showPanel(activate: true)
    }

    // MARK: Helpers

    nonisolated static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { !isDirectory($0) }
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

enum StatusIcon {
    // Monochrome template version of the two opposing arrows.
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            arrow(y: 4.5, pointingRight: true).fill()
            arrow(y: 13.5, pointingRight: false).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "QuickConvert"
        return image
    }()

    private static func arrow(y: CGFloat, pointingRight: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        let points: [NSPoint] = [
            NSPoint(x: 1.5, y: y - 1.1), NSPoint(x: 11, y: y - 1.1), NSPoint(x: 11, y: y - 4),
            NSPoint(x: 16.5, y: y), NSPoint(x: 11, y: y + 4), NSPoint(x: 11, y: y + 1.1), NSPoint(x: 1.5, y: y + 1.1)
        ].map { pointingRight ? $0 : NSPoint(x: 18 - $0.x, y: $0.y) }
        path.move(to: points[0])
        points.dropFirst().forEach(path.line(to:))
        path.close()
        return path
    }
}
