import AppKit
import UniformTypeIdentifiers

final class EditorSurface: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        fill(bounds, color(0xECECEC))
        let pane = NSRect(x: 18, y: 38, width: bounds.width - 36, height: bounds.height - 96)
        fill(pane, color(0xE6E6E6)); stroke(pane, color(0xCCCCCC), radius: 2)
    }
}

final class EditorButton: NSButton {
    var selected = false { didSet { needsDisplay = true } }
    var aqua = false
    var segment = false
    private var pulse: Timer?
    private var actionBlock: () -> Void
    init(_ title: String, label: String, action: @escaping () -> Void) {
        actionBlock = action; super.init(frame: .zero); self.title = title
        setAccessibilityLabel(label); target = self; self.action = #selector(invoke)
        isBordered = false; setButtonType(.momentaryPushIn)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { actionBlock() }
    override var isFlipped: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); pulse?.invalidate(); pulse = nil
        if window != nil && aqua && !segment {
            pulse = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }; self.needsDisplay = true
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 2), radius: CGFloat = segment ? 3 : r.height / 2
        let blue = isEnabled && (selected || aqua)
        gradient(r, blue ? (isHighlighted ? 0x3783C4 : 0xA9D6FA) : 0xFFFFFF, blue ? 0x4BA5E4 : 0xD4D4D4, radius: radius)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).addClip()
        gradient(NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.48), blue ? 0xE4F5FF : 0xFFFFFF, blue ? 0x81B8EC : 0xECECEC)
        if blue && aqua && !segment && window?.isKeyWindow == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !isHighlighted {
            color(0xFFFFFF, 0.10 + 0.12 * (sin(ProcessInfo.processInfo.systemUptime * 3) + 1) / 2).setFill(); NSBezierPath(rect: r).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        stroke(r, color(blue ? 0x47759B : 0x888888), radius: radius)
        stroke(r.insetBy(dx: 1, dy: 1), color(0xFFFFFF, 0.65), radius: radius)
        centeredGlyphText(title, in: r, size: 12, ink: color(isEnabled ? 0x111111 : 0x999999))
    }
}

@MainActor final class MetadataEditor: NSWindowController, NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
    private let library: Library
    private let records: [Track]
    private let albumMode: Bool
    private let surface = EditorSurface(frame: NSRect(x: 0, y: 0, width: 680, height: 600))
    private let body = FlippedView()
    private var tabs: [EditorButton] = []
    private var fields: [MetadataField: NSTextField] = [:]
    private var checks: [MetadataField: NSButton] = [:]
    private var original: [MetadataField: String] = [:]
    private var mixed: Set<MetadataField> = []
    private var changed: Set<MetadataField> = []
    private var draft: [MetadataField: String] = [:]
    private var artwork: ArtworkEdit = .unchanged
    private var tab = 0
    private let cover = NSImageView()
    private var lyricsView: NSTextView?
    private var resetPlays = false
    private var artworkScale = 1.0
    private let errorLabel = NSTextField(labelWithString: "")
    var onClose: (() -> Void)?
    var onSaved: (() -> Void)?
    private var tabNames: [String] { albumMode ? ["Информация", "Сортировка", "Параметры", "Обложка"] : ["Информация", "Сортировка", "Параметры", "Текст", "Обложка", "Файл"] }

    private var artworkObserver: NSObjectProtocol?
    deinit { if let artworkObserver { NotificationCenter.default.removeObserver(artworkObserver) } }
    init(library: Library, records: [Track], albumMode: Bool) {
        self.library = library; self.records = records; self.albumMode = albumMode
        let panel = NSPanel(contentRect: surface.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.delegate = self
        panel.title = albumMode ? "Информация об альбоме" : records.count > 1 ? "Информация о композициях" : "Информация о композиции"
        panel.appearance = NSAppearance(named: .aqua); panel.isReleasedWhenClosed = false; panel.contentView = surface
        for key in MetadataField.allCases {
            let values = Set(records.map { $0.value(key) })
            if values.count == 1 { original[key] = values.first!; draft[key] = values.first! }
            else { mixed.insert(key); draft[key] = "" }
        }
        cover.image = records.first.map(Covers.image)
        artworkObserver = NotificationCenter.default.addObserver(forName: Covers.ready, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let first = self.records.first, note.object as? String == Covers.key(first), case .unchanged = self.artwork else { return }
                self.cover.image = Covers.cached(first); self.selectTab(self.tab)
            }
        }
        let width = min(115, 628 / CGFloat(tabNames.count)); let start = (680 - width * CGFloat(tabNames.count)) / 2
        body.frame = NSRect(x: 34, y: 64, width: 612, height: 460); surface.addSubview(body)
        for (i, title) in tabNames.enumerated() {
            let button = EditorButton(title, label: title) { [weak self] in self?.selectTab(i) }
            button.segment = true; button.frame = NSRect(x: start + CGFloat(i) * width, y: 26, width: width + 1, height: 26)
            surface.addSubview(button); tabs.append(button)
        }
        errorLabel.frame = NSRect(x: 24, y: 539, width: 410, height: 42); errorLabel.font = font(10); errorLabel.textColor = color(0xA02722); errorLabel.maximumNumberOfLines = 3; surface.addSubview(errorLabel)
        let cancel = EditorButton("Отмена", label: "Отмена") { [weak self] in self?.closeSheet() }
        cancel.frame = NSRect(x: 454, y: 560, width: 94, height: 26); cancel.keyEquivalent = "\u{1b}"; surface.addSubview(cancel)
        let save = EditorButton("ОК", label: "Сохранить изменения") { [weak self] in self?.commit() }
        save.aqua = true; save.frame = NSRect(x: 560, y: 560, width: 94, height: 26); save.keyEquivalent = "\r"; surface.addSubview(save)
        selectTab(0)
    }
    required init?(coder: NSCoder) { fatalError() }
    private func label(_ title: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat = 11, bold: Bool = false, ink: NSColor = color(0x333333), parent: NSView? = nil) {
        let label = NSTextField(labelWithString: title); label.font = font(size, bold: bold); label.textColor = ink
        label.lineBreakMode = .byTruncatingTail; label.frame = NSRect(x: x, y: y, width: width, height: 20); (parent ?? body).addSubview(label)
    }
    private func field(_ key: MetadataField, y: CGFloat, width: CGFloat = 440, x: CGFloat = 0) {
        label(key == .trackTotal || key == .discTotal ? "из" : key == .discNumber ? "Диск" : key == .bpm ? "Темп" : key.label, x: x, y: y, width: width, size: 11, bold: true, ink: color(0x222222))
        let input = NSTextField(frame: NSRect(x: x, y: y + 20, width: width, height: 24))
        input.cell = ClassicTextCell(textCell: ""); input.isEditable = true; input.isSelectable = true
        input.font = font(11); input.isBezeled = false; input.drawsBackground = false; input.usesSingleLineMode = true; input.backgroundColor = .white
        input.stringValue = draft[key] ?? ""; input.placeholderString = mixed.contains(key) && !changed.contains(key) ? "Разные" : ""
        input.identifier = NSUserInterfaceItemIdentifier(key.rawValue); input.delegate = self; input.setAccessibilityLabel(key.label)
        body.addSubview(input); fields[key] = input
    }
    private func checkbox(_ key: MetadataField, y: CGFloat) {
        let check = NSButton(checkboxWithTitle: key.label, target: self, action: #selector(checkChanged(_:)))
        check.frame = NSRect(x: 0, y: y, width: 600, height: 22); check.font = font(11)
        check.identifier = NSUserInterfaceItemIdentifier(key.rawValue); check.allowsMixedState = true
        check.state = mixed.contains(key) && !changed.contains(key) ? .mixed : draft[key] == "1" ? .on : .off
        body.addSubview(check); checks[key] = check
    }
    private func captureDraft() {
        for (key, input) in fields where changed.contains(key) { draft[key] = input.stringValue }
        if let lyricsView, changed.contains(.lyrics) { draft[.lyrics] = lyricsView.string }
    }
    private func selectTab(_ index: Int) {
        captureDraft(); tab = index; fields = [:]; checks = [:]; lyricsView = nil
        body.subviews.forEach { $0.removeFromSuperview() }
        for (i, button) in tabs.enumerated() { button.selected = i == tab; button.needsDisplay = true }
        switch tabNames[index] {
        case "Информация":
            var left: [MetadataField] = [.artist, .albumArtist, .album, .grouping, .composer]
            if !albumMode { left.insert(.title, at: 0) }
            for (i, key) in left.enumerated() { field(key, y: CGFloat(i) * 55, width: 452) }
            field(.year, y: 55, width: 136, x: 476)
            field(.discNumber, y: 165, width: 60, x: 476); field(.discTotal, y: 165, width: 60, x: 552)
            if !albumMode { field(.number, y: 110, width: 60, x: 476); field(.trackTotal, y: 110, width: 60, x: 552); field(.bpm, y: 220, width: 136, x: 476) }
            field(.comments, y: 330, width: 612)
            field(.genre, y: 394, width: 300)
            checkbox(.isCompilation, y: 418); checks[.isCompilation]?.frame = NSRect(x: 326, y: 415, width: 286, height: 24)
        case "Обложка":
            let well = NSBox(frame: NSRect(x: 16, y: 40, width: 580, height: 320)); well.boxType = .custom; well.fillColor = .white; well.borderColor = color(0xAAAAAA); well.borderWidth = 1; body.addSubview(well)
            let preview = NSImageView(frame: NSRect(x: 166, y: 50, width: 280, height: 300)); preview.image = cover.image; preview.imageScaling = .scaleProportionallyUpOrDown; body.addSubview(preview)
            func scaleArtwork(_ scale: Double) { let size = 300 * scale; preview.frame = NSRect(x: (612 - size) / 2, y: 50 + (300 - size) / 2, width: size, height: size) }
            scaleArtwork(artworkScale)
            let choose = EditorButton("Добавить…", label: "Выбрать обложку") { [weak self] in self?.chooseArtwork() }; choose.frame = NSRect(x: 16, y: 378, width: 100, height: 26); body.addSubview(choose)
            let remove = EditorButton("Удалить", label: "Удалить обложку") { [weak self] in self?.artwork = .remove; self?.cover.image = nil; self?.selectTab(self?.tab ?? 0) }; remove.frame = NSRect(x: 126, y: 378, width: 100, height: 26); body.addSubview(remove)
            let zoom = AquaSlider(frame: NSRect(x: 464, y: 378, width: 132, height: 24)); zoom.aquaThumb = true; zoom.value = (artworkScale - 0.35) / 0.65; zoom.setAccessibilityLabel("Размер обложки в редакторе")
            zoom.onChange = { [weak self] value in self?.artworkScale = 0.35 + value * 0.65; scaleArtwork(0.35 + value * 0.65) }; body.addSubview(zoom)
        case "Текст":
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 4, width: 612, height: 440)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
            let textView = NSTextView(frame: scroll.bounds); textView.isRichText = false; textView.font = font(12); textView.string = draft[.lyrics] ?? ""; textView.delegate = self
            textView.isVerticallyResizable = true; textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
            scroll.documentView = textView; body.addSubview(scroll); lyricsView = textView
        case "Параметры":
            label("Коррекция громкости", x: 24, y: 30, width: 180)
            let volume = AquaSlider(frame: NSRect(x: 210, y: 24, width: 340, height: 28)); volume.aquaThumb = true; volume.ticked = true; volume.value = ((Double(draft[.volumeAdjustment] ?? "0") ?? 0) + 100) / 200; volume.setAccessibilityLabel("Коррекция громкости")
            let amount = NSTextField(labelWithString: mixed.contains(.volumeAdjustment) && !changed.contains(.volumeAdjustment) ? "Разные" : "\(Int(volume.value * 200 - 100))%")
            amount.frame = NSRect(x: 340, y: 62, width: 80, height: 20); amount.alignment = .center; amount.font = font(11); body.addSubview(amount)
            volume.onChange = { [weak self] value in let percent = Int((value * 200 - 100).rounded()); self?.changed.insert(.volumeAdjustment); self?.draft[.volumeAdjustment] = String(percent); amount.stringValue = "\(percent)%" }; body.addSubview(volume)
            label("−100%", x: 210, y: 62, width: 70); label("+100%", x: 500, y: 62, width: 80)
            if !albumMode { field(.startTime, y: 126, width: 160, x: 180); field(.stopTime, y: 186, width: 160, x: 180) }
            checkbox(.skipShuffle, y: 272); checks[.skipShuffle]?.frame.origin.x = 180
            label("Воспроизведено: \(records.reduce(0) { $0 + $1.plays })", x: 180, y: 326, width: 230)
            let reset = EditorButton(resetPlays ? "Будет сброшено" : "Сбросить счётчик", label: "Сбросить счётчик воспроизведений") { [weak self] in self?.resetPlays = true; self?.selectTab(self?.tab ?? 0) }
            reset.frame = NSRect(x: 180, y: 358, width: 160, height: 26); body.addSubview(reset)
        case "Сортировка":
            let pairs: [(MetadataField, MetadataField)] = [(.title, .sortTitle), (.artist, .sortArtist), (.albumArtist, .sortAlbumArtist), (.album, .sortAlbum), (.composer, .sortComposer)]
            for (i, pair) in pairs.enumerated() {
                field(pair.0, y: CGFloat(i) * 66, width: 292)
                field(pair.1, y: CGFloat(i) * 66, width: 296, x: 316)
            }
        case "Файл":
            guard let track = records.first else { return }
            let summary = NSImageView(frame: NSRect(x: 8, y: 12, width: 114, height: 114)); summary.image = cover.image; summary.imageScaling = .scaleProportionallyUpOrDown; body.addSubview(summary)
            label(track.title, x: 140, y: 20, width: 460, size: 13, bold: true); label(track.artist, x: 140, y: 46, width: 460); label(track.album, x: 140, y: 70, width: 460)
            let path = NSTextField(wrappingLabelWithString: track.path ?? "Файл недоступен"); path.font = font(11); path.frame = NSRect(x: 18, y: 290, width: 576, height: 110); body.addSubview(path)
            label("Длительность: \(timeString(track.duration))", x: 18, y: 160, width: 580)
            label("Формат: \(URL(fileURLWithPath: track.path ?? "").pathExtension.uppercased())", x: 18, y: 190, width: 580)
            if let file = track.path {
                let reveal = EditorButton("Показать в Finder", label: "Показать аудиофайл в Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }; reveal.frame = NSRect(x: 18, y: 230, width: 160, height: 25); body.addSubview(reveal)
            }
        default: break
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let raw = field.identifier?.rawValue, let key = MetadataField(rawValue: raw) else { return }
        changed.insert(key); draft[key] = field.stringValue
    }
    func textDidChange(_ notification: Notification) { changed.insert(.lyrics); draft[.lyrics] = lyricsView?.string ?? "" }
    @objc private func checkChanged(_ sender: NSButton) {
        guard let key = MetadataField(rawValue: sender.identifier?.rawValue ?? "") else { return }
        if sender.state == .mixed { changed.remove(key) } else { changed.insert(key); draft[key] = sender.state == .on ? "1" : "0" }
    }
    private func chooseArtwork() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url, let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return }
            let scale = min(1, 1024 / max(image.size.width, image.size.height)); let size = NSSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            image.draw(in: NSRect(origin: .zero, size: size)); NSGraphicsContext.restoreGraphicsState()
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
            self.artwork = .replace(data); self.cover.image = NSImage(data: data); self.selectTab(self.tab)
        }
    }
    func present(for parent: NSWindow) { guard let window else { return }; parent.beginSheet(window) }
    private func commit() {
        window?.makeFirstResponder(nil); captureDraft()
        var patch = MetadataPatch(); patch.artwork = artwork; patch.resetPlays = resetPlays
        for key in changed {
            let value = draft[key] ?? ""
            if mixed.contains(key) || value != original[key] { patch.fields[key] = value }
        }
        do { try library.apply(patch, to: Set(records.map(\.id))); onSaved?(); closeSheet() }
        catch { errorLabel.stringValue = error.localizedDescription }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeSheet(); return false }
    private func closeSheet() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window); parent.makeKeyAndOrderFront(nil) }
        window.orderOut(nil); onClose?()
    }
}

@MainActor final class PlaybackPreferencesSurface: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        fill(bounds, color(0xF2F2F2)); gradient(NSRect(x: 0, y: 0, width: bounds.width, height: 44), 0xF2F2F2, 0xD6D6D6)
        fill(NSRect(x: 0, y: 43, width: bounds.width, height: 1), color(0xA6A6A6))
        engravedText("Воспроизведение", NSRect(x: 20, y: 13, width: bounds.width - 40, height: 20), size: 13, ink: color(0x333333), bold: true)
    }
}

@MainActor final class PlaybackPreferences: NSWindowController, NSWindowDelegate {
    let library: Library
    let enabled = NSButton(checkboxWithTitle: "Плавный переход между песнями", target: nil, action: nil)
    let seconds = AquaSlider()
    let value = NSTextField(labelWithString: "")
    let alwaysOnTop = NSButton(checkboxWithTitle: "Мини-плеер поверх всех окон", target: nil, action: nil)
    var onMiniLevelChange: (() -> Void)?
    var onClose: (() -> Void)?
    init(library: Library) {
        self.library = library
        let surface = PlaybackPreferencesSurface(frame: NSRect(x: 0, y: 0, width: 480, height: 266))
        let panel = NSPanel(contentRect: surface.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = "Настройки iTunes"; panel.contentView = surface; panel.appearance = NSAppearance(named: .aqua); panel.isReleasedWhenClosed = false; panel.delegate = self
        enabled.frame = NSRect(x: 24, y: 67, width: 420, height: 22); enabled.font = font(12); enabled.target = self; enabled.action = #selector(toggle)
        surface.addSubview(enabled)
        let description = NSTextField(wrappingLabelWithString: "Конец текущей песни плавно смешивается с началом следующей.")
        description.frame = NSRect(x: 43, y: 100, width: 398, height: 35); description.font = font(11); description.textColor = color(0x606060); surface.addSubview(description)
        seconds.ticked = true; seconds.frame = NSRect(x: 43, y: 148, width: 282, height: 28); seconds.setAccessibilityLabel("Длительность плавного перехода")
        seconds.onChange = { [weak self] value in guard let self else { return }; self.library.crossfadeSeconds = (1 + value * 11).rounded(); self.reload() }
        surface.addSubview(seconds)
        value.frame = NSRect(x: 345, y: 150, width: 110, height: 20); value.font = font(11); surface.addSubview(value)
        let range = NSTextField(labelWithString: "1 секунда                                      12 секунд")
        range.frame = NSRect(x: 43, y: 176, width: 290, height: 17); range.font = font(10); range.textColor = color(0x6A6A6A); surface.addSubview(range)
        alwaysOnTop.frame = NSRect(x: 24, y: 224, width: 420, height: 22); alwaysOnTop.font = font(12); alwaysOnTop.target = self; alwaysOnTop.action = #selector(toggleMiniLevel); surface.addSubview(alwaysOnTop)
        ClassicWindowChrome.install(on: panel, body: surface, title: "Настройки iTunes")
        reload(); panel.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func toggleMiniLevel() { UserDefaults.standard.set(alwaysOnTop.state == .on, forKey: "MiniPlayerAlwaysOnTop"); onMiniLevelChange?() }
    @objc private func toggle() { library.crossfadeEnabled = enabled.state == .on; reload() }
    func reload() {
        alwaysOnTop.state = UserDefaults.standard.bool(forKey: "MiniPlayerAlwaysOnTop") ? .on : .off
        enabled.state = library.crossfadeEnabled ? .on : .off
        seconds.value = (library.crossfadeSeconds - 1) / 11; seconds.isEnabled = library.crossfadeEnabled; seconds.alphaValue = library.crossfadeEnabled ? 1 : 0.45
        value.stringValue = AlbumSummary.inflect(Int(library.crossfadeSeconds.rounded()), "секунда", "секунды", "секунд")
        value.textColor = library.crossfadeEnabled ? color(0x333333) : color(0x888888)
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

@MainActor extension MetadataEditor {
    static func testAquaEditor(track: Track, storage: URL) {
        let library = Library(storage: storage); library.tracks = [track]
        let editor = MetadataEditor(library: library, records: [track], albumMode: false)
        precondition(!editor.tabNames.contains("Видео"))
        let title = editor.fields[.title]!
        title.stringValue = "Edited locally"; editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: title))
        editor.selectTab(editor.tabNames.firstIndex(of: "Параметры")!)
        let slider = editor.body.subviews.compactMap { $0 as? AquaSlider }.first!
        slider.value = 0.65; slider.onChange?(slider.value)
        editor.selectTab(editor.tabNames.firstIndex(of: "Обложка")!)
        let zoom = editor.body.subviews.compactMap { $0 as? AquaSlider }.first!
        zoom.value = 0.4; zoom.onChange?(zoom.value)
        editor.selectTab(0)
        precondition(editor.fields[.title]?.stringValue == "Edited locally" && editor.draft[.volumeAdjustment] == "30")
        precondition(library.tracks[0].title == track.title)
        editor.commit(); precondition(library.tracks[0].title == "Edited locally" && library.tracks[0].volumeAdjustment == 30)
        var other = track; other.id = "other"; other.title = "Keep individual title"; other.artist = "Different artist"
        library.tracks = [track, other]
        let group = MetadataEditor(library: library, records: [track, other], albumMode: true)
        for i in group.tabNames.indices { group.selectTab(i) }
        group.commit(); precondition(library.tracks.map(\.title) == [track.title,other.title])
        print("PASS: Aqua metadata tabs, drafts across tabs, volume/artwork sliders, explicit-only group edits and commit")
    }
}

/// Shared opaque Snow Leopard titlebar for secondary windows.
@MainActor final class ClassicWindowChrome: NSView {
    let caption: String
    private var lights: [RetroButton] = []
    private var clock: Timer?
    override var isFlipped: Bool { true }
    init(body: NSView, title: String) {
        caption = title; super.init(frame: NSRect(x: 0, y: 0, width: body.frame.width, height: body.frame.height + 28))
        body.frame.origin = NSPoint(x: 0, y: 28); addSubview(body)
        for (i, kind) in [RetroButton.TrafficSymbol.close, .minimize, .zoom].enumerated() {
            let b = RetroButton("", label: i == 0 ? "Закрыть окно" : i == 1 ? "Свернуть окно недоступно" : "Масштаб недоступен") { [weak self] in self?.window?.performClose(nil) }
            b.trafficSymbol = kind; b.traffic = [0xE66B60,0xE8C44B,0x78B56A][i]; b.trafficMonochrome = i != 0; b.isEnabled = i == 0
            b.frame = NSRect(x: 7 + CGFloat(i) * 21, y: 4, width: 20, height: 20); addSubview(b); lights.append(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    static func install(on panel: NSPanel, body: NSView, title: String) {
        panel.styleMask.insert(.fullSizeContentView); panel.titlebarAppearsTransparent = true; panel.titleVisibility = .hidden; panel.titlebarSeparatorStyle = .none
        let chrome = ClassicWindowChrome(body: body, title: title); panel.setContentSize(chrome.frame.size); panel.contentView = chrome
        for type: NSWindow.ButtonType in [.closeButton,.miniaturizeButton,.zoomButton] { panel.standardWindowButton(type)?.isHidden = true }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); clock?.invalidate(); clock = nil
        if window != nil { clock = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
            guard let self, let window = self.window else { timer.invalidate(); return }
            let point = self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            let hover = NSApp.isActive && window.isKeyWindow && NSRect(x: 7,y: 4,width: 62,height: 20).contains(point)
            self.lights.forEach { $0.showTrafficGlyphs = hover && $0.isEnabled; $0.needsDisplay = true }; self.needsDisplay = true
            }
        } }
    }
    override func mouseDown(with event: NSEvent) { if convert(event.locationInWindow, from: nil).y < 28 { window?.performDrag(with: event) } else { super.mouseDown(with: event) } }
    override func draw(_ dirtyRect: NSRect) {
        let active = NSApp.isActive && window?.isKeyWindow == true
        gradient(NSRect(x: 0,y: 0,width: bounds.width,height: 28), active ? 0xF1F1F1 : 0xF6F6F6, active ? 0xC8C8C8 : 0xE2E2E2)
        fill(NSRect(x: 0,y: 27,width: bounds.width,height: 1), color(0x999999))
        engravedText(caption, NSRect(x: 78,y: 7,width: bounds.width - 156,height: 18), size: 12, ink: color(0x333333), alignment: .center)
    }
}

@MainActor final class ClassicAboutWindow: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    init() {
        let body = FlippedView(frame: NSRect(x: 0,y: 0,width: 440,height: 280)); body.wantsLayer = true; body.layer?.backgroundColor = color(0xECECEC).cgColor
        let panel = NSPanel(contentRect: body.bounds, styleMask: [.titled,.closable], backing: .buffered, defer: false)
        super.init(window: panel); panel.title = "Об iTunes"; panel.delegate = self; panel.isReleasedWhenClosed = false; panel.appearance = NSAppearance(named: .aqua)
        let icon = NSImageView(frame: NSRect(x: 28,y: 28,width: 96,height: 96)); icon.imageScaling = .scaleProportionallyUpOrDown
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") { icon.image = NSImage(contentsOf: url) }; body.addSubview(icon)
        func label(_ text: String, _ rect: NSRect, size: CGFloat, bold: Bool = false) { let field = NSTextField(wrappingLabelWithString: text); field.font = font(size,bold:bold); field.textColor = color(0x333333); field.frame = rect; body.addSubview(field) }
        let info = Bundle.main.infoDictionary ?? [:], version = info["CFBundleShortVersionString"] as? String ?? "—", build = info["CFBundleVersion"] as? String ?? "—"
        label("iTunes", NSRect(x: 145,y: 37,width: 264,height: 30), size: 22,bold:true)
        label("Версия \(version) · сборка \(build)", NSRect(x: 145,y: 77,width: 270,height: 25), size: 12)
        label("Локальная медиатека в стиле iTunes 9 на Mac OS X Snow Leopard.", NSRect(x: 28,y: 146,width: 384,height: 42), size: 12)
        label("Музыка · видеоклипы · Cover Flow · плейлисты\nВаша музыка хранится на вашем Mac.", NSRect(x: 28,y: 197,width: 384,height: 38), size: 11)
        let done = EditorButton("Готово", label:"Закрыть сведения о приложении") { [weak self] in self?.window?.performClose(nil) }; done.aqua = true; done.keyEquivalent = "\r"; done.frame = NSRect(x: 316,y: 246,width: 96,height: 26); body.addSubview(done)
        ClassicWindowChrome.install(on: panel, body: body, title: "Об iTunes"); panel.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
