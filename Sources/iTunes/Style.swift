import AppKit
import CoreText
import ImageIO

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
    NSFont(name: bold ? "LucidaGrande-Bold" : "LucidaGrande", size: size) ?? NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
}
func text(_ string: String, _ rect: NSRect, size: CGFloat = 11, ink: NSColor = color(0x292929), bold: Bool = false, alignment: NSTextAlignment = .left) {
    let p = NSMutableParagraphStyle(); p.alignment = alignment; p.lineBreakMode = .byTruncatingTail
    (string as NSString).draw(in: rect, withAttributes: [.font: font(size, bold: bold), .foregroundColor: ink, .paragraphStyle: p])
}
// Center the visible glyphs, rather than a fixed-height font line box.
func centeredGlyphText(_ string: String, in rect: NSRect, size: CGFloat, ink: NSColor, bold: Bool = false, alignment: NSTextAlignment = .center) {
    guard let context = NSGraphicsContext.current else { return }
    let attributes: [NSAttributedString.Key: Any] = [.font: font(size, bold: bold), .foregroundColor: ink]
    var line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    if CTLineGetTypographicBounds(line, nil, nil, nil) > rect.width {
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        line = CTLineCreateTruncatedLine(line, Double(max(1, rect.width)), .end, ellipsis) ?? line
    }
    let visible = CTLineGetImageBounds(line, nil)
    guard !visible.isEmpty else { return }
    let cg = context.cgContext
    cg.saveGState(); cg.clip(to: rect)
    cg.textMatrix = .identity
    cg.translateBy(x: alignment == .left ? rect.minX - visible.minX : rect.midX - visible.midX, y: rect.midY + (context.isFlipped ? visible.midY : -visible.midY))
    if context.isFlipped { cg.scaleBy(x: 1, y: -1) }
    cg.textPosition = .zero; CTLineDraw(line, cg); cg.restoreGState()
}
func engravedText(_ string: String, _ rect: NSRect, size: CGFloat = 11, ink: NSColor = color(0x5A6577), bold: Bool = false, alignment: NSTextAlignment = .left) {
    let pixel = 1 / (NSGraphicsContext.current?.cgContext.ctm.a.magnitude ?? 2)
    text(string, rect.offsetBy(dx: 0, dy: pixel), size: size, ink: color(0xFFFFFF, 0.7), bold: bold, alignment: alignment)
    text(string, rect, size: size, ink: ink, bold: bold, alignment: alignment)
}
func fill(_ rect: NSRect, _ c: NSColor) { c.setFill(); rect.fill() }
func gradient(_ rect: NSRect, _ top: UInt32, _ bottom: UInt32, radius: CGFloat = 0) {
    NSGradient(starting: color(top), ending: color(bottom))!.draw(in: NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius), angle: 90)
}
func stroke(_ rect: NSRect, _ c: NSColor, radius: CGFloat = 0) {
    c.setStroke(); let p = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius); p.lineWidth = 1; p.stroke()
}
enum AlbumSummary {
    static func inflect(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n = abs(count) % 100
        let word = (11...14).contains(n) ? many : n % 10 == 1 ? one : (2...4).contains(n % 10) ? few : many
        return "\(count) " + word
    }
    static func duration(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? min(315_360_000, max(0, seconds)) : 0
        let minutes = safe > 0 ? max(1, Int((safe / 60).rounded())) : 0
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return inflect(rest, "минута", "минуты", "минут") }
        let h = inflect(hours, "час", "часа", "часов")
        return rest == 0 ? h : h + " " + inflect(rest, "минута", "минуты", "минут")
    }
    static func text(_ tracks: [Track]) -> String {
        let year = tracks.compactMap(\.year).filter { $0 > 0 }.min().map(String.init) ?? "Год не указан"
        let count = inflect(tracks.count, "песня", "песни", "песен")
        let seconds = tracks.reduce(0.0) { $0 + ($1.duration.isFinite ? max(0, $1.duration) : 0) }
        return [year, count, duration(seconds)].joined(separator: " · ")
    }
}

func timeString(_ value: Double) -> String { let n = Int(max(0, value.isFinite ? value : 0)); return String(format: "%d:%02d", n / 60, n % 60) }

func drawSpeaker(_ r: NSRect, loud: Bool) {
    NSGraphicsContext.saveGraphicsState()
    let p = NSBezierPath()
    p.appendRect(NSRect(x: r.minX, y: r.midY - 2, width: 3, height: 4))
    p.move(to: NSPoint(x: r.minX + 3, y: r.midY - 2)); p.line(to: NSPoint(x: r.minX + 7, y: r.minY)); p.line(to: NSPoint(x: r.minX + 7, y: r.maxY)); p.line(to: NSPoint(x: r.minX + 3, y: r.midY + 2)); p.close()
    NSGradient(starting: color(0x42464B), ending: color(0x92969B))!.draw(in: p, angle: 90)
    color(0x41464C).setStroke()
    if loud { for n in 0..<3 {
        let x = r.minX + 9 + CGFloat(n) * 3; let h = r.height * (0.35 + CGFloat(n) * 0.23)
        let wave = NSBezierPath(); wave.lineWidth = 1
        wave.move(to: NSPoint(x: x, y: r.midY - h / 2)); wave.curve(to: NSPoint(x: x, y: r.midY + h / 2), controlPoint1: NSPoint(x: x + 2, y: r.midY - h / 4), controlPoint2: NSPoint(x: x + 2, y: r.midY + h / 4)); wave.stroke()
    } }
    NSGraphicsContext.restoreGraphicsState()
}
/// Native vector equivalents of the supplied SVG glyphs; all coordinates are in points.
/// The shared renderer supplies the engraving, lower specular edge and Aqua state.
enum MetalGlyph {
    case play, pause, previous, next, add, shuffle, repeatAll, repeatOne, artwork, more
    var canvas: CGSize {
        switch self {
        case .play, .pause: return CGSize(width: 14, height: 14)
        case .previous, .next: return CGSize(width: 13, height: 11)
        case .add: return CGSize(width: 12, height: 12)
        case .artwork: return CGSize(width: 13, height: 12)
        default: return CGSize(width: 14, height: 12)
        }
    }
    static func playback(_ symbol: String) -> MetalGlyph? {
        switch symbol { case "▶": return .play; case "Ⅱ": return .pause; case "◀◀": return .previous; case "▶▶": return .next; default: return nil }
    }
    private var path: CGPath {
        let result = CGMutablePath()
        func polygon(_ points: [CGPoint]) { guard let first = points.first else { return }; result.move(to: first); for point in points.dropFirst() { result.addLine(to: point) }; result.closeSubpath() }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat) { result.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerWidth: radius, cornerHeight: radius) }
        func line(_ points: [CGPoint], width: CGFloat, cap: CGLineCap = .round) { let p = CGMutablePath(); p.addLines(between: points); result.addPath(p.copy(strokingWithWidth: width, lineCap: cap, lineJoin: .round, miterLimit: 2)) }
        switch self {
        case .play:
            result.move(to: CGPoint(x: 3.5, y: 1.8))
            result.addCurve(to: CGPoint(x: 4.36, y: 1.32), control1: CGPoint(x: 3.5, y: 1.35), control2: CGPoint(x: 3.98, y: 1.08))
            result.addLine(to: CGPoint(x: 12.1, y: 6.52))
            result.addCurve(to: CGPoint(x: 12.1, y: 7.48), control1: CGPoint(x: 12.45, y: 6.75), control2: CGPoint(x: 12.45, y: 7.25))
            result.addLine(to: CGPoint(x: 4.36, y: 12.68))
            result.addCurve(to: CGPoint(x: 3.5, y: 12.2), control1: CGPoint(x: 3.98, y: 12.92), control2: CGPoint(x: 3.5, y: 12.65)); result.closeSubpath()
        case .pause: rect(3, 2, 3, 10, 0.8); rect(8, 2, 3, 10, 0.8)
        case .previous:
            rect(1, 1.5, 1.8, 8, 0.4)
            polygon([CGPoint(x: 2.8, y: 5.5), CGPoint(x: 7.8, y: 1.8), CGPoint(x: 7.8, y: 9.2)])
            polygon([CGPoint(x: 7.5, y: 5.5), CGPoint(x: 12.5, y: 1.8), CGPoint(x: 12.5, y: 9.2)])
        case .next:
            polygon([CGPoint(x: 5.5, y: 5.5), CGPoint(x: 0.5, y: 1.8), CGPoint(x: 0.5, y: 9.2)])
            polygon([CGPoint(x: 10.2, y: 5.5), CGPoint(x: 5.2, y: 1.8), CGPoint(x: 5.2, y: 9.2)]); rect(10.2, 1.5, 1.8, 8, 0.4)
        case .add:
            line([CGPoint(x: 6, y: 2), CGPoint(x: 6, y: 10)], width: 2, cap: .square)
            line([CGPoint(x: 2, y: 6), CGPoint(x: 10, y: 6)], width: 2, cap: .square)
        case .shuffle:
            line([CGPoint(x: 1, y: 3), CGPoint(x: 3.8, y: 3), CGPoint(x: 8.5, y: 9), CGPoint(x: 11.2, y: 9)], width: 1.7)
            line([CGPoint(x: 1, y: 9), CGPoint(x: 3.8, y: 9), CGPoint(x: 8.5, y: 3), CGPoint(x: 11.2, y: 3)], width: 1.7)
            for y: CGFloat in [3, 9] { polygon([CGPoint(x: 10.5, y: y - 1.8), CGPoint(x: 13.5, y: y), CGPoint(x: 10.5, y: y + 1.8)]) }
        case .repeatAll, .repeatOne:
            let upper = CGMutablePath(); upper.move(to: CGPoint(x: 10.5, y: 3)); upper.addLine(to: CGPoint(x: 3.5, y: 3)); upper.addCurve(to: CGPoint(x: 1.5, y: 5), control1: CGPoint(x: 2.4, y: 3), control2: CGPoint(x: 1.5, y: 3.9)); upper.addLine(to: CGPoint(x: 1.5, y: 6.2))
            result.addPath(upper.copy(strokingWithWidth: 1.7, lineCap: .round, lineJoin: .round, miterLimit: 2))
            let lower = CGMutablePath(); lower.move(to: CGPoint(x: 3.5, y: 9)); lower.addLine(to: CGPoint(x: 10.5, y: 9)); lower.addCurve(to: CGPoint(x: 12.5, y: 7), control1: CGPoint(x: 11.6, y: 9), control2: CGPoint(x: 12.5, y: 8.1)); lower.addLine(to: CGPoint(x: 12.5, y: 5.8))
            result.addPath(lower.copy(strokingWithWidth: 1.7, lineCap: .round, lineJoin: .round, miterLimit: 2))
            polygon([CGPoint(x: 9.8, y: 1.1), CGPoint(x: 13, y: 3), CGPoint(x: 9.8, y: 4.9)])
            polygon([CGPoint(x: 4.2, y: 7.1), CGPoint(x: 1, y: 9), CGPoint(x: 4.2, y: 10.9)])
            if self == .repeatOne { polygon([CGPoint(x: 6.1, y: 5.2), CGPoint(x: 7.1, y: 4.3), CGPoint(x: 8, y: 4.3), CGPoint(x: 8, y: 7.8), CGPoint(x: 7, y: 7.8), CGPoint(x: 7, y: 5.5), CGPoint(x: 6.6, y: 5.9)]) }
        case .artwork:
            let box = CGPath(roundedRect: CGRect(x: 1.2, y: 1.5, width: 10.6, height: 9), cornerWidth: 1, cornerHeight: 1, transform: nil)
            result.addPath(box.copy(strokingWithWidth: 1.4, lineCap: .butt, lineJoin: .round, miterLimit: 2))
            line([CGPoint(x: 1.2, y: 4.2), CGPoint(x: 11.8, y: 4.2)], width: 1.2, cap: .butt)
            polygon([CGPoint(x: 6.5, y: 5.6), CGPoint(x: 4.2, y: 8.2), CGPoint(x: 8.8, y: 8.2)])
        case .more: for x: CGFloat in [3, 7, 11] { result.addEllipse(in: CGRect(x: x - 1.3, y: 4.7, width: 2.6, height: 2.6)) }
        }
        return result
    }
    func draw(in rect: NSRect, active: Bool = false, pressed: Bool = false) {
        guard let context = NSGraphicsContext.current else { return }; let cg = context.cgContext
        cg.saveGState(); defer { cg.restoreGState() }
        if !context.isFlipped { cg.translateBy(x: 0, y: rect.minY + rect.maxY); cg.scaleBy(x: 1, y: -1) }
        cg.translateBy(x: rect.midX - canvas.width / 2 + (self == .play ? 1 : 0), y: rect.midY - canvas.height / 2 + (pressed ? 0.5 : 0))
        let shape = path
        if active {
            cg.saveGState(); cg.setShadow(offset: .zero, blur: 3, color: color(0x2463BD, 0.35).cgColor); cg.setFillColor(color(0x2463BD).cgColor); cg.addPath(shape); cg.fillPath(); cg.restoreGState()
        }
        cg.saveGState(); cg.translateBy(x: 0, y: 1); cg.setFillColor(color(0xFFFFFF, active ? 0.8 : 0.85).cgColor); cg.addPath(shape); cg.fillPath(); cg.restoreGState()
        cg.saveGState(); cg.addPath(shape); cg.clip()
        if active { cg.setFillColor(color(0x2463BD).cgColor); cg.fill(CGRect(origin: .zero, size: canvas)) }
        else {
            let ramp = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0x3A3A3A).cgColor, color(0x565656).cgColor] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(ramp, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: canvas.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        // Subtract a one-point lower copy to leave a dark rim only on upper edges.
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        cg.setFillColor(color(0, active ? 0.15 : 0.35).cgColor); cg.addPath(shape); cg.fillPath()
        cg.saveGState(); cg.setBlendMode(.destinationOut); cg.translateBy(x: 0, y: 1); cg.setFillColor(NSColor.black.cgColor); cg.addPath(shape); cg.fillPath(); cg.restoreGState()
        cg.endTransparencyLayer(); cg.restoreGState()
    }
}

func legacyStatusIcon(_ symbol: String, in rect: NSRect, selected: Bool, pressed: Bool = false) {
    let glyph: MetalGlyph = symbol == "+" ? .add : symbol == "⤨" ? .shuffle : symbol.hasPrefix("↻") ? (symbol.contains("¹") ? .repeatOne : .repeatAll) : .artwork
    glyph.draw(in: rect, active: selected && (symbol == "⤨" || symbol.hasPrefix("↻")), pressed: pressed)
}

func metallicGradient(_ rect: NSRect, top: NSColor, bottom: NSColor, radius: CGFloat = 0) {
    guard let context = NSGraphicsContext.current else { return }; let cg = context.cgContext
    cg.saveGState(); defer { cg.restoreGState() }
    cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); cg.clip()
    let ramp = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(ramp, start: CGPoint(x: 0, y: context.isFlipped ? rect.minY : rect.maxY), end: CGPoint(x: 0, y: context.isFlipped ? rect.maxY : rect.minY), options: [])
}

final class RetroButton: NSButton {
    var symbol = ""
    var scopeTab = false
    var paneHeader = false
    var statusControl = false
    var round = false
    var selected = false
    var dark = false
    var aqua = false
    var fontSize: CGFloat = 11
    var segmentIndex: Int?
    var segmentCount = 4
    var trafficMini = false
    var trafficMonochrome = false
    var lcdControl = false
    enum TrafficSymbol { case close, minimize, zoom }
    var trafficSymbol: TrafficSymbol?
    var showTrafficGlyphs = false { didSet { needsDisplay = true } }
    var traffic: UInt32?
    private var playbackHeld = false
    var actionBlock: (() -> Void)?
    convenience init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.init(frame: .zero); self.symbol = symbol; title = label; toolTip = label
        setAccessibilityLabel(label); actionBlock = action; target = self; self.action = #selector(invoke)
        setButtonType(.momentaryPushIn); isBordered = false; focusRingType = .none
    }
    @objc func invoke() { actionBlock?() }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, round, MetalGlyph.playback(symbol) != nil else { super.mouseDown(with: event); return }
        playbackHeld = true; needsDisplay = true; displayIfNeeded()
        defer { playbackHeld = false; needsDisplay = true; displayIfNeeded() }
        super.mouseDown(with: event)
    }
    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        if round, MetalGlyph.playback(symbol) != nil { playbackHeld = flag; needsDisplay = true; displayIfNeeded() }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 4, bounds.height > 4 else { return }
        let r = bounds.insetBy(dx: 1, dy: 1)
        if scopeTab || paneHeader {
            if paneHeader {
                gradient(bounds, 0xFAFAFA, 0xDEDEDE)
                fill(NSRect(x: 0, y: 0, width: bounds.width, height: 0.5), color(0xA5A5A5))
                fill(NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5), color(0xA5A5A5))
            } else if selected || isHighlighted {
                gradient(bounds.insetBy(dx: 0.5, dy: 1), 0xB8B8B8, 0xD4D4D4, radius: 3)
                stroke(bounds.insetBy(dx: 0.5, dy: 1), color(0x999999), radius: 3)
                fill(NSRect(x: 3, y: 1, width: bounds.width - 6, height: 0.5), color(0x747474, 0.4))
            }
            let rect = bounds.insetBy(dx: paneHeader ? 14 : 4, dy: 2)
            centeredGlyphText(symbol, in: rect.offsetBy(dx: 0, dy: isFlipped ? 0.5 : -0.5), size: fontSize, ink: color(0xFFFFFF, 0.8), bold: !paneHeader)
            centeredGlyphText(symbol, in: rect, size: fontSize, ink: selected ? color(0x222222) : color(0x4A4A4A), bold: !paneHeader)
            if paneHeader {
                color(0x646464).setFill(); let arrow = NSBezierPath()
                let cy = bounds.midY
                arrow.move(to: NSPoint(x: 6, y: cy + (selected ? 2 : -3)))
                arrow.line(to: NSPoint(x: selected ? 12 : 11, y: cy + (selected ? 2 : 0)))
                arrow.line(to: NSPoint(x: selected ? 9 : 6, y: selected ? cy - 3 : cy + 3)); arrow.close(); arrow.fill()
            }
            return
        }
        if lcdControl {
            color(0x778264).setFill(); NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
            centeredGlyphText(symbol, in: bounds.insetBy(dx: 2, dy: 2), size: 8, ink: color(0xEEF2D9), bold: true)
            return
        }
        if let kind = trafficSymbol,
           let artwork = TrafficLightArtwork.image(kind, mini: trafficMini, active: NSApp.isActive && (window?.isKeyWindow == true || ClassicPopup.active?.anchor?.window === window),
                                                    hovered: showTrafficGlyphs, pressed: isHighlighted,
                                                    monochrome: trafficMonochrome, edited: window?.isDocumentEdited ?? false) {
            let size: CGFloat = trafficMini ? 14 : 16
            artwork.draw(in: NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                         hints: [.interpolation: NSImageInterpolation.high.rawValue])
            return
        }
        if let original = traffic {
            let inactive = !NSApp.isActive || (window?.isKeyWindow == false && ClassicPopup.active?.anchor?.window !== window)
            let c: UInt32 = inactive || (trafficMonochrome && !showTrafficGlyphs && !isHighlighted) ? 0xD6D6D6 : original
            gradient(r, c, c &- 0x202020, radius: r.width / 2); stroke(r, color(0x000000, 0.35), radius: r.width / 2)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: r).addClip()
            if isHighlighted { fill(r, color(0x000000, 0.18)) }
            NSGradient(starting: color(0xFFFFFF, 0.65), ending: color(0xFFFFFF, 0))!.draw(in: NSBezierPath(ovalIn: NSRect(x: r.minX + 1.5, y: r.minY + 1.5, width: r.width - 3, height: r.height * 0.52)), angle: 90)
            let gleam = NSBezierPath(roundedRect: NSRect(x: r.minX + 3, y: r.maxY - 3, width: r.width - 6, height: 1), xRadius: 1, yRadius: 1)
            color(0xFFFFFF, 0.45).setFill(); gleam.fill()
            NSGraphicsContext.restoreGraphicsState()
            if !inactive && (showTrafficGlyphs || isHighlighted) {
                let cx = bounds.midX; let cy = bounds.midY
                color(trafficSymbol == .close ? 0x7E201A : trafficSymbol == .minimize ? 0x805700 : 0x24541D).setStroke()
                let glyph = NSBezierPath(); glyph.lineWidth = 1.5; glyph.lineCapStyle = .round
                switch trafficSymbol {
                case .close:
                    glyph.move(to: NSPoint(x: cx - 2.8, y: cy - 2.8)); glyph.line(to: NSPoint(x: cx + 2.8, y: cy + 2.8))
                    glyph.move(to: NSPoint(x: cx + 2.8, y: cy - 2.8)); glyph.line(to: NSPoint(x: cx - 2.8, y: cy + 2.8))
                case .minimize:
                    glyph.move(to: NSPoint(x: cx - 3.4, y: cy)); glyph.line(to: NSPoint(x: cx + 3.4, y: cy))
                case .zoom:
                    glyph.move(to: NSPoint(x: cx - 3, y: cy + 3)); glyph.line(to: NSPoint(x: cx + 3, y: cy - 3))
                    glyph.move(to: NSPoint(x: cx - 3, y: cy)); glyph.line(to: NSPoint(x: cx - 3, y: cy + 3)); glyph.line(to: NSPoint(x: cx, y: cy + 3))
                    glyph.move(to: NSPoint(x: cx, y: cy - 3)); glyph.line(to: NSPoint(x: cx + 3, y: cy - 3)); glyph.line(to: NSPoint(x: cx + 3, y: cy))
                case nil: break
                }
                glyph.stroke()
            }
            return
        }
        if statusControl { drawStatusContainer(); legacyStatusIcon(symbol, in: bounds, selected: selected, pressed: isHighlighted); return }
        if round, let glyph = MetalGlyph.playback(symbol) {
            let pressed = playbackHeld || isHighlighted; let down: CGFloat = isFlipped ? 1 : -1
            let face = pressed ? r.offsetBy(dx: 0, dy: down * 0.5) : r
            if !pressed { color(0xFFFFFF, 0.6).setFill(); NSBezierPath(ovalIn: r.offsetBy(dx: 0, dy: down)).fill() }
            metallicGradient(face, top: color(pressed ? 0xA7A7A7 : 0xFAFAFA), bottom: color(pressed ? 0xD4D4D4 : 0xC8C8C8), radius: face.height / 2)
            stroke(face, color(pressed ? 0x555555 : 0x6E6E6E), radius: face.height / 2)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: face).addClip()
            if pressed {
                let top = isFlipped ? face.minY : face.maxY - 6
                metallicGradient(NSRect(x: face.minX, y: top, width: face.width, height: 6), top: color(0, 0.45), bottom: color(0, 0))
            }
            NSBezierPath(rect: NSRect(x: face.minX, y: isFlipped ? face.minY : face.midY, width: face.width, height: face.height / 2)).addClip()
            stroke(face.insetBy(dx: 1, dy: 1), color(0xFFFFFF, pressed ? 0.12 : 1), radius: face.height / 2)
            NSGraphicsContext.restoreGraphicsState()
            glyph.draw(in: bounds, pressed: pressed); return
        }
        let active = selected || isHighlighted
        NSGraphicsContext.saveGraphicsState()
        if let index = segmentIndex {
            let clip = NSBezierPath(roundedRect: r, xRadius: index == 0 || index == segmentCount - 1 ? 3 : 0, yRadius: index == 0 || index == segmentCount - 1 ? 3 : 0)
            if index == 0 { clip.appendRect(NSRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height)) }
            if index == segmentCount - 1 { clip.appendRect(NSRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height)) }
            clip.addClip()
        }
        gradient(r, dark ? (active ? 0x191919 : 0x797979) : (aqua && active ? 0x8AC8FA : active ? 0x8B8F94 : 0xFAFAFA), dark ? (active ? 0x383838 : 0x454545) : (aqua && active ? 0x2E7DD6 : active ? 0xC7CCD2 : 0xB7B9BC), radius: round ? r.height / 2 : segmentIndex == nil ? 4 : 0)
        if round {
            stroke(r.insetBy(dx: 1, dy: 1), color(0xFFFFFF, 0.8), radius: r.height / 2)
        }
        stroke(r, color(0x777A7E), radius: round ? r.height / 2 : segmentIndex == nil ? 4 : 0)
        if !round { let p = NSBezierPath(); p.move(to: NSPoint(x: r.minX + 5, y: r.minY + 1.5)); p.line(to: NSPoint(x: r.maxX - 5, y: r.minY + 1.5)); color(0xFFFFFF, active ? 0.1 : 0.7).setStroke(); p.stroke() }
        NSGraphicsContext.restoreGraphicsState()
        if let glyph = MetalGlyph.playback(symbol) { glyph.draw(in: bounds, pressed: isHighlighted); return }
        centeredGlyphText(symbol, in: bounds.insetBy(dx: 3, dy: 2), size: round ? 16 : fontSize, ink: dark || (aqua && active) ? .white : color(0x3C4045), bold: true)
    }
    private func drawStatusContainer() {
        let index = segmentIndex ?? 0; let count = segmentIndex == nil ? 1 : segmentCount
        let cluster = NSRect(x: -CGFloat(index) * bounds.width + 0.5, y: 0.5, width: CGFloat(count) * bounds.width - 1, height: bounds.height - 1)
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: bounds).addClip()
        NSBezierPath(roundedRect: cluster, xRadius: 3, yRadius: 3).addClip()
        metallicGradient(bounds, top: color(isHighlighted ? 0xBDBDBD : 0xF9F9F9), bottom: color(isHighlighted ? 0xC7C7C7 : 0xBDBDBD))
        if isHighlighted {
            let top = isFlipped ? bounds.minY : bounds.maxY - 4
            metallicGradient(NSRect(x: 0, y: top, width: bounds.width, height: 4), top: color(0, 0.35), bottom: color(0, 0))
        }
        stroke(cluster.insetBy(dx: 1, dy: 1), color(0xFFFFFF, isHighlighted ? 0.15 : 0.9), radius: 2)
        stroke(cluster, color(0x888888), radius: 3)
        if index < count - 1 { fill(NSRect(x: bounds.maxX - 0.5, y: 1, width: 0.5, height: bounds.height - 2), color(0xA8A8A8)) }
        NSGraphicsContext.restoreGraphicsState()
    }

}

final class AquaSlider: NSControl {
    enum FlankingIcons { case none, speakers, squares }
    var value: Double = 0.5 { didSet { value = min(1, max(0, value)); needsDisplay = true } }
    var onChange: ((Double) -> Void)?
    var ticked = false
    var aquaThumb = false
    var diamond = false
    var compact = false
    var flankingIcons: FlankingIcons = .none
    private var dragging = false { didSet { needsDisplay = true } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); setAccessibilityElement(true); setAccessibilityRole(.slider)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func accessibilityValue() -> Any? { NSNumber(value: value) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: 0) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: 1) }
    override func setAccessibilityValue(_ value: Any?) {
        guard isEnabled, let number = value as? NSNumber else { return }
        self.value = number.doubleValue; onChange?(self.value)
    }
    override func accessibilityPerformIncrement() -> Bool { guard isEnabled else { return false }; value += 0.05; onChange?(value); return true }
    override func accessibilityPerformDecrement() -> Bool { guard isEnabled else { return false }; value -= 0.05; onChange?(value); return true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: _ = accessibilityPerformDecrement()
        case 124, 126: _ = accessibilityPerformIncrement()
        case 115: value = 0; onChange?(value)
        case 119: value = 1; onChange?(value)
        default: super.keyDown(with: event)
        }
    }
    override var isFlipped: Bool { true }
    private var trackRect: NSRect {
        let inset: CGFloat = diamond || compact ? 5 : flankingIcons == .speakers ? 22 : flankingIcons == .squares ? 20 : 8
        let trailing: CGFloat = diamond || compact ? 5 : flankingIcons == .speakers ? 28 : flankingIcons == .squares ? 26 : 8
        return NSRect(x: inset, y: bounds.midY - 2, width: max(1, bounds.width - inset - trailing), height: 4)
    }
    // Draw in the control's flipped coordinates so every highlight shares a top-down light source.
    private func silverGradient(_ rect: NSRect, top: UInt32, bottom: UInt32, radius: CGFloat) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); cg.clip()
        let colors = [color(top).cgColor, color(bottom).cgColor] as CFArray
        let ramp = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        cg.drawLinearGradient(ramp, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        cg.restoreGState()
    }
    override func draw(_ dirtyRect: NSRect) {
        let bar = trackRect; let x = bar.minX + value * bar.width
        if diamond {
            // The LCD scrubber retains its olive groove and diamond handle.
            let lcdBar = NSRect(x: bar.minX, y: bounds.midY - 2, width: bar.width, height: 5)
            gradient(lcdBar, 0x717771, 0xB8BFB4, radius: 3); stroke(lcdBar, color(0x53594D, 0.45), radius: 3)
            let p = NSBezierPath(); p.move(to: NSPoint(x: x, y: bounds.midY - 5)); p.line(to: NSPoint(x: x + 4, y: bounds.midY)); p.line(to: NSPoint(x: x, y: bounds.midY + 5)); p.line(to: NSPoint(x: x - 4, y: bounds.midY)); p.close(); color(0xF6F8EB).setFill(); p.fill(); color(0x59634D, 0.5).setStroke(); p.lineWidth = 0.5; p.stroke()
            return
        }
        if ticked {
            let y: CGFloat = 8
            let groove = NSRect(x: bar.minX, y: y - 2, width: bar.width, height: 4)
            silverGradient(groove, top: 0x858585, bottom: 0xB4B4B4, radius: 1); stroke(groove, color(0x888888), radius: 1)
            for i in 0...10 { fill(NSRect(x: bar.minX + CGFloat(i) * bar.width / 10, y: 21, width: 0.5, height: 4), color(0x888888)) }
            let p = NSBezierPath(); p.move(to: NSPoint(x: x - 5, y: y - 6)); p.line(to: NSPoint(x: x + 5, y: y - 6)); p.line(to: NSPoint(x: x + 5, y: y + 3)); p.line(to: NSPoint(x: x, y: y + 8)); p.line(to: NSPoint(x: x - 5, y: y + 3)); p.close()
            NSGradient(starting: color(dragging ? 0x4E8ED6 : 0x9BC8F2), ending: color(dragging ? 0xA6CFEF : 0xE7F6FF))!.draw(in: p, angle: 90)
            color(0x5165A1).setStroke(); p.lineWidth = 1; p.stroke()
            fill(NSRect(x: x - 3.5, y: y - 4.5, width: 7, height: 1), color(0xFFFFFF, 0.9))
            return
        }
        let highlight = NSBezierPath(roundedRect: bar.offsetBy(dx: 0, dy: 1), xRadius: 2, yRadius: 2)
        color(0xFFFFFF, 0.65).setFill(); highlight.fill()
        silverGradient(bar, top: 0x7A7A7A, bottom: 0x9E9E9E, radius: 2)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).addClip()
        let insetShade = NSGradient(starting: color(0x000000, 0.45), ending: color(0x000000, 0))!
        insetShade.draw(in: NSBezierPath(rect: NSRect(x: bar.minX, y: bar.minY, width: bar.width, height: 2)), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        let d: CGFloat = compact ? 8 : 13
        let knob = NSRect(x: x - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        let shape = NSBezierPath(ovalIn: knob)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = color(0x000000, 0.35); shadow.shadowOffset = NSSize(width: 0, height: -1); shadow.shadowBlurRadius = 2; shadow.set()
        color(0xC2C2C2).setFill(); shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        silverGradient(knob, top: aquaThumb ? 0xDBF1FF : dragging ? 0xDCDCDC : 0xF8F8F8, bottom: aquaThumb ? (dragging ? 0x327BBD : 0x6BACDE) : dragging ? 0x9E9E9E : 0xC2C2C2, radius: d / 2)
        stroke(knob, color(dragging ? 0x525252 : 0x686868), radius: d / 2)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: knob.minX, y: knob.minY, width: d, height: d / 2)).addClip()
        color(0xFFFFFF, 0.9).setStroke(); let rim = NSBezierPath(ovalIn: knob.insetBy(dx: 1.25, dy: 1.25)); rim.lineWidth = 1; rim.stroke()
        NSGraphicsContext.restoreGraphicsState()
        if !compact { drawIcons() }
    }
    private func drawIcons() {
        func etched(_ draw: (CGFloat, NSColor) -> Void) { draw(1, color(0xFFFFFF, 0.65)); draw(0, color(flankingIcons == .speakers ? 0x4A4A4A : 0x555555, flankingIcons == .speakers ? 0.75 : 1)) }
        if flankingIcons == .speakers {
            for loud in [false, true] {
                let left: CGFloat = loud ? bounds.width - 20 : 0
                etched { offset, ink in
                    let y = self.bounds.midY + offset; let p = NSBezierPath()
                    p.appendRect(NSRect(x: left, y: y - 1.5, width: 3, height: 3))
                    p.move(to: NSPoint(x: left + 3, y: y - 1.5)); p.line(to: NSPoint(x: left + 6, y: y - 4)); p.line(to: NSPoint(x: left + 6, y: y + 4)); p.line(to: NSPoint(x: left + 3, y: y + 1.5)); p.close()
                    ink.setFill(); p.fill(); ink.setStroke()
                    for n in 0..<(loud ? 3 : 1) {
                        let x = left + 8 + CGFloat(n) * 3; let h = CGFloat(4 + n * 3)
                        let wave = NSBezierPath(); wave.lineWidth = 1
                        wave.move(to: NSPoint(x: x, y: y - h / 2)); wave.curve(to: NSPoint(x: x, y: y + h / 2), controlPoint1: NSPoint(x: x + 2, y: y - h / 4), controlPoint2: NSPoint(x: x + 2, y: y + h / 4)); wave.stroke()
                    }
                }
            }
        } else if flankingIcons == .squares {
            for large in [false, true] {
                let d: CGFloat = large ? 12 : 8; let x: CGFloat = large ? bounds.width - 14 : 0
                etched { offset, ink in ink.setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: self.bounds.midY - d / 2 + offset, width: d, height: d), xRadius: 1, yRadius: 1).fill() }
            }
        }
    }
    override func mouseDown(with event: NSEvent) { guard isEnabled else { return }; window?.makeFirstResponder(self); dragging = true; update(event) }
    override func mouseDragged(with event: NSEvent) { guard isEnabled else { return }; update(event) }
    override func mouseUp(with event: NSEvent) { guard dragging else { return }; update(event); dragging = false }
    private func update(_ event: NSEvent) { let bar = trackRect; value = (convert(event.locationInWindow, from: nil).x - bar.minX) / bar.width; onChange?(value) }
}

@MainActor enum Covers {
    static let ready = Notification.Name("iTunes.thumbnail.ready")
    static let cache: NSCache<NSString, NSImage> = { let cache = NSCache<NSString, NSImage>(); cache.totalCostLimit = 64 * 1024 * 1024; return cache }()
    private static let palettes: NSCache<NSString, AlbumPaletteBox> = { let cache = NSCache<NSString, AlbumPaletteBox>(); cache.countLimit = 512; return cache }()
    static func palette(_ track: Track) -> AlbumPalette { palettes.object(forKey: key(track) as NSString)?.value ?? .fallback }
    private static let decoder: OperationQueue = { let queue = OperationQueue(); queue.name = "iTunes thumbnails"; queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .utility; return queue }()
    private static var pending = Set<String>()
    private static var generation = 0
    static func key(_ track: Track) -> String { track.artworkPath ?? track.id }
    static func cached(_ track: Track) -> NSImage? { cache.object(forKey: key(track) as NSString) }
    static func invalidate() { generation += 1; pending.removeAll(); cache.removeAllObjects(); palettes.removeAllObjects() }
    private static let placeholder: NSImage = {
        let image = NSImage(size: NSSize(width: 512, height: 512), flipped: true) { r in
            gradient(r, 0x50545B, 0x24272D)
            let disc = NSRect(x: 70, y: 70, width: 372, height: 372)
            color(0xC7CBD1, 0.16).setFill(); NSBezierPath(ovalIn: disc).fill()
            color(0xE1E5EB, 0.18).setStroke(); NSBezierPath(ovalIn: disc).stroke()
            color(0x30343A).setFill(); NSBezierPath(ovalIn: NSRect(x: 220, y: 220, width: 72, height: 72)).fill()
            text("♫", NSRect(x: 142, y: 123, width: 228, height: 250), size: 190, ink: color(0xCDD3DD, 0.7), alignment: .center)
            return true
        }
        return image
    }()
    static func image(_ track: Track) -> NSImage {
        if let cached = cached(track) { return cached }
        let id = key(track)
        guard track.artwork != nil || track.artworkPath != nil else { return placeholder }
        if pending.insert(id).inserted {
            let data = track.artwork; let path = track.artworkPath; let version = generation
            decoder.addOperation {
                let thumbnail: CGImage? = autoreleasepool {
                    let source: CGImageSource?
                    let options = [kCGImageSourceShouldCache: false] as CFDictionary
                    if let data { source = CGImageSourceCreateWithData(data as CFData, options) }
                    else if let path { source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, options) }
                    else { source = nil }
                    guard let source else { return nil }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                }
                let palette = thumbnail.map(AlbumPalette.extract)
                Task { @MainActor in
                    guard generation == version else { return }
                    pending.remove(id)
                    if let thumbnail {
                        if let palette { palettes.setObject(AlbumPaletteBox(palette), forKey: id as NSString) }
                        cache.setObject(NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height)), forKey: id as NSString, cost: thumbnail.width * thumbnail.height * 4)
                        NotificationCenter.default.post(name: ready, object: id)
                    } else { cache.setObject(placeholder, forKey: id as NSString) }
                }
            }
        }
        return placeholder
    }
    static func draw(_ track: Track, in rect: NSRect, alpha: CGFloat = 1) {
        let cover = image(track)
        var target = rect
        if track.isVideo, cover.size.width > 0, cover.size.height > 0 {
            fill(rect, color(0x111111))
            let scale = min(rect.width / cover.size.width, rect.height / cover.size.height)
            target = NSRect(x: rect.midX - cover.size.width * scale / 2, y: rect.midY - cover.size.height * scale / 2, width: cover.size.width * scale, height: cover.size.height * scale)
        }
        cover.draw(in: target, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
}

final class CenteredSearchCell: NSSearchFieldCell {
    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        var r = super.searchTextRect(forBounds: rect)
        r.size.height = ceil(NSLayoutManager().defaultLineHeight(for: font ?? NSFont.systemFont(ofSize: 11)))
        r.origin.y = floor((rect.height - r.height) / 2)
        return r
    }
}
final class CenteredSearchField: NSSearchField {
    override var searchTextBounds: NSRect {
        var r = super.searchTextBounds
        r.size.height = ceil(NSLayoutManager().defaultLineHeight(for: font ?? NSFont.systemFont(ofSize: 11)))
        r.origin.y = floor((bounds.height - r.height) / 2)
        return r
    }
}

final class ClassicTextCell: NSTextFieldCell {
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let h = ceil(NSLayoutManager().defaultLineHeight(for: font ?? NSFont.systemFont(ofSize: 11)))
        return NSRect(x: rect.minX + 5, y: rect.minY + floor((rect.height - h) / 2), width: rect.width - 10, height: h)
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        fill(cellFrame, .white); stroke(cellFrame, color(0xA8A8A8))
        fill(NSRect(x: cellFrame.minX + 1, y: cellFrame.minY + 1, width: cellFrame.width - 2, height: 1), color(0xE0E0E0))
        super.drawInterior(withFrame: drawingRect(forBounds: cellFrame), in: controlView)
    }
}

/// Three actual buttons share one bezel; glyphs use pixel-aligned paths rather than font symbols.
final class ViewModePicker: NSView {
    override var isFlipped: Bool { true }
    var onChange: ((Int) -> Void)?
    var selectedIndex = 1 { didSet { for (i, b) in segments.enumerated() { b.state = i == selectedIndex ? .on : .off; b.needsDisplay = true } } }
    private var segments: [ViewModeSegment] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        for (i, title) in ["Список", "Сетка", "Cover Flow"].enumerated() {
            let b = ViewModeSegment(frame: .zero); b.index = i; b.title = title; b.setAccessibilityLabel(title)
            b.isBordered = false; b.focusRingType = .none; b.target = self; b.action = #selector(choose(_:)); b.toolTip = title
            addSubview(b); segments.append(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func choose(_ sender: ViewModeSegment) { selectedIndex = sender.index; onChange?(sender.index) }
    override func layout() {
        super.layout(); let width = (bounds.width - 2) / 3
        for (i, button) in segments.enumerated() { button.frame = NSRect(x: 1 + CGFloat(i) * width, y: 1, width: width, height: bounds.height - 2) }
    }
    override func draw(_ dirtyRect: NSRect) {
        gradient(bounds.insetBy(dx: 0, dy: 1), 0xF2F2F2, 0xBEBEBE, radius: 4)
        stroke(bounds.insetBy(dx: 0, dy: 1), color(0x777777), radius: 4)
    }
}
final class ViewModeSegment: NSButton {
    override var isFlipped: Bool { true }
    var index = 0
    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on || isHighlighted
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: bounds, xRadius: index == 1 ? 0 : 3, yRadius: index == 1 ? 0 : 3)
        if index == 0 { clip.appendRect(NSRect(x: bounds.midX, y: 0, width: bounds.width / 2, height: bounds.height)) }
        if index == 2 { clip.appendRect(NSRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)) }
        clip.addClip()
        gradient(bounds, selected ? 0x444444 : 0xFFFFFF, selected ? 0x777777 : 0xC7C7C7)
        fill(NSRect(x: 0, y: 0, width: bounds.width, height: 1), color(selected ? 0x292929 : 0xFFFFFF, 0.8))
        if index > 0 { fill(NSRect(x: 0, y: 0, width: 0.5, height: bounds.height), color(0x777777)) }
        let cx = bounds.midX; let cy = bounds.midY
        let ink = selected ? NSColor.white : color(0x52575B)
        ink.setFill(); ink.setStroke()
        if index == 0 {
            for i in 0..<6 { NSRect(x: cx - 8, y: cy - 5.5 + CGFloat(i) * 2, width: 16, height: 1).fill() }
        } else if index == 1 {
            for y in 0..<2 { for x in 0..<3 { NSRect(x: cx - 7.5 + CGFloat(x) * 5.5, y: cy - 5 + CGFloat(y) * 6, width: 4, height: 4).fill() } }
        } else {
            let p = NSBezierPath(); p.lineWidth = 1
            p.appendRect(NSRect(x: cx - 4.5, y: cy - 6, width: 9, height: 12))
            p.move(to: NSPoint(x: cx - 7, y: cy - 6)); p.line(to: NSPoint(x: cx - 10, y: cy - 4)); p.line(to: NSPoint(x: cx - 10, y: cy + 4)); p.line(to: NSPoint(x: cx - 7, y: cy + 6)); p.close()
            p.move(to: NSPoint(x: cx + 7, y: cy - 6)); p.line(to: NSPoint(x: cx + 10, y: cy - 4)); p.line(to: NSPoint(x: cx + 10, y: cy + 4)); p.line(to: NSPoint(x: cx + 7, y: cy + 6)); p.close(); p.stroke()
            fill(NSRect(x: cx - 3, y: cy - 4.5, width: 6, height: 9), ink.withAlphaComponent(0.65))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Original artwork is bundled locally; unknown genre tags retain the drawn fallback.
@MainActor enum LegacyAssets {
    private static var cache: [String: NSImage] = [:]
    static func image(_ name: String, folder: String, extension ext: String) -> NSImage? {
        let key = folder + "/" + name
        if let cached = cache[key] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: folder), let image = NSImage(contentsOf: url) else { return nil }
        cache[key] = image; return image
    }
    static func icon(_ name: String) -> NSImage? { image("playrecent-" + name, folder: "LegacyIcons", extension: "icns") }
    static func genreName(_ value: String) -> String? {
        let aliases: [String: [String]] = [
            "alternative": ["alternative", "alternative rock", "альтернатива"],
            "blues": ["blues", "блюз"], "books": ["books", "audiobooks", "аудиокниги"],
            "christian": ["christian", "gospel", "christian & gospel", "христианская музыка"],
            "classicT": ["classic"], "classical": ["classical", "классика", "классическая музыка"],
            "country": ["country", "кантри"], "dance": ["dance", "dance music", "танцевальная", "танцевальная музыка"],
            "electronic": ["electronic", "electronics", "electronica", "electronic music", "электроника", "электронная музыка"],
            "finearts": ["fine arts", "finearts"], "folk": ["folk", "фолк"],
            "hiphop": ["hip hop", "hip-hop", "hiphop", "rap", "hip-hop/rap", "хип-хоп", "рэп"],
            "holiday": ["holiday", "christmas", "праздничная музыка"], "jazz": ["jazz", "джаз"],
            "jpop": ["j-pop", "jpop"], "kayokyoku": ["kayokyoku"], "latin": ["latin", "латинская музыка"],
            "newage": ["new age", "newage", "new-age", "нью-эйдж"],
            "pop": ["pop", "pop music", "поп", "поп-музыка"], "rb": ["r&b", "rnb", "r'n'b", "rhythm and blues", "r&b/soul"],
            "reggae": ["reggae", "регги"], "rock": ["rock", "рок"],
            "soundtrack": ["soundtrack", "soundtracks", "саундтрек", "саундтреки"],
            "spoken": ["spoken", "spoken word", "разговорный жанр"], "teens": ["teens", "teen pop"],
            "vocal": ["vocal", "вокал"], "world": ["world", "world music", "музыка мира"]
        ]
        let normalized = Track.normalized(value).replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "‑", with: "-")
        for candidate in [normalized] + normalized.components(separatedBy: CharacterSet(charactersIn: ";,/")) {
            let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name = aliases.first(where: { $0.value.contains(key) })?.key { return "genre-" + name }
        }
        return nil
    }
    static func genre(_ value: String) -> NSImage? {
        guard let name = genreName(value) else { return nil }
        return image(name, folder: "GenreArtwork", extension: "jpg")
    }
}

@MainActor enum TrafficLightArtwork {
    static func image(_ kind: RetroButton.TrafficSymbol, mini: Bool, active: Bool, hovered: Bool, pressed: Bool, monochrome: Bool = false, edited: Bool = false) -> NSImage? {
        let size = mini ? "Mini" : "Regular"
        let suffix = mini ? " Mini" : ""
        let name: String
        let state: String
        if !active || (monochrome && !hovered && !pressed) {
            state = "Regular"; name = "Button Background" + suffix + (edited && kind == .close ? " Dot" : "")
        } else {
            let button = kind == .close ? "Close" : kind == .minimize ? "Minimize" : "Maximize"
            if pressed {
                state = "Pressed"
                if edited && kind == .close {
                    name = mini ? "Button Close Pressed Mini Dot" : "Button Close pressed Dot"
                } else { name = "Button " + button + " Pressed" + suffix }
            } else if hovered {
                state = "Rollover"; name = "Button " + button + " Hover" + suffix
            } else {
                state = "Regular"; name = "Button " + button + suffix + (edited && kind == .close ? " Dot" : "")
            }
        }
        return LegacyAssets.image(name, folder: "TrafficLights/" + state + "/" + size, extension: "png")
    }
}
