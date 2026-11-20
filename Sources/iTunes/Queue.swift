import AppKit

/// Each occurrence has its own identity: adding the same song twice is intentional.
struct QueueEntry: Equatable {
    let id: String
    let trackID: String
    init(_ trackID: String) { self.id = UUID().uuidString; self.trackID = trackID }
}

enum QueueSection: CaseIterable { case manual, context, later }

/// Reusable Finder-style selection. IDs may be track IDs or queue occurrence IDs.
struct ItemSelection {
    private(set) var ids: Set<String> = []
    private(set) var anchor: String?
    private(set) var focus: String?
    mutating func select(_ id: String, ordered: [String], modifiers: NSEvent.ModifierFlags = [], context: Bool = false) {
        guard let index = ordered.firstIndex(of: id) else { return }
        if context && ids.contains(id) { focus = id; return }
        if modifiers.contains(.shift), let anchor, let start = ordered.firstIndex(of: anchor) {
            let range = Set(ordered[min(start, index)...max(start, index)])
            ids = modifiers.contains(.command) ? ids.union(range) : range
        } else if modifiers.contains(.command) {
            if !ids.insert(id).inserted { ids.remove(id) }; anchor = id
        } else { ids = [id]; anchor = id }
        focus = id
    }
    mutating func set(_ values: Set<String>, ordered: [String]) { ids = values.intersection(ordered); anchor = ordered.first { ids.contains($0) }; focus = anchor }
    mutating func retain(_ ordered: [String]) { ids.formIntersection(ordered); if anchor.map({ !ordered.contains($0) }) == true { anchor = nil }; if focus.map({ !ordered.contains($0) }) == true { focus = nil } }
    mutating func clear() { ids = []; anchor = nil; focus = nil }
}

struct PlaybackPlan {
    struct Played { let entry: QueueEntry; let section: QueueSection }
    private(set) var manual: [QueueEntry] = []
    private(set) var continuation: [QueueEntry] = []
    private(set) var later: [QueueEntry] = []
    private(set) var cycle: [String] = []
    private(set) var current: Played?
    private(set) var history: [Played] = []
    var contextTitle = "Из медиатеки"
    var hasExplicit: Bool { !manual.isEmpty || !later.isEmpty }
    var hasUpcoming: Bool { hasExplicit || !continuation.isEmpty }
    func entries(_ section: QueueSection) -> [QueueEntry] { switch section { case .manual: return manual; case .context: return continuation; case .later: return later } }
    private mutating func setEntries(_ entries: [QueueEntry], _ section: QueueSection) { switch section { case .manual: manual = entries; case .context: continuation = entries; case .later: later = entries } }
    mutating func start(_ ids: [String], at trackID: String, title: String, shuffled: Bool) {
        cycle = ids; contextTitle = title
        let index = ids.firstIndex(of: trackID) ?? 0
        history = ids.prefix(index).map { Played(entry: QueueEntry($0), section: .context) }
        continuation = (shuffled ? ids.filter { $0 != trackID }.shuffled() : Array(ids.dropFirst(index + 1))).map(QueueEntry.init)
        current = Played(entry: QueueEntry(trackID), section: .context)
    }
    mutating func add(_ ids: [String], next: Bool) {
        let entries = ids.map(QueueEntry.init)
        if next { manual.insert(contentsOf: entries, at: 0) } else { later += entries }
    }
    mutating func clearManual() { manual.removeAll(); later.removeAll() }
    mutating func remove(_ id: String) { remove(Set([id])) }
    mutating func remove(_ ids: Set<String>) { for section in QueueSection.allCases { setEntries(entries(section).filter { !ids.contains($0.id) }, section) } }
    @discardableResult mutating func move(_ id: String, to section: QueueSection, at boundary: Int) -> Bool { move([id], to: section, at: boundary) }
    @discardableResult mutating func move(_ ids: [String], to section: QueueSection, at boundary: Int) -> Bool {
        let selected = Set(ids), all = manual + continuation + later
        let moving = ids.compactMap { id in all.first { $0.id == id } }
        guard !moving.isEmpty, moving.count == selected.count else { return false }
        let destination = entries(section)
        let before = destination.prefix(max(0, boundary)).filter { selected.contains($0.id) }.count
        remove(selected)
        var updated = entries(section)
        updated.insert(contentsOf: moving, at: min(updated.count, max(0, boundary - before)))
        setEntries(updated, section); return true
    }
    mutating func next(repeatAll: Bool = false, shuffled: Bool = false) -> String? {
        if !hasUpcoming && repeatAll { continuation = (shuffled ? cycle.shuffled() : cycle).map(QueueEntry.init) }
        guard let section = QueueSection.allCases.first(where: { !entries($0).isEmpty }), let entry = entries(section).first else { return nil }
        if let current { history.append(current) }
        var list = entries(section); list.removeFirst(); setEntries(list, section)
        current = Played(entry: entry, section: section); return entry.trackID
    }
    mutating func previous() -> String? {
        guard let previous = history.popLast() else { return current?.entry.trackID }
        if let current { var list = entries(current.section); list.insert(current.entry, at: 0); setEntries(list, current.section) }
        current = previous; return previous.entry.trackID
    }
    mutating func jump(_ id: String) -> String? {
        for section in QueueSection.allCases {
            if let index = entries(section).firstIndex(where: { $0.id == id }) {
                for before in QueueSection.allCases.prefix(while: { $0 != section }) { setEntries([], before) }
                setEntries(Array(entries(section).dropFirst(index)), section); return next()
            }
        }
        return nil
    }
    mutating func shuffleRemaining() { continuation.shuffle() }
}

@MainActor final class QueueLCDButton: NSButton {
    var opened = false { didSet { needsDisplay = true; setAccessibilityValue(opened ? "Открыта" : "Закрыта") } }
    var onPress: (() -> Void)?
    init() {
        super.init(frame: .zero); title = "Далее"; isBordered = false; target = self; action = #selector(press)
        toolTip = "Показать очередь «Далее»"; setAccessibilityLabel("Очередь Далее")
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func press() { onPress?() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if opened || isHighlighted { color(0, 0.12).setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 3, yRadius: 3).fill() }
        let x = bounds.midX - 7, y = bounds.midY - 5
        for offset: CGFloat in [1, 0] {
            let ink = offset == 1 ? color(0xFFFFFF, 0.5) : color(opened ? 0x1E2216 : 0x3E4430)
            for i in 0..<3 { fill(NSRect(x: x, y: y + CGFloat(i) * 4 + offset, width: 2, height: 2), ink); fill(NSRect(x: x + 4, y: y + CGFloat(i) * 4 + offset, width: 10, height: 2), ink) }
        }
    }
}

@MainActor final class ClassicPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class ClassicPopup: NSObject {
    static var active: ClassicPopup?
    let panel: NSPanel
    weak var anchor: NSView?
    var onClose: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var closing = false
    init(body: NSView, anchor: NSView, caret: Bool = false, at point: NSPoint? = nil) {
        self.anchor = anchor
        panel = ClassicPopupPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        panel.title = caret ? "Далее" : "Действия"; panel.setAccessibilityLabel(panel.title)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .aqua); panel.level = .floating; panel.hidesOnDeactivate = true
        let shell = ClassicPopupShell(body: body, caret: caret)
        panel.contentView = shell
        let local = point ?? NSPoint(x: anchor.bounds.midX, y: anchor.isFlipped ? anchor.bounds.maxY : anchor.bounds.minY)
        let screen = anchor.window?.convertPoint(toScreen: anchor.convert(local, to: nil)) ?? .zero
        let visible = anchor.window?.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let width = body.frame.width + 2, height = body.frame.height + 2 + (caret ? 8 : 0)
        let x = min(visible.maxX - width - 8, max(visible.minX + 8, screen.x - (caret ? width / 2 : 8)))
        shell.caretX = min(width - 16, max(16, screen.x - x))
        panel.setFrame(NSRect(x: x, y: max(visible.minY + 8, screen.y - height - 2), width: width, height: height), display: false)
    }
    func show() {
        Self.active?.close(animated: false); Self.active = self
        if let parent = anchor?.window { parent.addChildWindow(panel, ordered: .above) }
        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 0; panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close(); return nil }
                if self.onKey?(event) == true { return nil }
                return event
            }
            if event.window !== self.panel {
                if let anchor = self.anchor, event.window === anchor.window, anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return event }
                self.close()
            }
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.close() }) { monitors.append(monitor) }
        for name in [NSWindow.didResizeNotification, NSWindow.willMoveNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: anchor?.window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.close(animated: false) } })
        }
    }
    func close(animated: Bool = true) {
        guard !closing else { return }; closing = true
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        if Self.active === self { Self.active = nil }
        onClose?()
        if animated {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 }, completionHandler: { [self] in
                Task { @MainActor in self.finishClose() }
            })
        } else { finishClose() }
    }
    private func finishClose() {
        let parent = panel.parent
        if panel.isKeyWindow && NSApp.isActive { parent?.makeKey() }
        parent?.removeChildWindow(panel); panel.orderOut(nil)
    }
}

@MainActor final class ClassicPopupShell: NSView {
    let body: NSView; let caret: Bool
    var caretX: CGFloat = 20
    override var isFlipped: Bool { true }
    init(body: NSView, caret: Bool) {
        self.body = body; self.caret = caret; super.init(frame: .zero)
        body.wantsLayer = true; body.layer?.cornerRadius = 5; body.layer?.masksToBounds = true; addSubview(body)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); body.frame.origin = NSPoint(x: 1, y: caret ? 9 : 1) }
    override func draw(_ dirtyRect: NSRect) {
        let top: CGFloat = caret ? 8 : 0
        let r = NSRect(x: 0.5, y: top + 0.5, width: bounds.width - 1, height: bounds.height - top - 1)
        NSColor.white.setFill(); NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill(); stroke(r, color(0x888888), radius: 6)
        if caret {
            let p = NSBezierPath(); p.move(to: NSPoint(x: caretX - 7, y: 9)); p.line(to: NSPoint(x: caretX, y: 1)); p.line(to: NSPoint(x: caretX + 7, y: 9)); color(0xEFEFEF).setFill(); p.fill(); color(0x888888).setStroke(); p.stroke()
            fill(NSRect(x: caretX - 6, y: 8, width: 12, height: 2), color(0xEFEFEF))
        }
    }
}

@MainActor final class ClassicMenuRow: NSButton {
    var hovered = false
    var invoke: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        invoke = action; super.init(frame: .zero); self.title = title; isBordered = false; target = self; self.action = #selector(activate)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func activate() { ClassicPopup.active?.close(animated: false); invoke() }
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted { gradient(bounds, 0x6799DC, 0x2863B6) }
        text(title, bounds.insetBy(dx: 12, dy: 5), size: 11, ink: hovered || isHighlighted ? .white : color(0x222222))
    }
}

@MainActor enum ClassicActionMenu {
    static func show(_ actions: [(String, () -> Void)], from anchor: NSView, at point: NSPoint? = nil) {
        let width = max(224, min(330, actions.map { ($0.0 as NSString).size(withAttributes: [.font: font(11)]).width + 28 }.max() ?? 224))
        let body = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: actions.reduce(CGFloat(8)) { $0 + ($1.0.isEmpty ? 9 : 26) }))
        body.wantsLayer = true; body.layer?.backgroundColor = NSColor.white.cgColor
        var rows: [ClassicMenuRow] = []
        var y: CGFloat = 4
        for action in actions {
            if action.0.isEmpty {
                let divider = NSView(frame: NSRect(x: 10, y: y + 4, width: width - 20, height: 1)); divider.wantsLayer = true; divider.layer?.backgroundColor = color(0xD4D4D4).cgColor; body.addSubview(divider); y += 9
            } else {
                let row = ClassicMenuRow(action.0, action: action.1); row.frame = NSRect(x: 0, y: y, width: width, height: 26); body.addSubview(row); rows.append(row); y += 26
            }
        }
        let popup = ClassicPopup(body: body, anchor: anchor, at: point)
        var index = -1
        popup.onKey = { event in
            if event.keyCode == 125 || event.keyCode == 126 {
                index = min(rows.count - 1, max(0, index + (event.keyCode == 125 ? 1 : -1)))
                for (i, row) in rows.enumerated() { row.hovered = i == index; row.needsDisplay = true }; return true
            }
            if event.keyCode == 36, rows.indices.contains(index) { rows[index].performClick(nil); return true }
            return false
        }
        popup.show()
    }
}

@MainActor final class QueueTrackCell: NSView {
    let track: Track
    let alternate: Bool
    let remove: DrawerIconButton
    var dragging = false { didSet { alphaValue = dragging ? 0.6 : 1 } }
    private var hovered = false
    private var downPoint = NSPoint.zero
    var onSelect: ((NSEvent) -> Void)?
    var onPlay: (() -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var onDrop: ((NSEvent) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downPoint = event.locationInWindow; dragging = false; onSelect?(event) }
    override func mouseDragged(with event: NSEvent) {
        let p = event.locationInWindow
        if dragging || hypot(p.x - downPoint.x, p.y - downPoint.y) >= 4 { dragging = true; onDrag?(event) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragging { dragging = false; onDrop?(event) } else if event.clickCount >= 2 { onPlay?() }
    }
    override var isFlipped: Bool { true }
    init(track: Track, alternate: Bool, onRemove: @escaping () -> Void) {
        self.track = track; self.alternate = alternate; remove = DrawerIconButton(.close, label: "Убрать «\(track.title)» из очереди", action: onRemove)
        super.init(frame: NSRect(x: 0, y: 0, width: 330, height: 44)); addSubview(remove); remove.isHidden = true
        setAccessibilityElement(true); setAccessibilityRole(.cell); setAccessibilityLabel(track.title + ", " + track.artist)
        toolTip = track.title + " — " + track.artist + " — " + track.album
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); remove.frame = NSRect(x: bounds.width - 23, y: 15, width: 14, height: 14) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; remove.isHidden = false; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; remove.isHidden = true; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        fill(bounds, alternate ? color(0xF3F6FA) : .white)
        let selected = (superview as? NSTableRowView)?.isSelected == true
        if selected { gradient(bounds, 0x77A8E2, 0x3272C5) }
        else if hovered { fill(bounds, color(0xE4EDFA)) }
        fill(NSRect(x: 0, y: 43, width: bounds.width, height: 1), color(0xE6E6E6))
        if hovered { for y: CGFloat in [18, 21, 24] { fill(NSRect(x: 5, y: y, width: 8, height: 1), color(0x999999)) } }
        let art = NSRect(x: 19, y: 6, width: 32, height: 32)
        Covers.draw(track, in: art); stroke(art, color(0, 0.2))
        text(track.title, NSRect(x: 59, y: 6, width: max(1, bounds.width - 88), height: 17), size: 12, ink: selected ? .white : color(0x111111), bold: true)
        text(track.artist + " — " + track.album, NSRect(x: 59, y: 24, width: max(1, bounds.width - 88), height: 15), size: 11, ink: selected ? color(0xFFFFFF, 0.9) : color(0x6E6E6E))
    }
}

@MainActor final class QueueInsertionMarker: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        fill(NSRect(x: 8, y: 2, width: bounds.width - 10, height: 2), color(0x2668C5))
        color(0x2668C5).setFill(); NSBezierPath(ovalIn: NSRect(x: 4, y: 0, width: 6, height: 6)).fill()
    }
}

@MainActor final class QueueTable: NSTableView {
    private let marker = QueueInsertionMarker()
    var insertionRow: Int? {
        didSet {
            guard let row = insertionRow else { marker.removeFromSuperview(); return }
            let y = row < numberOfRows ? rect(ofRow: max(0, row)).minY : (numberOfRows > 0 ? rect(ofRow: numberOfRows - 1).maxY : 1)
            marker.frame = NSRect(x: 0, y: max(0, y - 3), width: bounds.width, height: 6)
            marker.wantsLayer = true; marker.layer?.zPosition = 1000
            addSubview(marker, positioned: .above, relativeTo: nil); marker.needsDisplay = true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if numberOfRows == 0 { text("Очередь пуста", NSRect(x: 15, y: 22, width: bounds.width - 30, height: 22), size: 12, ink: color(0x777777), alignment: .center) }
    }
}

@MainActor final class QueueClearButton: NSButton {
    var onPress: (() -> Void)?
    init() { super.init(frame: .zero); title = "Очистить"; isBordered = false; target = self; action = #selector(press); setAccessibilityLabel("Очистить добавленные вручную треки") }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func press() { onPress?() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        gradient(r, isHighlighted ? 0xACACAC : 0xFAFAFA, isHighlighted ? 0xD0D0D0 : 0xC8C8C8, radius: 9)
        stroke(r, color(0x8E8E8E), radius: 9)
        centeredGlyphText(title, in: r.offsetBy(dx: 0, dy: 0.5), size: 10, ink: color(0xFFFFFF, 0.85))
        centeredGlyphText(title, in: r, size: 10, ink: color(0x333333))
    }
}

@MainActor final class QueueSectionHeader: NSView {
    let title: String
    override var isFlipped: Bool { true }
    init(_ title: String) { self.title = title; super.init(frame: NSRect(x: 0, y: 0, width: 330, height: 20)); setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(title) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        fill(bounds, color(0xE6E9EF)); engravedText(title, NSRect(x: 6, y: 4, width: bounds.width - 12, height: 14), size: 10, ink: color(0x586375), bold: true)
    }
}

@MainActor final class QueueClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return constrained }
        constrained.origin.x = documentView.bounds.minX
        constrained.origin.y = min(max(documentView.bounds.minY, proposedBounds.minY), max(documentView.bounds.minY, documentView.bounds.maxY - proposedBounds.height))
        return constrained
    }
}

@MainActor final class QueueBody: NSView {
    weak var owner: QueuePopover?
    let scroll = NSScrollView()
    let clear = QueueClearButton()
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 330, height: 200))
        scroll.contentView = QueueClipView()
        scroll.verticalScrollElasticity = .none; scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.borderType = .noBorder; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.backgroundColor = .white
        addSubview(scroll); addSubview(clear)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); scroll.frame = NSRect(x: 0, y: 32, width: bounds.width, height: max(1, bounds.height - 32)); clear.frame = NSRect(x: bounds.width - 66, y: 7, width: 58, height: 18) }
    override func draw(_ dirtyRect: NSRect) {
        fill(bounds, .white); gradient(NSRect(x: 0, y: 0, width: bounds.width, height: 32), 0xEFEFEF, 0xDCDCDC)
        fill(NSRect(x: 0, y: 31, width: bounds.width, height: 1), color(0xBDBDBD))
        let title = owner?.library.playbackPlan.hasExplicit == true ? "Далее" : "Далее: " + (owner?.library.playbackPlan.contextTitle ?? "Из медиатеки")
        engravedText(title, NSRect(x: 10, y: 9, width: bounds.width - (clear.isHidden ? 20 : 84), height: 16), size: 11, ink: color(0x333333), bold: true)
    }
}

@MainActor final class QueuePopover: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Item { let entry: QueueEntry?; let section: QueueSection; let heading: String? }
    let library: Library
    let body = QueueBody()
    let table = QueueTable()
    private(set) var items: [Item] = []
    private var records: [String: Track] = [:]
    private var selection = ItemSelection()
    private var restoringSelection = false
    private var popup: ClassicPopup!
    var onClose: (() -> Void)?
    var isOpen: Bool { ClassicPopup.active === popup }
    init(library: Library, anchor: NSView) {
        self.library = library; super.init(); body.owner = self
        table.style = .plain; table.headerView = nil; table.rowHeight = 44; table.usesAutomaticRowHeights = false; table.intercellSpacing = .zero
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("queue")); column.width = 330; table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self; table.selectionHighlightStyle = .none; table.allowsEmptySelection = true
        table.allowsMultipleSelection = true; table.target = self; table.doubleAction = #selector(playClicked)
        body.scroll.documentView = table
        body.clear.onPress = { [weak self] in self?.library.clearUpNext() }
        reload()
        popup = ClassicPopup(body: body, anchor: anchor, caret: true)
        popup.onClose = { [weak self] in self?.onClose?() }
        popup.onKey = { [weak self] event in
            guard let self else { return false }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a" {
                self.selection.set(Set(self.items.compactMap { $0.entry?.id }), ordered: self.items.compactMap { $0.entry?.id }); self.applySelection(); return true
            }
            if event.keyCode == 125 || event.keyCode == 126 {
                let direction = event.keyCode == 125 ? 1 : -1
                var i = self.table.selectedRow < 0 ? (direction > 0 ? -1 : self.items.count) : self.table.selectedRow
                repeat { i += direction } while self.items.indices.contains(i) && self.items[i].entry == nil
                if self.items.indices.contains(i) { if let id = self.items[i].entry?.id { self.selection.select(id, ordered: self.items.compactMap { $0.entry?.id }, modifiers: event.modifierFlags); self.applySelection() }; self.table.scrollRowToVisible(i) }; return true
            }
            if event.keyCode == 36 { self.playRow(self.table.selectedRow); return true }
            if event.keyCode == 51 { let ids = Set(self.table.selectedRowIndexes.compactMap { self.items[$0].entry?.id }); self.library.removeUpNext(ids); return true }
            return false
        }
    }
    func show() { popup.show() }
    func close() { popup.close() }
    func reload() {
        let oldOrigin = body.scroll.contentView.bounds.origin
        records = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let manual = library.playbackPlan.manual.filter { records[$0.trackID] != nil }
        let context = library.playbackPlan.continuation.filter { records[$0.trackID] != nil }
        let later = library.playbackPlan.later.filter { records[$0.trackID] != nil }
        let groups: [(QueueSection, String, [QueueEntry])] = [(.manual, "Далее", manual), (.context, library.playbackPlan.contextTitle, context), (.later, "Добавлено позже", later)]
        let showHeaders = groups.filter { !$0.2.isEmpty }.count > 1
        items = []
        for (section, title, entries) in groups where !entries.isEmpty {
            if showHeaders { items.append(Item(entry: nil, section: section, heading: title)) }
            items += entries.map { Item(entry: $0, section: section, heading: nil) }
        }
        body.clear.isHidden = !library.playbackPlan.hasExplicit
        selection.retain(items.compactMap { $0.entry?.id })
        restoringSelection = true
        table.reloadData(); applySelection(); table.insertionRow = nil
        restoringSelection = false
        let contentHeight = items.reduce(CGFloat(0)) { $0 + ($1.entry == nil ? 20 : 44) }
        let height: CGFloat = items.isEmpty ? 96 : min(410, contentHeight + 32)
        body.frame.size.height = height; body.needsLayout = true; body.needsDisplay = true
        if let popup {
            let old = popup.panel.frame
            popup.panel.setFrame(NSRect(x: old.minX, y: old.maxY - height - 10, width: old.width, height: height + 10), display: true)
        }
        body.layoutSubtreeIfNeeded()
        body.scroll.hasVerticalScroller = contentHeight > body.scroll.contentSize.height + 0.5
        table.frame.size = NSSize(width: body.scroll.contentSize.width, height: max(contentHeight, body.scroll.contentSize.height))
        body.scroll.contentView.scroll(to: NSPoint(x: 0, y: min(oldOrigin.y, max(0, contentHeight - body.scroll.contentSize.height))))
        body.scroll.reflectScrolledClipView(body.scroll.contentView)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { items[row].entry == nil ? 20 : 44 }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let ids = Set(table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].entry?.id : nil })
        if !restoringSelection && selection.ids != ids { selection.set(ids, ordered: items.compactMap { $0.entry?.id }) }
        table.enumerateAvailableRowViews { row, _ in row.subviews.forEach { $0.needsDisplay = true } }
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { items[row].entry != nil }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        guard let entry = item.entry, let track = records[entry.trackID] else {
            return QueueSectionHeader(item.heading ?? "")
        }
        let cell = QueueTrackCell(track: track, alternate: row % 2 == 1) { [weak self] in self?.library.removeUpNext(entry.id) }
        cell.onSelect = { [weak self] event in
            guard let self, self.items.contains(where: { $0.entry?.id == entry.id }) else { return }
            self.table.window?.makeFirstResponder(self.table)
            let keepGroup = self.selection.ids.count > 1 && self.selection.ids.contains(entry.id) && event.modifierFlags.intersection([.command, .shift]).isEmpty
            self.selection.select(entry.id, ordered: self.items.compactMap { $0.entry?.id }, modifiers: event.modifierFlags, context: keepGroup); self.applySelection()
        }
        cell.onPlay = { [weak self] in self?.library.playUpNext(entry.id) }
        cell.onDrag = { [weak self] event in self?.updateDrag(event) }
        cell.onDrop = { [weak self] event in
            guard let self else { return }
            self.updateDrag(event)
            if let boundary = self.table.insertionRow { let ids = self.selection.ids.contains(entry.id) ? self.items.compactMap { $0.entry }.filter { self.selection.ids.contains($0.id) }.map(\.id) : [entry.id]; _ = self.drop(ids, at: boundary) }
            self.table.insertionRow = nil
            self.table.enumerateAvailableRowViews { row, _ in row.subviews.compactMap { $0 as? QueueTrackCell }.forEach { $0.dragging = false } }
        }
        return cell
    }
    private func applySelection() {
        table.selectRowIndexes(IndexSet(items.indices.filter { items[$0].entry.map { selection.ids.contains($0.id) } ?? false }), byExtendingSelection: false)
    }
    @objc private func playClicked() { playRow(table.clickedRow) }
    private func playRow(_ row: Int) { if items.indices.contains(row), let entry = items[row].entry { library.playUpNext(entry.id) } }
    private func updateDrag(_ event: NSEvent) {
        let point = table.convert(event.locationInWindow, from: nil)
        let visible = table.visibleRect
        guard point.x >= 0, point.x <= table.bounds.width, point.y >= visible.minY - 20, point.y <= visible.maxY + 20 else { table.insertionRow = nil; return }
        _ = table.autoscroll(with: event)
        table.insertionRow = insertionBoundary(at: point)
        table.enumerateAvailableRowViews { row, index in
            guard self.items.indices.contains(index), let id = self.items[index].entry?.id, self.selection.ids.contains(id) else { return }
            row.subviews.compactMap { $0 as? QueueTrackCell }.forEach { $0.dragging = true }
        }
        table.displayIfNeeded()
    }
    func insertionBoundary(at point: NSPoint) -> Int {
        let row = table.row(at: point)
        if row < 0 { return point.y < 0 ? 0 : items.count }
        return point.y < table.rect(ofRow: row).midY ? row : row + 1
    }
    @discardableResult func drop(_ id: String, at boundary: Int) -> Bool { drop([id], at: boundary) }
    @discardableResult func drop(_ ids: [String], at boundary: Int) -> Bool {
        let row = min(items.count, max(0, boundary))
        let section: QueueSection
        if row == 0 { section = .manual }
        else if row < items.count, items[row].heading != nil { section = items[row - 1].section }
        else { section = row < items.count ? items[row].section : items.last?.section ?? .manual }
        let index = items.prefix(row).filter { $0.section == section && $0.entry != nil }.count
        return library.moveUpNext(ids, to: section, at: index)
    }
}

@MainActor extension Library {
    func beginPlaybackContext(_ records: [Track], at track: Track, title requestedTitle: String? = nil) {
        queue = records.map(\.id)
        let title: String
        if let requestedTitle { title = requestedTitle }
        else if Set(records.map(\.albumKey)).count == 1 { title = "Из альбома «" + track.album + "»" }
        else if let playlist = playlists.keys.sorted().first(where: { playlists[$0] == queue }) { title = "Из плейлиста «" + playlist + "»" }
        else { title = "Из медиатеки" }
        let ids = records.filter { !shuffle || $0.skipShuffle != true || $0.id == track.id }.map(\.id)
        playbackPlan.start(ids, at: track.id, title: title, shuffled: shuffle)
    }
    func enqueue(_ records: [Track], next: Bool) {
        let valid = Set(tracks.map(\.id))
        playbackPlan.add(records.map(\.id).filter { valid.contains($0) }, next: next)
        onQueueChange?()
    }
    func clearUpNext() { playbackPlan.clearManual(); onQueueChange?() }
    func removeUpNext(_ id: String) { removeUpNext(Set([id])) }
    func removeUpNext(_ ids: Set<String>) { playbackPlan.remove(ids); onQueueChange?() }
    @discardableResult func moveUpNext(_ id: String, to section: QueueSection, at index: Int) -> Bool {
        let moved = playbackPlan.move(id, to: section, at: index)
        if moved { onQueueChange?() }; return moved
    }
    @discardableResult func moveUpNext(_ ids: [String], to section: QueueSection, at index: Int) -> Bool {
        let moved = playbackPlan.move(ids, to: section, at: index); if moved { onQueueChange?() }; return moved
    }
    func playUpNext(_ id: String) {
        let before = playbackPlan
        guard let trackID = playbackPlan.jump(id), let track = tracks.first(where: { $0.id == trackID }) else { return }
        if !play(track) { playbackPlan = before; onQueueChange?() }
    }
}

@MainActor func testPlaybackQueue(track fixture: Track, storage: URL) {
    var plan = PlaybackPlan()
    plan.start(["a","b","c"], at: "a", title: "Album", shuffled: false)
    plan.add(["x","x"], next: false); plan.add(["y","z"], next: true)
    precondition(plan.manual.map(\.trackID) == ["y","z"] && plan.later.map(\.trackID) == ["x","x"])
    precondition(Set(plan.later.map(\.id)).count == 2)
    precondition([plan.next(),plan.next(),plan.next(),plan.next(),plan.next(),plan.next()].compactMap { $0 } == ["y","z","b","c","x","x"])
    precondition(plan.next() == nil && plan.next(repeatAll: true) == "a")
    plan.start(["a","b","c","d"], at: "a", title: "Album", shuffled: false)
    let c = plan.continuation[1], d = plan.continuation[2]
    precondition(plan.move([c.id,d.id], to: .manual, at: 0))
    precondition(plan.manual.map(\.trackID) == ["c","d"] && plan.continuation.map(\.trackID) == ["b"])
    precondition(plan.move([c.id,d.id], to: .later, at: 0) && plan.later.map(\.trackID) == ["c","d"])
    plan.add(["x","y"], next: true)
    precondition(plan.jump(plan.later[1].id) == "d" && !plan.hasUpcoming)
    precondition(plan.previous() == "a" && plan.next() == "d")
    plan.start(["a","b","c"], at: "a", title: "Album", shuffled: false)
    plan.add(["x","y"], next: true); plan.add(["z"], next: false)
    plan.clearManual(); precondition(!plan.hasExplicit && plan.continuation.map(\.trackID) == ["b","c"])
    plan.add(Array(repeating: "x", count: 8), next: false)
    let all = Set((plan.manual + plan.continuation + plan.later).map(\.id)), currentID = plan.current?.entry.id
    for i in 0..<100 {
        let entries = plan.manual + plan.continuation + plan.later; let entry = entries[i % entries.count]
        let section = QueueSection.allCases[i % 3]
        precondition(plan.move(entry.id, to: section, at: i % (plan.entries(section).count + 1)))
        precondition(Set((plan.manual + plan.continuation + plan.later).map(\.id)) == all && plan.current?.entry.id == currentID)
    }
    let library = Library(storage: storage)
    library.tracks = ["a", "b", "c", "x", "y"].map { id in var t = fixture; t.id = id; t.title = id; return t }
    let tracks = library.tracks
    library.play(tracks[0], within: Array(tracks.prefix(3)))
    let player = library.player; library.enqueue([tracks[3],tracks[4]], next: false)
    precondition(library.player === player && library.currentID == "a")
    library.step(1); precondition(library.currentID == "b", "Add Later must wait until the album has finished")
    library.enqueue([tracks[3]], next: true); library.step(1); precondition(library.currentID == "x")
    library.advanceAfterFinish(); precondition(library.currentID == "c")
    library.advanceAfterFinish(); precondition(library.currentID == "x")
    library.advanceAfterFinish(); precondition(library.currentID == "y")
    library.step(-1); precondition(library.currentID == "x")
    library.step(1); precondition(library.currentID == "y")
    library.repeatMode = 2; library.advanceAfterFinish(); precondition(library.currentID == "y")
    library.enqueue([tracks[1]], next: true); library.advanceAfterFinish(); precondition(library.currentID == "b")
    library.repeatMode = 1; library.step(1); precondition(library.currentID == "a")
    library.enqueue([tracks[3],tracks[4]], next: false)
    library.playUpNext(library.playbackPlan.later[1].id); precondition(library.currentID == "y" && !library.playbackPlan.hasUpcoming)
    library.repeatMode = 0; library.play(tracks[0], within: Array(tracks.prefix(3)))
    library.enqueue([tracks[3]], next: false); library.clearUpNext(); precondition(library.playbackPlan.continuation.count == 2)
    // Drive the same pointer callbacks used by the queue UI, without displaying a window.
    library.play(tracks[0], within: Array(tracks.prefix(3)))
    let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
    let anchor = NSView(frame: NSRect(x: 10, y: 350, width: 24, height: 24)); host.contentView?.addSubview(anchor)
    let queueUI = QueuePopover(library: library, anchor: anchor)
    library.onQueueChange = { [weak queueUI] in queueUI?.reload() }
    queueUI.body.layoutSubtreeIfNeeded(); queueUI.table.layoutSubtreeIfNeeded()
    let cell = queueUI.tableView(queueUI.table, viewFor: queueUI.table.tableColumns[0], row: 1) as! QueueTrackCell
    let unchangedPlayer = library.player; let unchangedPlays = library.tracks.map(\.plays)
    func mouse(_ type: NSEvent.EventType, y: CGFloat) -> NSEvent {
        let point = queueUI.table.convert(NSPoint(x: 8, y: y), to: nil)
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: queueUI.table.window?.windowNumber ?? 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    let start = queueUI.table.rect(ofRow: 1).midY
    cell.mouseDown(with: mouse(.leftMouseDown, y: start))
    cell.mouseDragged(with: mouse(.leftMouseDragged, y: 1))
    precondition(cell.dragging && queueUI.table.insertionRow == 0)
    cell.mouseUp(with: mouse(.leftMouseUp, y: 1))
    precondition(!cell.dragging && queueUI.table.insertionRow == nil)
    precondition(library.playbackPlan.manual.map(\.trackID) == ["c"] && library.playbackPlan.continuation.map(\.trackID) == ["b"])
    precondition(library.currentID == "a" && library.player === unchangedPlayer && library.tracks.map(\.plays) == unchangedPlays)
    precondition(queueUI.items.count == 4 && queueUI.items[0].heading == "Далее" && queueUI.items[2].heading != nil)
    queueUI.body.layoutSubtreeIfNeeded()
    let boundary = queueUI.table.rect(ofRow: 3)
    precondition(queueUI.insertionBoundary(at: NSPoint(x: 10, y: boundary.minY + 1)) == 3)
    precondition(queueUI.insertionBoundary(at: NSPoint(x: 10, y: boundary.maxY - 1)) == 4)
    library.clearUpNext(); precondition(queueUI.body.clear.isHidden && queueUI.items.count == 1)
    library.play(tracks[0], within: tracks, contextTitle: "Из плейлиста «Тест»")
    precondition(library.playbackPlan.contextTitle == "Из плейлиста «Тест»")
    library.onQueueChange = nil
    print("PASS: queue pointer drag threshold, Aqua boundary placement, promotion into empty manual section, no click/play after drop, section headers, clear button and playlist context")
    library.stopPlayback(); library.flushPendingSave()
    print("PASS: Up Next duplicate identities, insertion order, context promotion/demotion, 100 reorders without changing playback, removal/clear, skip/jump/history, album continuation, repeat modes and real audio transitions")
}
