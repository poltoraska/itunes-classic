import AppKit

/// Small, immutable palette computed alongside the background thumbnail decode.
struct AlbumPalette {
    var red: Double; var green: Double; var blue: Double
    var lightText: Bool
    static let fallback = AlbumPalette(red: 0.27, green: 0.30, blue: 0.35, lightText: true)
    var background: NSColor { NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1) }
    var primary: NSColor { lightText ? .white : color(0x111111) }
    var secondary: NSColor { primary.withAlphaComponent(0.72) }
    static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
    var textContrast: Double {
        let bg = Self.luminance(red, green, blue), fg = lightText ? 1 : Self.luminance(17 / 255, 17 / 255, 17 / 255)
        return (max(bg, fg) + 0.05) / (min(bg, fg) + 0.05)
    }
    static func extract(_ image: CGImage) -> AlbumPalette {
        let side = 48; var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let cg = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            cg.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side)); return true
        }
        guard rendered else { return .fallback }
        struct Bin { var count = 0; var r = 0.0; var g = 0.0; var b = 0.0 }
        var bins: [Int: Bin] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 192 {
            let key = Int(pixels[i] / 32) << 6 | Int(pixels[i + 1] / 32) << 3 | Int(pixels[i + 2] / 32)
            var bin = bins[key] ?? Bin(); bin.count += 1
            let alpha = Double(pixels[i + 3])
            bin.r += Double(pixels[i]) / alpha; bin.g += Double(pixels[i + 1]) / alpha; bin.b += Double(pixels[i + 2]) / alpha; bins[key] = bin
        }
        guard let dominant = bins.sorted(by: { $0.key < $1.key }).max(by: { $0.value.count < $1.value.count })?.value else { return .fallback }
        let n = Double(dominant.count); var rgb = [dominant.r / n, dominant.g / n, dominant.b / n]
        let gray = rgb.reduce(0, +) / 3
        rgb = rgb.map { $0 * 0.76 + gray * 0.24 }
        let lightness = (rgb.max()! + rgb.min()!) / 2
        let shift = min(0.84, max(0.20, lightness)) - lightness
        rgb = rgb.map { min(1, max(0, $0 + shift)) }
        let l = luminance(rgb[0], rgb[1], rgb[2]); let black = luminance(17 / 255, 17 / 255, 17 / 255)
        var result = AlbumPalette(red: rgb[0], green: rgb[1], blue: rgb[2], lightText: 1.05 / (l + 0.05) >= (l + 0.05) / (black + 0.05))
        // White and #111 have a narrow gap where neither reaches 4.5:1.
        // Nudge only those middle tones down rather than returning a low-contrast pair.
        while result.textContrast < 4.5 { result.lightText = true; result.red *= 0.96; result.green *= 0.96; result.blue *= 0.96 }
        return result
    }
}
final class AlbumPaletteBox: NSObject { let value: AlbumPalette; init(_ value: AlbumPalette) { self.value = value } }

@MainActor final class DrawerIconButton: NSButton {
    enum Kind { case close, play, shuffle, more }
    let kind: Kind
    var onPress: (() -> Void)?
    init(_ kind: Kind, label: String, action: @escaping () -> Void) {
        self.kind = kind; onPress = action; super.init(frame: .zero)
        isBordered = false; title = label; toolTip = label; setAccessibilityLabel(label); target = self; self.action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func pressed() { onPress?() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 4, bounds.height > 4 else { return }
        let r = bounds.insetBy(dx: 1, dy: 1)
        if kind == .close {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = color(0x000000, 0.35); shadow.shadowOffset = NSSize(width: 0, height: -1); shadow.shadowBlurRadius = 2; shadow.set()
            color(0x000000, isHighlighted ? 0.7 : 0.45).setFill(); NSBezierPath(ovalIn: r).fill(); NSGraphicsContext.restoreGraphicsState()
            let rim = NSBezierPath(); rim.move(to: NSPoint(x: r.minX + 4, y: r.minY + 3)); rim.curve(to: NSPoint(x: r.maxX - 4, y: r.minY + 3), controlPoint1: NSPoint(x: r.midX - 2, y: r.minY), controlPoint2: NSPoint(x: r.midX + 2, y: r.minY)); color(0xFFFFFF, 0.4).setStroke(); rim.stroke()
            let cross = NSBezierPath(); cross.lineWidth = 1.7; cross.lineCapStyle = .round
            for d: CGFloat in [-1, 1] { cross.move(to: NSPoint(x: r.midX - 3, y: r.midY - 3 * d)); cross.line(to: NSPoint(x: r.midX + 3, y: r.midY + 3 * d)) }; NSColor.white.setStroke(); cross.stroke()
        } else {
            gradient(r, isHighlighted ? 0x999999 : 0xF8F8F8, isHighlighted ? 0xC5C5C5 : 0xBDBDBD, radius: 4)
            stroke(r, color(0x000000, 0.4), radius: 4)
            let glyph: MetalGlyph = kind == .shuffle ? .shuffle : kind == .play ? .play : .more
            glyph.draw(in: r, pressed: isHighlighted)
        }
    }
}

@MainActor final class AlbumDrawerRow: NSButton {
    let track: Track
    let position: Int
    var spacious = false
    var palette = AlbumPalette.fallback
    var current = false; var playing = false
    var onPlay: (() -> Void)?
    var aquaSelected = false
    var onSelect: ((NSEvent.ModifierFlags, Bool) -> Void)?
    var contextActions: (() -> [(String, () -> Void)])?
    var onQueue: (([Track], Bool) -> Void)?
    var onEdit: ((Track) -> Void)?
    private var hovering = false
    private var tracking: NSTrackingArea?
    init(track: Track, position: Int, onPlay: @escaping () -> Void) {
        self.track = track; self.position = position; self.onPlay = onPlay; super.init(frame: .zero)
        isBordered = false; title = track.title; target = self; action = #selector(play)
        setAccessibilityLabel("\(track.title), \(track.artist), \(timeString(track.duration))")
        toolTip = track.title + " — " + track.artist
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func play() { onSelect?([], false) }
    override func mouseDown(with event: NSEvent) { onSelect?(event.modifierFlags, false); if event.clickCount >= 2 { onPlay?() } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) {
        onSelect?(event.modifierFlags, true)
        ClassicActionMenu.show(contextActions?() ?? [], from: self, at: convert(event.locationInWindow, from: nil))
    }
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow], owner: self); addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width >= 80, bounds.height >= 20 else { return }
        if aquaSelected { gradient(bounds.insetBy(dx: 0, dy: 0.5), 0x6F9FD9, 0x316CB8, radius: 2) }
        let primary = aquaSelected ? NSColor.white : palette.primary
        let secondary = aquaSelected ? color(0xE8F0FE) : palette.secondary
        if !aquaSelected && (hovering || isHighlighted || current) { palette.primary.withAlphaComponent(isHighlighted ? 0.20 : 0.10).setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 4, yRadius: 4).fill() }
        fill(NSRect(x: 4, y: bounds.maxY - 0.5, width: bounds.width - 8, height: 0.5), palette.primary.withAlphaComponent(palette.lightText ? 0.1 : 0.08))
        text(current ? (playing ? "▶" : "Ⅱ") : String(track.number > 0 ? track.number : position + 1), NSRect(x: 2, y: spacious ? 7 : 5, width: 18, height: 17), size: spacious ? 11 : 10, ink: secondary, alignment: .right)
        let badgeWidth: CGFloat = track.isExplicit == true ? 64 : 0
        text(track.title, NSRect(x: 28, y: spacious ? 6 : 4, width: max(1, bounds.width - 72 - badgeWidth), height: 19), size: spacious ? 13 : 11, ink: primary)
        if badgeWidth > 0 {
            let badge = NSRect(x: bounds.width - 102, y: 5, width: 56, height: 14)
            stroke(badge, secondary, radius: 1); centeredGlyphText("EXPLICIT", in: badge, size: 9, ink: secondary)
        }
        let p = NSMutableParagraphStyle(); p.alignment = .right
        (timeString(track.duration) as NSString).draw(in: NSRect(x: bounds.width - 38, y: spacious ? 7 : 5, width: 36, height: 17), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: spacious ? 11 : 10, weight: .regular), .foregroundColor: secondary, .paragraphStyle: p])
    }
}

@MainActor final class AlbumDrawer: NSView {
    override var isFlipped: Bool { true }
    private(set) var group: LibraryGroup?
    private(set) var orderedTracks: [Track] = []
    private(set) var rows: [AlbumDrawerRow] = []
    private(set) var selection = ItemSelection()
    var selectedTracks: [Track] { orderedTracks.filter { selection.ids.contains($0.id) } }
    var onEditTracks: (([Track]) -> Void)?
    var onAddToPlaylist: (([Track], String) -> Void)?
    var onRevealAlbum: (([Track]) -> Void)?
    var onRemove: (([Track], Bool) -> Void)?
    var playlistNames: (() -> [String])?
    override var acceptsFirstResponder: Bool { true }
    func select(_ id: String, modifiers: NSEvent.ModifierFlags = [], context: Bool = false) {
        window?.makeFirstResponder(self)
        selection.select(id, ordered: orderedTracks.map(\.id), modifiers: modifiers, context: context); updateSelection()
    }
    func selectAllTracks() { selection.set(Set(orderedTracks.map(\.id)), ordered: orderedTracks.map(\.id)); updateSelection() }
    private func updateSelection() { rows.forEach { $0.aquaSelected = selection.ids.contains($0.track.id); $0.setAccessibilitySelected($0.aquaSelected); $0.needsDisplay = true } }
    func playSelectedTracks() { if let first = selectedTracks.first { onPlayTracks?(first, selectedTracks) } }
    func actionsForSelection() -> [(String, () -> Void)] {
        let tracks = selectedTracks
        guard !tracks.isEmpty else { return [] }
        var actions: [(String, () -> Void)] = [
            ("Воспроизвести", { [weak self] in self?.onPlayTracks?(tracks[0], tracks) }),
            ("Воспроизвести следующим", { [weak self] in self?.onQueue?(tracks, true) }),
            ("Добавить в очередь позже", { [weak self] in self?.onQueue?(tracks, false) }),
            (tracks.count == 1 ? "Информация о композиции…" : "Информация о композициях…", { [weak self] in self?.onEditTracks?(tracks) })
        ]
        for name in playlistNames?() ?? [] { actions.append(("В плейлист «" + name + "»", { [weak self] in self?.onAddToPlaylist?(tracks, name) })) }
        actions += [("Показать в Finder", { NSWorkspace.shared.activateFileViewerSelecting(PlayerView.finderURLs(tracks)) }), ("", {}), ("Удалить из медиатеки…", { [weak self] in self?.onRemove?(tracks,false) })]
        return actions
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { playSelectedTracks(); return }
        if event.keyCode == 53 { selection.clear(); updateSelection(); return }
        let columns = max(1, (orderedTracks.count + columnCount - 1) / columnCount)
        let offsets: [UInt16: Int] = [125: 1, 126: -1, 123: -columns, 124: columns]
        if let offset = offsets[event.keyCode], !orderedTracks.isEmpty {
            let current = selection.focus.flatMap { id in orderedTracks.firstIndex { $0.id == id } } ?? (offset > 0 ? -1 : orderedTracks.count)
            let index = max(0, min(orderedTracks.count - 1, current + offset))
            select(orderedTracks[index].id, modifiers: event.modifierFlags); scrollToVisible(rows[index].frame); return
        }
        super.keyDown(with: event)
    }
    var palette = AlbumPalette.fallback
    var artwork: NSImage?
    var standalone = false { didSet { controls.first?.isHidden = standalone || group == nil; rows.forEach { $0.spacious = standalone }; needsLayout = true; needsDisplay = true } }
    private var contentLeft: CGFloat { standalone ? 32 : 44 }
    private var headingSize: CGFloat { standalone ? 20 : 16 }
    private var headingY: CGFloat { standalone ? 20 : 24 }
    private var subtitleY: CGFloat { standalone ? 55 : 51 }
    private var tracksY: CGFloat { standalone ? 110 : 103 }
    var summary: String { AlbumSummary.text(orderedTracks) }
    var titleFrame: NSRect { NSRect(x: contentLeft, y: headingY, width: max(1, actionX - contentLeft - 8), height: 22) }
    var closeFrame: NSRect { NSRect(x: 12, y: titleFrame.midY - 9, width: 18, height: 18) }
    private var rowHeight: CGFloat { standalone ? 28 : 24 }
    var caretX: CGFloat = 0
    var fullHeight: CGFloat = 240
    var currentID: String? { didSet { updatePlayback() } }
    var playing = false { didSet { updatePlayback() } }
    var onClose: (() -> Void)?
    var onPlayTracks: ((Track, [Track]) -> Void)?
    var onQueue: (([Track], Bool) -> Void)?
    var onEditTrack: ((Track) -> Void)?
    var onEdit: ((Track) -> Void)?
    var onShowList: ((LibraryGroup) -> Void)?
    private var controls: [DrawerIconButton] = []
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = true; setAccessibilityRole(.group); setAccessibilityLabel("Композиции альбома")
        controls = [DrawerIconButton(.close, label: "Закрыть альбом") { [weak self] in self?.onClose?() },
                    DrawerIconButton(.play, label: "Воспроизвести альбом") { [weak self] in self?.playAlbum() },
                    DrawerIconButton(.shuffle, label: "Перемешать альбом") { [weak self] in self?.playAlbum(shuffle: true) },
                    DrawerIconButton(.more, label: "Действия с альбомом") { [weak self] in self?.showOptions() }]
        controls.forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }
    var columnCount: Int { bounds.width < 640 ? 1 : 2 }
    func preferredHeight(width: CGFloat) -> CGFloat { max(standalone ? 260 : 194, tracksY + CGFloat((orderedTracks.count + (width < 640 ? 1 : 2) - 1) / (width < 640 ? 1 : 2)) * rowHeight + 24) + (standalone ? 0 : 7) }
    func configure(_ group: LibraryGroup) {
        if self.group?.key != group.key { selection.clear() }
        self.group = group
        controls.enumerated().forEach { $0.element.isHidden = $0.offset == 0 && standalone }
        orderedTracks = group.tracks.enumerated().sorted {
            let a = ($0.element.discNumber ?? 1, $0.element.number > 0 ? $0.element.number : 10000 + $0.offset, $0.offset)
            let b = ($1.element.discNumber ?? 1, $1.element.number > 0 ? $1.element.number : 10000 + $1.offset, $1.offset)
            return a < b
        }.map(\.element)
        rows.forEach { $0.removeFromSuperview() }; rows = []
        for (i, track) in orderedTracks.enumerated() {
            let row = AlbumDrawerRow(track: track, position: i) { [weak self] in guard let self else { return }; self.onPlayTracks?(track, self.orderedTracks) }
            row.onQueue = { [weak self] tracks, next in self?.onQueue?(tracks, next) }
            row.onEdit = { [weak self] track in self?.onEditTrack?(track) }
            row.onSelect = { [weak self] flags, context in self?.select(track.id, modifiers: flags, context: context) }
            row.contextActions = { [weak self] in self?.actionsForSelection() ?? [] }
            row.spacious = standalone; rows.append(row); addSubview(row)
        }
        selection.retain(orderedTracks.map(\.id)); updateSelection()
        refreshArtwork(); updatePlayback(); needsLayout = true
    }
    func clear() {
        selection.clear(); group = nil; orderedTracks = []; rows.forEach { $0.removeFromSuperview() }; rows = []; artwork = nil
        controls.forEach { $0.isHidden = true }; needsDisplay = true
    }
    func refreshArtwork() {
        if let first = orderedTracks.first { artwork = Covers.image(first); palette = Covers.palette(first) }
        else { artwork = nil; palette = .fallback }
        rows.forEach { $0.palette = palette; $0.needsDisplay = true }; needsDisplay = true
    }
    private func updatePlayback() { for row in rows { row.current = row.track.id == currentID; row.playing = playing; row.needsDisplay = true } }
    func playAlbum(shuffle: Bool = false) {
        let tracks = shuffle ? orderedTracks.shuffled() : orderedTracks
        if let first = tracks.first { onPlayTracks?(first, tracks) }
    }
    private var textRight: CGFloat { bounds.width < 720 ? bounds.width - 24 : bounds.width * (standalone ? 0.62 : 0.65) }
    private var actionX: CGFloat {
        let titleWidth = ((group?.title ?? "") as NSString).size(withAttributes: [.font: font(headingSize, bold: true)]).width
        return min(textRight - 82, contentLeft + titleWidth + 12)
    }
    override func layout() {
        super.layout()
        guard bounds.width >= 120 else { return }
        controls[0].frame = closeFrame
        for i in 1..<4 { controls[i].frame = NSRect(x: actionX + CGFloat(i - 1) * 26, y: headingY, width: 23, height: 22) }
        let count = (rows.count + columnCount - 1) / columnCount
        let width = max(1, (textRight - contentLeft - CGFloat(columnCount - 1) * 22) / CGFloat(columnCount))
        for (i, row) in rows.enumerated() { let col = i / max(1, count); let index = i % max(1, count); row.frame = NSRect(x: contentLeft + CGFloat(col) * (width + 22), y: tracksY + CGFloat(index) * rowHeight, width: width, height: rowHeight) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width >= 120, fullHeight > 7 else { return }
        guard let group else { if standalone { fill(bounds, AlbumPalette.fallback.background); text("Выберите альбом", bounds.insetBy(dx: 32, dy: 32), size: 18, ink: .white) }; return }
        let top: CGFloat = standalone ? 0 : 7
        let body = NSRect(x: 0, y: top, width: bounds.width, height: fullHeight - top); fill(body, palette.background)
        if let artwork, bounds.width >= 720 {
            let zone = NSRect(x: textRight, y: top, width: bounds.width - textRight, height: fullHeight - top)
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: zone).addClip()
            let side = max(zone.width, zone.height); let imageRect = NSRect(x: zone.maxX - side, y: zone.midY - side / 2, width: side, height: side)
            artwork.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            let cg = NSGraphicsContext.current!.cgContext
            let bg = palette.background; let clear = bg.withAlphaComponent(0)
            let horizontal = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [bg.cgColor, clear.cgColor] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(horizontal, start: CGPoint(x: zone.minX, y: 0), end: CGPoint(x: zone.minX + zone.width * 0.52, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            let bottom = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [clear.cgColor, bg.cgColor] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(bottom, start: CGPoint(x: 0, y: body.maxY - min(90, body.height * 0.3)), end: CGPoint(x: 0, y: body.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            let radial = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [clear.cgColor, bg.withAlphaComponent(0.35).cgColor] as CFArray, locations: [0, 1])!
            let center = CGPoint(x: zone.maxX, y: zone.minY + zone.height * 0.35)
            cg.drawRadialGradient(radial, startCenter: center, startRadius: zone.width * 0.3, endCenter: center, endRadius: max(zone.width, zone.height), options: [.drawsAfterEndLocation])
            NSGraphicsContext.restoreGraphicsState()
        }
        // Recessed compartment: shadow gradients stay inside both crisp edges.
        let cg = NSGraphicsContext.current!.cgContext
        let shade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0, 0.35).cgColor, NSColor.clear.cgColor] as CFArray, locations: [0, 1])!
        cg.drawLinearGradient(shade, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: top + 12), options: [])
        let lower = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.clear.cgColor, color(0, 0.20).cgColor] as CFArray, locations: [0, 1])!
        cg.drawLinearGradient(lower, start: CGPoint(x: 0, y: body.maxY - 8), end: CGPoint(x: 0, y: body.maxY), options: [])
        fill(NSRect(x: 0, y: top, width: bounds.width, height: 0.5), color(0, 0.25)); fill(NSRect(x: 0, y: body.maxY - 0.5, width: bounds.width, height: 0.5), color(0, 0.25))
        if !standalone {
        let caret = NSBezierPath(); caret.move(to: NSPoint(x: caretX - 6, y: 7.5)); caret.line(to: NSPoint(x: caretX, y: 0.5)); caret.line(to: NSPoint(x: caretX + 6, y: 7.5)); caret.close(); palette.background.setFill(); caret.fill()
        let edge = NSBezierPath(); edge.move(to: NSPoint(x: caretX - 6, y: 7)); edge.line(to: NSPoint(x: caretX, y: 0)); edge.line(to: NSPoint(x: caretX + 6, y: 7)); color(0, 0.25).setStroke(); edge.lineWidth = 0.5; edge.stroke()
        }
        let titleRect = titleFrame
        centeredGlyphText(group.title, in: titleRect.offsetBy(dx: 0, dy: 1), size: headingSize, ink: color(0, 0.2), bold: true, alignment: .left)
        centeredGlyphText(group.title, in: titleRect, size: headingSize, ink: palette.primary, bold: true, alignment: .left)
        text(orderedTracks.first?.albumDisplayArtist ?? group.subtitle, NSRect(x: contentLeft, y: subtitleY, width: textRight - contentLeft, height: 19), size: standalone ? 13 : 12, ink: palette.secondary)
        text(summary, NSRect(x: contentLeft, y: subtitleY + 20, width: textRight - contentLeft, height: 18), size: standalone ? 12 : 11, ink: palette.secondary)
    }
    private func showOptions() {
        if ClassicPopup.active?.anchor === controls[3] { ClassicPopup.active?.close(); return }
        var actions: [(String, () -> Void)] = [
            ("Воспроизвести альбом", { [weak self] in self?.playAlbum() }),
            ("Перемешать альбом", { [weak self] in self?.playAlbum(shuffle: true) }),
            ("Воспроизвести следующим", { [weak self] in guard let self else { return }; self.onQueue?(self.orderedTracks, true) }),
            ("Добавить в очередь позже", { [weak self] in guard let self else { return }; self.onQueue?(self.orderedTracks, false) })
        ]
        if !standalone { actions.append(("Показать списком", { [weak self] in self?.showListFromMenu() })) }
        actions.append(("Информация об альбоме…", { [weak self] in self?.editFromMenu() }))
        let tracks=orderedTracks
        actions += [("Показать в Finder", { [weak self] in self?.onRevealAlbum?(tracks) }), ("", {}), ("Удалить альбом…", { [weak self] in self?.onRemove?(tracks,true) })]
        ClassicActionMenu.show(actions, from: controls[3])
    }
    @objc private func playFromMenu() { playAlbum() }
    @objc private func shuffleFromMenu() { playAlbum(shuffle: true) }
    @objc private func showListFromMenu() { if let group { onShowList?(group) } }
    @objc private func editFromMenu() { if let first = orderedTracks.first { onEdit?(first) } }
}
