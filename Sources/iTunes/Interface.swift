import AppKit
import AVKit
import UniformTypeIdentifiers
import QuartzCore
import CryptoKit

final class FlippedView: NSView { override var isFlipped: Bool { true } }

@MainActor final class LibraryTrackTable: NSTableView {
    var onContext: ((Int, NSPoint) -> Void)?
    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil); onContext?(row(at: point), point)
    }
}
final class StripedRow: NSTableRowView {
    var alternate = false
    override func drawBackground(in dirtyRect: NSRect) { fill(bounds, alternate ? color(0xEDF3FC) : .white) }
    override func drawSelection(in dirtyRect: NSRect) {
        gradient(bounds, isEmphasized ? 0x77A8E2 : 0xAFB8C5, isEmphasized ? 0x3272C5 : 0x8D9AAD)
        fill(NSRect(x: 0, y: 0, width: bounds.width, height: 1), color(0xFFFFFF, 0.28))
    }
}

final class LegacyHeader: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        gradient(cellFrame, 0xFAFAFA, 0xD5D7DA)
        fill(NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1), color(0xA5A9AE))
        fill(NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY, width: 1, height: cellFrame.height), color(0xB6BAC0))
        text(stringValue, cellFrame.insetBy(dx: 7, dy: 4), size: 10, bold: true)
    }
}

/// One geometry shared by drawing and the seek control: spectrum and timing never overlap.
struct LCDMetrics {
    let elapsed: NSRect
    let duration: NSRect
    let progress: NSRect
    let spectrum: NSRect
    init(rect: NSRect, mini: Bool, total: Double) {
        // Reserve the rightmost LCD column for Up Next without shrinking the seek target vertically.
        let rect = mini ? rect : NSRect(x: rect.minX, y: rect.minY, width: rect.width - 28, height: rect.height)
        let sample = timeString(total)
        func width(_ text: String, minimum: CGFloat) -> CGFloat { max(minimum, ceil((text as NSString).size(withAttributes: [.font: font(9)]).width) + 2) }
        let y = rect.maxY - 15
        elapsed = NSRect(x: rect.minX + (mini ? 18 : 24), y: y, width: width(sample, minimum: mini ? 28 : 34), height: 13)
        let rightWidth = width(mini ? sample : "−" + sample, minimum: mini ? 30 : 42)
        duration = NSRect(x: rect.maxX - (mini ? 19 : 10) - rightWidth, y: y, width: rightWidth, height: 13)
        progress = NSRect(x: elapsed.maxX + 2, y: y + 1, width: max(1, duration.minX - elapsed.maxX - 4), height: 11)
        spectrum = NSRect(x: rect.minX + 22, y: rect.minY + 5, width: max(1, rect.width - 44), height: max(0, y - rect.minY - 10))
    }
}

enum GridGrouping: String, CaseIterable {
    case albums = "Альбомы", artists = "Исполнители", genres = "Жанры", composers = "Композиторы"
}
struct LibraryGroup {
    var key: String
    var title: String
    var subtitle: String
    var tracks: [Track]
}

enum LibrarySortField: String, Codable, CaseIterable {
    case title, artist, genre, year
    var label: String { switch self { case .title: return "По названию"; case .artist: return "По исполнителю"; case .genre: return "По жанру"; case .year: return "По году" } }
}
struct LibrarySortSettings: Codable, Equatable {
    var primary: LibrarySortField = .title
    var secondary: LibrarySortField? = nil
    var ascending = true
    var yearAscending = true
    static let defaultsKey = "library.sort.v1"
    static func load(_ defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: defaultsKey), var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        if value.secondary == value.primary { value.secondary = nil }; return value
    }
    func save(_ defaults: UserDefaults) { if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) } }
    func compare(_ a: Track, _ b: Track, titleA: String? = nil, titleB: String? = nil) -> Bool {
        for field in [primary] + (secondary.map { [$0] } ?? []) {
            let result: ComparisonResult
            if field == .year {
                let ay = a.year.flatMap { $0 > 0 ? $0 : nil }; let by = b.year.flatMap { $0 > 0 ? $0 : nil }
                if ay == nil && by != nil { return false }; if ay != nil && by == nil { return true }
                result = ay == by ? .orderedSame : (ay ?? 0) < (by ?? 0) ? .orderedAscending : .orderedDescending
            } else {
                func value(_ track: Track, _ title: String?) -> String {
                    switch field {
                    case .title: return title ?? track.sortTitle ?? track.title
                    case .artist: return title != nil ? (track.sortAlbumArtist ?? track.albumDisplayArtist) : (track.sortArtist ?? track.artist)
                    case .genre: return track.genre
                    case .year: return ""
                    }
                }
                result = value(a, titleA).localizedStandardCompare(value(b, titleB))
            }
            if result != .orderedSame { let direction = field == .year && primary != .year ? yearAscending : ascending; return direction ? result == .orderedAscending : result == .orderedDescending }
        }
        let tie = (titleA ?? a.sortTitle ?? a.title).localizedStandardCompare(titleB ?? b.sortTitle ?? b.title)
        return tie == .orderedSame ? a.id < b.id : tie == .orderedAscending
    }
    func groups(_ groups: [LibraryGroup], kind: GridGrouping) -> [LibraryGroup] {
        func representative(_ group: LibraryGroup) -> Track {
            var t = group.tracks[0]
            t.id = group.key
            t.year = group.tracks.compactMap(\.year).filter { $0 > 0 }.min()
            if kind == .artists { t.albumArtist = group.title; t.sortAlbumArtist = group.title }
            if kind == .genres { t.genre = group.title }
            return t
        }
        let prepared = groups.map { group -> (LibraryGroup, Track, String) in
            let title = kind == .albums && !group.tracks[0].isVideo ? (group.tracks[0].sortAlbum ?? group.title) : group.title
            return (group, representative(group), title)
        }
        return prepared.sorted { compare($0.1, $1.1, titleA: $0.2, titleB: $1.2) }.map { $0.0 }
    }
}

extension LibrarySortSettings {
    private enum CodingKeys: String, CodingKey { case primary, secondary, ascending, yearAscending }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primary = try c.decodeIfPresent(LibrarySortField.self, forKey: .primary) ?? .title
        secondary = try c.decodeIfPresent(LibrarySortField.self, forKey: .secondary)
        ascending = try c.decodeIfPresent(Bool.self, forKey: .ascending) ?? true
        yearAscending = try c.decodeIfPresent(Bool.self, forKey: .yearAscending) ?? true
    }
}

/// A shared-perspective scene keeps each cover and its reflection in one 3D plane.
@MainActor final class FlowScene: NSView {
    var onClick: ((NSPoint, Int) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        // The parent stage paints black. A transparent compositor lets negative-depth
        // flattened cards remain visible instead of falling behind an opaque surface.
        layer = CALayer(); layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { onClick?(convert(event.locationInWindow, from: nil), event.clickCount) }
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
}

/// A continuous target in album units. AppKit deltas already respect natural scrolling.
struct CoverFlowScrollState {
    private(set) var position = 0.0
    private(set) var finishing = false
    private var horizontal: Bool?
    private var lastTime = -Double.infinity
    private var lastMovement = -Double.infinity
    private var velocity = 0.0
    mutating func reset(to position: Double) { self.position = position; horizontal = nil; finishing = false; velocity = 0; lastTime = -.infinity; lastMovement = -.infinity }
    mutating func finish(at timestamp: Double, count: Int) -> Double {
        guard !finishing else { return position }
        let speed = timestamp-lastMovement < 0.08 ? velocity : 0
        var end = (position + min(0.75,max(-0.75,speed * 0.065))).rounded()
        if speed > 2 { end = max(end,position.rounded(.up)) }
        if speed < -2 { end = min(end,position.rounded(.down)) }
        position = min(Double(max(0,count-1)),max(0,end)); finishing = true
        return position
    }
    mutating func update(x: Double, y: Double, precise: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase, timestamp: Double, presented: Double, count: Int) -> Double {
        guard count > 0 else { reset(to: 0); return 0 }
        let coasting = !momentum.isEmpty
        if phase.contains(.began) || (!coasting && !phase.contains(.ended) && (timestamp-lastTime > 0.25 || finishing)) { reset(to:presented) }
        // macOS momentum must not become a second animation after our finger-up trajectory.
        if coasting { return finish(at:timestamp,count:count) }
        let dt = min(0.1,max(1.0/240,lastTime.isFinite ? timestamp-lastTime : 1.0/60))
        lastTime = timestamp
        if horizontal == nil && (x != 0 || y != 0) { horizontal = abs(x) > abs(y) }
        let delta = -(horizontal == true ? x : y)
        if precise {
            let travel = delta/140
            position += travel
            if travel != 0 {
                let fraction = 1-exp(-dt/0.025)
                velocity += (min(12,max(-12,travel/dt))-velocity)*fraction
                lastMovement = timestamp
            }
        } else if delta != 0 { position = position.rounded() + (delta > 0 ? 1 : -1) }
        position = min(Double(count-1),max(0,position))
        if phase.contains(.ended) || phase.contains(.cancelled) { return finish(at:timestamp,count:count) }
        return position
    }
}

/// Render independently of input-event frequency, retaining velocity between targets.
struct CoverFlowMotion {
    private(set) var position = 0.0
    private(set) var target = 0.0
    private(set) var velocity = 0.0
    private(set) var tracking = false
    private var lastFrame: Double?
    private var began = 0.0
    private var start = 0.0
    private var startVelocity = 0.0
    static let settleDuration = 0.18
    mutating func reset(to value: Double) { position = value; target = value; velocity = 0; tracking = false; lastFrame = nil; start = value }
    mutating func follow(_ value: Double, at now: Double) { target = value; tracking = true; if lastFrame == nil { lastFrame = now } }
    mutating func settle(_ value: Double, at now: Double) {
        if !tracking && abs(target - value) < 0.00001 { return }
        target = value; tracking = false; began = now; start = position
        let delta = target - start, sign = delta < 0 ? -1.0 : 1.0
        startVelocity = sign * min(3 * abs(delta) / Self.settleDuration, max(0, velocity * sign))
    }
    mutating func clamp(maximum: Double) {
        position = min(maximum, max(0, position)); target = min(maximum, max(0, target))
    }
    @discardableResult mutating func advance(at now: Double) -> Bool {
        let dt = min(1.0 / 15, max(0, now - (lastFrame ?? now)))
        lastFrame = now
        if tracking {
            let omega = 125.0, error = position - target, c = velocity + omega * error, decay = exp(-omega * dt)
            position = target + (error + c * dt) * decay
            velocity = (velocity - omega * c * dt) * decay
            if abs(position - target) < 0.00005 && abs(velocity) < 0.002 { position = target; velocity = 0; return false }
            return true
        }
        let elapsed = max(0, now - began)
        let t = elapsed >= Self.settleDuration - 1e-9 ? 1 : min(1, elapsed / Self.settleDuration)
        if t == 1 { position = target; velocity = 0; return false }
        let delta = target - start, tangent = startVelocity * Self.settleDuration
        position = start + (3 * t * t - 2 * t * t * t) * delta + (t * t * t - 2 * t * t + t) * tangent
        velocity = ((6 * t - 6 * t * t) * delta + (3 * t * t - 4 * t + 1) * tangent) / Self.settleDuration
        return true
    }
}

struct CoverFlowGeometry {
    private static func hermite(_ t: CGFloat, end: CGFloat, firstSlope: CGFloat, lastSlope: CGFloat) -> CGFloat {
        (3 * t * t - 2 * t * t * t) * end + (t * t * t - 2 * t * t + t) * firstSlope + (t * t * t - t * t) * lastSlope
    }
    static func offset(distance: CGFloat, size: CGFloat) -> CGFloat {
        let depth = abs(distance), sign: CGFloat = distance < 0 ? -1 : 1
        return sign * size * (hermite(min(depth, 1), end: 0.79, firstSlope: 1.1, lastSlope: 0.24) + max(0, depth - 1) * 0.24)
    }
    static func angle(depth: CGFloat) -> CGFloat { let t = min(depth, 1); return 62 * t * (2 - t) * .pi / 180 }
    static func recession(depth: CGFloat) -> CGFloat { hermite(min(depth, 1), end: 80, firstSlope: 0, lastSlope: 17) + max(0, depth - 1) * 17 }
    static func settledPosition(from start: CGFloat, to target: CGFloat, elapsed: Double) -> CGFloat {
        let t = CGFloat(min(1, max(0, elapsed / CoverFlowMotion.settleDuration)))
        return t == 1 ? target : start + (target - start) * (3 * t * t - 2 * t * t * t)
    }
}

@available(macOS 14.0, *)
@MainActor private final class FlowDisplayTarget: NSObject {
    weak var stage: AlbumStage?
    init(_ stage: AlbumStage) { self.stage = stage }
    @objc func tick(_ link: CADisplayLink) {
        guard let stage else { link.invalidate(); return }
        stage.advanceFlow(at: link.targetTimestamp)
    }
}

@MainActor final class AlbumStage: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var albums: [Track] = [] {
        didSet {
            if oldValue.map(\.albumKey) != albums.map(\.albumKey) || zip(oldValue, albums).contains(where: { $0.artworkPath != $1.artworkPath || $0.artwork != $1.artwork }) { rebuildScene() }
            selected = min(selected, max(0, albums.count - 1))
            needsLayout = true; needsDisplay = true; updateLabels()
        }
    }
    var selected = 0 {
        didSet { if oldValue != selected { if !updatingFlowSelection { scrollState.reset(to: Double(selected)); animateFlow(to: CGFloat(selected)) }; needsDisplay = true; updateLabels() } }
    }
    var grid = false {
        didSet { stopFlowMotion(); if !grid { closeDrawer(animated: false) }; if grid { coverLayers.values.forEach { $0.removeFromSuperlayer() }; coverLayers.removeAll(); shades.removeAll() }; clearScrub(); scene.isHidden = grid; scrubber.isHidden = grid; needsLayout = true; needsDisplay = true; updateLabels() }
    }
    var showsFlowLabels = false
    var onSelect: ((Track) -> Void)?
    var gridGroups: [LibraryGroup] = [] { didSet { clearScrub(); reconcileDrawer(); needsDisplay = true } }
    var gridGrouping: GridGrouping = .albums { didSet { if gridGrouping != .albums { closeDrawer(animated: false) } } }
    var tileSize: CGFloat = 128 { didSet { needsLayout = true; needsDisplay = true } }
    var onOpenGroup: ((LibraryGroup) -> Void)?
    var onEditAlbum: ((Track) -> Void)?
    var onPlay: ((Track) -> Void)?
    let drawer = AlbumDrawer(frame: .zero)
    private(set) var expandedKey: String?
    private(set) var drawerExpansion: CGFloat = 0
    private let drawerClip = FlippedView()
    private var drawerAnimation: Timer?
    private var drawerClosing = false
    var onPlayTracks: ((Track, [Track]) -> Void)?
    private var gridColumns: Int { max(1, Int(bounds.width / (tileSize + 48))) }
    private var expandedIndex: Int? { expandedKey.flatMap { key in gridGroups.firstIndex { $0.key == key } } }
    private var insertionY: CGFloat { guard let index = expandedIndex else { return 0 }; return 24 + CGFloat(index / gridColumns + 1) * (tileSize + 58) - 8 }
    func gridContentHeight(width: CGFloat) -> CGFloat {
        let columns = max(1, Int(width / (tileSize + 48)))
        return CGFloat((gridGroups.count + columns - 1) / columns) * (tileSize + 58) + 24 + drawerExpansion
    }
    func tileRect(at index: Int) -> NSRect {
        let columns = gridColumns; let cell = bounds.width / CGFloat(columns)
        var y = CGFloat(index / columns) * (tileSize + 58) + 24
        if let expanded = expandedIndex, index / columns > expanded / columns { y += drawerExpansion }
        return NSRect(x: CGFloat(index % columns) * cell + (cell - tileSize) / 2, y: y, width: tileSize, height: tileSize)
    }
    private func reconcileDrawer() {
        guard let index = expandedIndex, gridGrouping == .albums, grid, !gridGroups[index].tracks.contains(where: { $0.isVideo }) else { if expandedKey != nil { closeDrawer(animated: false) }; return }
        let group = gridGroups[index]
        if drawer.group?.title != group.title || drawer.group?.tracks != group.tracks { drawer.configure(group) }
        selected = index; updateDrawerLayout()
    }
    func toggleDrawer(at index: Int, animated: Bool = true) {
        guard grid, gridGrouping == .albums, gridGroups.indices.contains(index), !gridGroups[index].tracks.contains(where: { $0.isVideo }) else { return }
        let key = gridGroups[index].key
        if expandedKey == key && !drawerClosing { closeDrawer(animated: animated); return }
        if let old = expandedIndex, old / gridColumns != index / gridColumns, drawerExpansion > 0 {
            closeDrawer(animated: animated) { [weak self] in guard let self, let new = self.gridGroups.firstIndex(where: { $0.key == key }) else { return }; self.toggleDrawer(at: new, animated: animated) }; return
        }
        window?.makeFirstResponder(self)
        drawerClosing = false; expandedKey = key; selected = index; clearScrub(); drawer.configure(gridGroups[index]); drawer.isHidden = false
        animateDrawer(to: drawer.preferredHeight(width: bounds.width), animated: animated)
        if let first = gridGroups[index].tracks.first { onSelect?(first) }
    }
    func closeDrawer(animated: Bool = true, completion: (() -> Void)? = nil) {
        guard expandedKey != nil else { completion?(); return }
        drawerClosing = true
        animateDrawer(to: 0, animated: animated) { [weak self] in
            guard let self else { return }; self.expandedKey = nil; self.drawerClosing = false; self.drawer.isHidden = true; self.needsDisplay = true; completion?()
        }
    }
    private func animateDrawer(to target: CGFloat, animated: Bool, completion: (() -> Void)? = nil) {
        drawerAnimation?.invalidate(); drawerAnimation = nil
        let start = drawerExpansion; let began = CACurrentMediaTime()
        let scroll = enclosingScrollView
        let scrollStart = scroll?.contentView.bounds.origin.y ?? 0
        let viewport = scroll?.contentSize.height ?? bounds.height
        let top = expandedIndex.map { max(0, tileRect(at: $0).minY - 12) } ?? 0
        let finalBottom = insertionY + target + 12
        let scrollEnd = target > start ? max(0, min(top, max(scrollStart, finalBottom - viewport))) : scrollStart
        func moveScroll(_ fraction: Double) {
            guard let scroll else { return }
            let y = min(max(0, frame.height - viewport), max(0, scrollStart + (scrollEnd - scrollStart) * fraction))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, abs(start - target) > 0.5 else { drawerExpansion = target; updateDrawerLayout(); moveScroll(1); completion?(); return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let progress = min(1, (CACurrentMediaTime() - began) / 0.24)
                // Invert the x component of cubic-bezier(0.25, 1, 0.5, 1).
                var low = 0.0; var high = 1.0
                for _ in 0..<14 { let t = (low + high) / 2; let x = 0.75 * (1 - t) * (1 - t) * t + 1.5 * (1 - t) * t * t + t * t * t; if x < progress { low = t } else { high = t } }
                let t = (low + high) / 2; let eased = 1 - pow(1 - t, 3)
                self.drawerExpansion = progress == 1 ? target : start + (target - start) * eased; self.updateDrawerLayout(); moveScroll(eased)
                if progress == 1 { timer.invalidate(); self.drawerAnimation = nil; completion?() }
            }
        }
        drawerAnimation = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func updateDrawerLayout() {
        guard grid else { return }
        if let index = expandedIndex {
            drawer.fullHeight = drawer.preferredHeight(width: bounds.width)
            if drawerAnimation == nil && !drawerClosing { drawerExpansion = drawer.fullHeight }
            drawer.caretX = tileRect(at: index).midX
            drawerClip.frame = NSRect(x: 0, y: insertionY, width: bounds.width, height: drawerExpansion)
            drawerClip.bounds.origin.y = insertionY
            let fullFrame = NSRect(x: 0, y: insertionY, width: bounds.width, height: drawer.fullHeight)
            if drawer.frame != fullFrame { drawer.frame = fullFrame; drawer.needsLayout = true }
        }
        if let scroll = enclosingScrollView {
            let height = max(scroll.contentSize.height, gridContentHeight(width: bounds.width))
            if abs(frame.height - height) > 0.5 { setFrameSize(NSSize(width: frame.width, height: height)) }
        }
        needsDisplay = true
    }
    private let scene = FlowScene(frame: .zero)
    private let scrubber = FlowScrubber()
    private let albumLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private var coverLayers: [Int: CALayer] = [:]
    private var shades: [Int: CALayer] = [:]
    private var hoverTracking: NSTrackingArea?
    private(set) var scrubbedGroup: Int?
    private(set) var scrubbedTrack: Int?
    private var scrubArtwork: NSImage?
    private var scrubArtworkID: String?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area); hoverTracking = area
    }
    override func mouseMoved(with event: NSEvent) { scrub(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { clearScrub() }
    func clearScrub() {
        if scrubbedGroup != nil { scrubbedGroup = nil; scrubbedTrack = nil; scrubArtwork = nil; scrubArtworkID = nil; needsDisplay = true }
    }
    static func scrubIndex(fraction: CGFloat, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(count - 1, max(0, Int(min(1, max(0, fraction)) * CGFloat(count))))
    }
    func scrub(at point: NSPoint) {
        guard grid, gridGrouping == .albums else { clearScrub(); return }
        guard let index = gridIndex(at: point) else { clearScrub(); return }
        let rect = tileRect(at: index)
        guard !gridGroups[index].tracks.contains(where: { $0.isVideo }), rect.contains(point), let track = Self.scrubIndex(fraction: (point.x - rect.minX) / rect.width, count: gridGroups[index].tracks.count) else { clearScrub(); return }
        if scrubbedGroup != index || scrubbedTrack != track {
            scrubbedGroup = index; scrubbedTrack = track; needsDisplay = true
        }
    }
    private var scrollState = CoverFlowScrollState()
    private var flowMotion = CoverFlowMotion()
    private var flowPosition: CGFloat { CGFloat(flowMotion.position) }
    private var flowTarget: CGFloat { CGFloat(flowMotion.target) }
    private var flowTimer: Timer?
    private var flowDisplayLink: AnyObject?
    private var updatingFlowSelection = false
    private var flowSettleWork: DispatchWorkItem?
    private var flowDetailWork: DispatchWorkItem?
    private var publishedFlowKey: String?
    private var renderedCenter = -1
    func stopFlowMotion() {
        stopFlowClock(); flowSettleWork?.cancel(); flowSettleWork = nil
        flowDetailWork?.cancel(); flowDetailWork = nil
        flowMotion.reset(to: Double(selected)); scrollState.reset(to: Double(selected))
    }
    private func stopFlowClock() {
        flowTimer?.invalidate(); flowTimer = nil
        if #available(macOS 14.0, *), let link = flowDisplayLink as? CADisplayLink { link.invalidate() }
        flowDisplayLink = nil
    }
    private func startFlowClock() {
        guard flowTimer == nil && flowDisplayLink == nil else { return }
        if #available(macOS 14.0, *), window?.screen != nil, !isHiddenOrHasHiddenAncestor {
            let link = displayLink(target: FlowDisplayTarget(self), selector: #selector(FlowDisplayTarget.tick(_:)))
            let maximum = Float(window?.screen?.maximumFramesPerSecond ?? 60)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
            flowDisplayLink = link; link.add(to: .main, forMode: .common)
        } else {
            let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated { guard let self else { timer.invalidate(); return }; self.advanceFlow(at: CACurrentMediaTime()) }
            }
            flowTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func animateFlow(to position: CGFloat, tracking: Bool = false) {
        let target = min(CGFloat(max(0, albums.count - 1)), max(0, position))
        if grid || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopFlowClock(); flowMotion.reset(to: Double(target)); updateFlowSelection(); publishFlowSelection(); layoutFlow(animated: false); return
        }
        let now = CACurrentMediaTime()
        if tracking { flowMotion.follow(Double(target), at: now) }
        else { flowMotion.settle(Double(target), at: now) }
        startFlowClock()
    }
    fileprivate func advanceFlow(at time: Double) {
        let moving = flowMotion.advance(at: time)
        updateFlowSelection(); layoutFlow(animated: false)
        if !moving { stopFlowClock(); if !flowMotion.tracking { publishFlowSelection() } }
    }
    private func publishFlowSelection() {
        flowDetailWork?.cancel(); flowDetailWork = nil
        guard !grid, albums.indices.contains(selected) else { return }
        let track = albums[selected]
        let key = track.isVideo ? track.id : track.albumKey
        guard publishedFlowKey != key else { return }
        publishedFlowKey = key; onSelect?(track)
        setAccessibilityValue(track.album + ", " + track.albumDisplayArtist)
    }
    private func updateFlowSelection() {
        guard !albums.isEmpty else { return }
        let index = min(albums.count - 1, max(0, Int(flowPosition.rounded())))
        if index != selected {
            updatingFlowSelection = true; selected = index; updatingFlowSelection = false
            flowDetailWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.publishFlowSelection() }
            flowDetailWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
        }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { stopFlowMotion() } }
    private var lastSize: NSSize = .zero
    var renderedCoverCount: Int { coverLayers.count }

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        addSubview(scene); addSubview(scrubber); drawerClip.wantsLayer = true; drawerClip.layer?.masksToBounds = true; addSubview(drawerClip); drawerClip.addSubview(drawer); drawer.isHidden = true
        drawer.onClose = { [weak self] in self?.closeDrawer() }
        drawer.onPlayTracks = { [weak self] track, queue in self?.onPlayTracks?(track, queue) }
        drawer.onEdit = { [weak self] track in self?.onEditAlbum?(track) }
        drawer.onShowList = { [weak self] group in self?.onOpenGroup?(group) }
        albumLabel.font = font(12, bold: true); albumLabel.textColor = .white
        artistLabel.font = font(10); artistLabel.textColor = color(0xD2D2D2)
        for label in [albumLabel, artistLabel] { label.alignment = .center; label.lineBreakMode = .byTruncatingTail; addSubview(label) }
        scene.onClick = { [weak self] point, clicks in self?.clickCover(point, clicks: clicks) }
        scene.onScroll = { [weak self] event in self?.scrollWheel(with: event) }
        scrubber.onChange = { [weak self] value in
            guard let self, !self.albums.isEmpty else { return }
            self.choose(Int((value * Double(self.albums.count - 1)).rounded()))
        }
        setAccessibilityLabel("Cover Flow"); setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func rebuildScene() {
        renderedCenter = -1; publishedFlowKey = nil
        coverLayers.values.forEach { $0.removeFromSuperlayer() }; coverLayers.removeAll(); shades.removeAll()
        if !grid { layoutFlow(animated: false) }
    }
    func artworkDidLoad(_ key: String) {
        scrubArtworkID = nil; scrubArtwork = nil
        if let first = drawer.orderedTracks.first, Covers.key(first) == key { drawer.refreshArtwork() }
        needsDisplay = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, group) in coverLayers where albums.indices.contains(index) && Covers.key(albums[index]) == key {
            guard let cover = Covers.cached(albums[index]) else { continue }
            var rect = NSRect(x: 0, y: 0, width: 512, height: 512)
            let image = cover.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            group.sublayers?.first?.contents = image; group.sublayers?.last?.contents = image
        }
        CATransaction.commit()
    }
    private func makeLayer(_ track: Track, index: Int) {
            // Each cover and its reflection form one flattened card. Adjacent
            // cards composite in depth order rather than intersecting in 3D.
            let group = CALayer(); group.isDoubleSided = true
            let face = CALayer(); face.name = "cover"
            var rect = NSRect(x: 0, y: 0, width: 512, height: 512)
            let image = Covers.image(track).cgImage(forProposedRect: &rect, context: nil, hints: nil)
            face.contents = image; face.contentsGravity = .resizeAspectFill; face.masksToBounds = true
            face.isDoubleSided = true; face.borderWidth = 0.5; face.borderColor = color(0xFFFFFF, 0.25).cgColor
            let gloss = CAGradientLayer(); gloss.name = "gloss"
            gloss.colors = [NSColor.clear.cgColor, color(0xFFFFFF, 0.015).cgColor, color(0xFFFFFF, 0.12).cgColor]
            gloss.locations = [0, 0.5, 1]; face.addSublayer(gloss)
            let shade = CALayer(); shade.name = "shade"; shade.backgroundColor = NSColor.black.cgColor
            face.addSublayer(shade); shades[index] = shade
            group.addSublayer(face)
            let reflection = CALayer(); reflection.name = "reflection"; reflection.contents = image
            reflection.contentsGravity = .resizeAspectFill; reflection.masksToBounds = true
            reflection.transform = CATransform3DMakeScale(1, -1, 1); reflection.opacity = 0.45
            let fade = CAGradientLayer(); fade.name = "fade"
            // The reflection is vertically flipped, so its near edge is local y=0.
            fade.colors = [NSColor.black.cgColor, color(0x000000, 0.35).cgColor, NSColor.clear.cgColor]
            fade.locations = [0, 0.30, 0.65]; reflection.mask = fade
            group.addSublayer(reflection)
            scene.layer?.addSublayer(group); coverLayers[index] = group
    }
    override func layout() {
        super.layout()
        updateDrawerLayout()
        guard bounds.width >= 64, bounds.height >= 64 else { return }
        scene.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - (showsFlowLabels ? 63 : 25)))
        albumLabel.frame = NSRect(x: 16, y: bounds.height - 62, width: bounds.width - 32, height: 19)
        artistLabel.frame = NSRect(x: 16, y: bounds.height - 43, width: bounds.width - 32, height: 17)
        scrubber.frame = NSRect(x: max(42, bounds.width * 0.19), y: bounds.height - 23, width: max(80, bounds.width * 0.62), height: 15)
        if lastSize != bounds.size { lastSize = bounds.size; layoutFlow(animated: false) }
    }
    private func layoutFlow(animated: Bool) {
        guard !grid, let root = scene.layer else { return }
        flowMotion.clamp(maximum: Double(max(0, albums.count - 1)))
        let center = Int(flowPosition.rounded())
        if renderedCenter != center || coverLayers.isEmpty {
            renderedCenter = center
            let visible = albums.isEmpty ? Set<Int>() : Set(max(0, center - 10)...min(albums.count - 1, center + 10))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for index in coverLayers.keys.filter({ !visible.contains($0) }) { coverLayers.removeValue(forKey: index)?.removeFromSuperlayer(); shades.removeValue(forKey: index) }
            for index in visible where coverLayers[index] == nil { makeLayer(albums[index], index: index) }
            CATransaction.commit()
            if !albums.isEmpty { for index in max(0, center - 12)...min(albums.count - 1, center + 12) { _ = Covers.image(albums[index]) } }
        }
        let size = min(250, max(60, scene.bounds.height * 0.77))
        let floor = max(22, (scene.bounds.height - size) * 0.70)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayerTransform = CATransform3DIdentity
        for (i, group) in coverLayers {
            let distance = CGFloat(i) - flowPosition; let depth = abs(distance)
            let sign: CGFloat = distance < 0 ? -1 : 1
            let offset = CoverFlowGeometry.offset(distance: distance, size: size)
            let sizeChanged = group.bounds.width != size
            if sizeChanged { group.bounds = CGRect(x: 0, y: 0, width: size, height: size) }
            group.position = CGPoint(x: scene.bounds.midX + offset, y: floor + size / 2)
            // Sorting depth is independent of the card's projective transform.
            // This prevents a back card from cutting through a nearer card.
            group.zPosition = 10000 - depth * 100 - CGFloat(i) * 0.00001
            var transform = CATransform3DIdentity; transform.m34 = -1 / 850
            transform = CATransform3DTranslate(transform, 0, 0, -CoverFlowGeometry.recession(depth: depth))
            group.transform = CATransform3DRotate(transform, sign * CoverFlowGeometry.angle(depth: depth), 0, 1, 0)
            group.opacity = Float(min(1, max(0, (10 - depth) / 2)))
            if sizeChanged, let face = group.sublayers?.first {
                face.bounds = group.bounds; face.position = CGPoint(x: size / 2, y: size / 2)
                for overlay in face.sublayers ?? [] { overlay.frame = face.bounds }
            }
            if let reflection = group.sublayers?.last {
                reflection.bounds = group.bounds
                reflection.position = CGPoint(x: size / 2, y: -size / 2 - 1)
                reflection.mask?.frame = reflection.bounds
                if let fade = reflection.mask as? CAGradientLayer {
                    let fadeEnd = max(0.06, min(0.4, floor / size))
                    fade.locations = [0, NSNumber(value: Double(fadeEnd * 0.6)), NSNumber(value: Double(fadeEnd))]
                }
            }
            shades[i]?.opacity = Float(min(0.62, 0.16 * min(depth, 1) + max(0, depth - 1) * 0.045))
        }
        CATransaction.commit()
        scrubber.value = albums.count > 1 ? Double(selected) / Double(albums.count - 1) : 0
        scrubber.isEnabled = albums.count > 1
    }
    override func draw(_ dirtyRect: NSRect) {
        if grid { drawGrid(); return }
        fill(bounds, .black)
        guard albums.indices.contains(selected) else {
            text("Добавьте музыку в медиатеку", NSRect(x: 20, y: bounds.midY - 10, width: bounds.width - 40, height: 24), size: 13, ink: color(0x96999E), alignment: .center); return
        }
    }
    private func updateLabels() {
        let valid = albums.indices.contains(selected)
        albumLabel.isHidden = grid || !valid || !showsFlowLabels; artistLabel.isHidden = grid || !valid || !showsFlowLabels
        if valid { albumLabel.stringValue = albums[selected].isVideo ? albums[selected].title : albums[selected].album; artistLabel.stringValue = albums[selected].albumDisplayArtist }
    }
    private func drawGrid() {
        fill(bounds, .white)
        let columns = gridColumns, cell = bounds.width / CGFloat(gridColumns), expandedRow = expandedIndex.map { $0 / gridColumns }
        let viewport = visibleRect.insetBy(dx: 0, dy: -64)
        for (i, group) in gridGroups.enumerated() {
            let row = i / columns
            let y = CGFloat(row) * (tileSize + 58) + 24 + ((expandedRow.map { row > $0 } ?? false) ? drawerExpansion : 0)
            let r = NSRect(x: CGFloat(i % columns) * cell + (cell - tileSize) / 2, y: y, width: tileSize, height: tileSize)
            guard r.intersects(viewport) else { continue }
            guard let first = group.tracks.first else { continue }
            let previewIndex = scrubbedGroup == i ? scrubbedTrack : nil
            let track = previewIndex.flatMap { group.tracks.indices.contains($0) ? group.tracks[$0] : nil } ?? first
            let x = r.minX
            if selected == i {
                let frame = r.insetBy(dx: -5, dy: -5)
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow(); glow.shadowColor = color(0x328EE6, 0.45); glow.shadowBlurRadius = 4; glow.shadowOffset = .zero; glow.set()
                color(0x328EE6).setFill(); NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3).fill(); NSGraphicsContext.restoreGraphicsState()
                metallicGradient(frame, top: color(0x73C1FF), bottom: color(0x247ACB), radius: 3)
                stroke(frame, color(0x2C7DBD), radius: 3); stroke(frame.insetBy(dx: 1, dy: 1), color(0xFFFFFF, 0.35), radius: 2)
            }
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = color(0x000000, 0.35); shadow.shadowBlurRadius = 6; shadow.shadowOffset = NSSize(width: 0, height: -3); shadow.set()
            color(0x161616).setFill(); NSBezierPath(rect: r).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: r).addClip()
            if gridGrouping == .genres, let artwork = LegacyAssets.genre(group.title) {
                artwork.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            } else if gridGrouping == .genres {
                let palettes: [(UInt32, UInt32)] = [(0x368DC9, 0x113C70), (0xB67C38, 0x5D351E), (0x80A345, 0x294420), (0xAB547B, 0x502747), (0x7B72B0, 0x36304E)]
                let index = abs(group.title.utf8.reduce(0) { ($0 &* 31) &+ Int($1) } % palettes.count)
                gradient(r, palettes[index].0, palettes[index].1)
                text("♫", NSRect(x: x, y: y + tileSize * 0.08, width: tileSize, height: tileSize * 0.66), size: tileSize * 0.58, ink: color(0xFFFFFF, 0.8), alignment: .center)
                text(group.title.uppercased(), NSRect(x: x + 7, y: y + tileSize * 0.75, width: tileSize - 14, height: 20), size: 11, ink: .white, bold: true, alignment: .center)
            } else if previewIndex != nil {
                if scrubArtworkID != track.id {
                    scrubArtworkID = track.id; scrubArtwork = Covers.image(track)
                }
                (scrubArtwork ?? Covers.image(first)).draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            } else { Covers.draw(track, in: r) }
            if let previewIndex {
                let strip = NSRect(x: r.minX, y: r.maxY - 17, width: r.width, height: 17)
                fill(strip, color(0x000000, 0.62))
                text("\(previewIndex + 1) / \(group.tracks.count)", strip.insetBy(dx: 5, dy: 2), size: 9, ink: .white, alignment: .right)
                fill(NSRect(x: r.minX, y: r.maxY - 2, width: r.width * CGFloat(previewIndex + 1) / CGFloat(group.tracks.count), height: 2), color(0xC7D9EC, 0.85))
            }
            NSGraphicsContext.restoreGraphicsState()
            text(previewIndex == nil ? group.title : track.title, NSRect(x: x - 19, y: y + tileSize + 9, width: tileSize + 38, height: 18), size: 11, ink: color(0x111111), bold: true, alignment: .center)
            text(previewIndex == nil ? group.subtitle : track.artist, NSRect(x: x - 22, y: y + tileSize + 24, width: tileSize + 44, height: 17), size: 10, ink: color(0x6E6E6E), alignment: .center)
        }
    }
    func gridIndex(at point: NSPoint) -> Int? {
        var y = point.y
        if expandedKey != nil && y >= insertionY { if y < insertionY + drawerExpansion { return nil }; y -= drawerExpansion }
        let cell = bounds.width / CGFloat(gridColumns)
        let col = Int(floor(point.x / cell)); let row = Int(floor((y - 15) / (tileSize + 58)))
        let index = row * gridColumns + col
        guard col >= 0, col < gridColumns, row >= 0, gridGroups.indices.contains(index) else { return nil }
        let r = tileRect(at: index)
        return NSRect(x: r.minX - 9, y: r.minY - 9, width: tileSize + 18, height: tileSize + 56).contains(point) ? index : nil
    }
    override func rightMouseDown(with event: NSEvent) {
        guard grid, let index = gridIndex(at: convert(event.locationInWindow, from: nil)), gridGroups.indices.contains(index) else { return }
        selected = index; needsDisplay = true
        ClassicActionMenu.show(albumActions(at: index), from: self, at: convert(event.locationInWindow, from: nil))
    }
    func albumActions(at index: Int) -> [(String, () -> Void)] {
        guard gridGroups.indices.contains(index) else { return [] }
        let group = gridGroups[index]
        var actions: [(String, () -> Void)] = [
            ("Показать композиции", { [weak self] in self?.openGridGroup() })
        ]
        if gridGrouping == .albums, let first = group.tracks.first {
            let ordered = group.tracks.sorted { ($0.discNumber ?? 1, $0.number) < ($1.discNumber ?? 1, $1.number) }
            actions += [
                ("Воспроизвести альбом", { [weak self] in if let track = ordered.first { self?.onPlayTracks?(track, ordered) } }),
                ("Перемешать альбом", { [weak self] in let tracks = ordered.shuffled(); if let track = tracks.first { self?.onPlayTracks?(track, tracks) } }),
                ("Воспроизвести следующим", { [weak self] in self?.drawer.onQueue?(ordered, true) }),
                ("Добавить в очередь позже", { [weak self] in self?.drawer.onQueue?(ordered, false) }),
                ("Информация об альбоме…", { [weak self] in self?.onEditAlbum?(first) }),
                ("Показать в Finder", { [weak self] in self?.drawer.onRevealAlbum?(ordered) }),
                ("", {}),
                ("Удалить альбом…", { [weak self] in self?.drawer.onRemove?(ordered,true) })
            ]
        }
        return actions
    }
    @objc private func openGridGroup() { if gridGroups.indices.contains(selected) { if gridGrouping == .albums && gridGroups[selected].tracks.first?.isVideo != true { toggleDrawer(at: selected) } else { onOpenGroup?(gridGroups[selected]) } } }
    @objc private func editGridAlbum() { if gridGroups.indices.contains(selected), let track = gridGroups[selected].tracks.first { onEditAlbum?(track) } }
    func choose(_ index: Int) {
        guard !albums.isEmpty else { return }
        let target = min(albums.count - 1, max(0, index)); scrollState.reset(to: Double(target))
        if grid { selected = target; onSelect?(albums[target]) } else { animateFlow(to: CGFloat(target)) }
    }
    func step(_ direction: Int) { choose(Int(flowTarget.rounded()) + direction) }
    func flowIndex(at point: NSPoint) -> Int? {
        // Test the projected quadrilateral in scene coordinates. Inverse conversion
        // from z=0 is ambiguous now that compositing depth is separate from perspective.
        let order = coverLayers.keys.sorted {
            let a = abs(CGFloat($0) - flowPosition); let b = abs(CGFloat($1) - flowPosition)
            return a == b ? $0 < $1 : a < b
        }
        for index in order {
            guard let model = coverLayers[index] else { continue }
            let group = model.presentation() ?? model
            guard group.opacity > 0, let face = group.sublayers?.first else { continue }
            let r = face.bounds
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            let projected = corners.map { face.convert($0, to: scene.layer?.presentation() ?? scene.layer) }
            let polygon = CGMutablePath(); polygon.addLines(between: projected); polygon.closeSubpath()
            if polygon.contains(point) { return index }
        }
        return nil
    }
    private func clickCover(_ point: NSPoint, clicks: Int) {
        window?.makeFirstResponder(self)
        if let index = flowIndex(at: point) { choose(index); if clicks == 2 { onPlay?(albums[index]) } }
    }
    override func mouseDown(with event: NSEvent) {
        guard grid else { return }
        window?.makeFirstResponder(self)
        if let index = gridIndex(at: convert(event.locationInWindow, from: nil)) {
            selected = index; needsDisplay = true
            if gridGrouping == .albums, gridGroups[index].tracks.first?.isVideo != true {
                toggleDrawer(at: index)
            } else if event.clickCount == 2, gridGroups.indices.contains(index) { onOpenGroup?(gridGroups[index]) }
        }
    }
    override func scrollWheel(with event: NSEvent) {
        if grid { clearScrub(); super.scrollWheel(with: event); return }
        guard !albums.isEmpty else { return }
        flowSettleWork?.cancel(); flowSettleWork = nil
        let target = scrollState.update(x: event.scrollingDeltaX, y: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas, phase: event.phase, momentum: event.momentumPhase, timestamp: event.timestamp, presented: Double(flowPosition), count: albums.count)
        let continuous = event.hasPreciseScrollingDeltas && !scrollState.finishing
        animateFlow(to:CGFloat(target),tracking:continuous)
        // Only devices without gesture phases need an inactivity fallback. Trackpads finish on finger-up.
        if continuous && event.phase.isEmpty && event.momentumPhase.isEmpty {
            let work=DispatchWorkItem { [weak self] in
                guard let self, !self.grid else { return }
                let target=self.scrollState.finish(at:CACurrentMediaTime(),count:self.albums.count)
                self.animateFlow(to:CGFloat(target))
            }
            flowSettleWork=work; DispatchQueue.main.asyncAfter(deadline:.now()+0.06,execute:work)
        }
    }

    override func keyDown(with event: NSEvent) {
        if grid {
            if event.keyCode == 53 { closeDrawer(); return }
            if event.keyCode == 36 { openGridGroup(); return }
            let moves: [UInt16: Int] = [123: -1, 124: 1, 125: gridColumns, 126: -gridColumns]
            if let move = moves[event.keyCode], !gridGroups.isEmpty {
                selected = min(gridGroups.count - 1, max(0, selected + move)); needsDisplay = true; scrollToVisible(tileRect(at: selected).insetBy(dx: -10, dy: -10)); return
            }
        }
        if event.keyCode == 123 { step(-1) }
        else if event.keyCode == 124 { step(1) }
        else if event.keyCode == 36, albums.indices.contains(selected) { onPlay?(albums[selected]) }
        else { super.keyDown(with: event) }
    }
}

final class FlowScrubber: NSControl {
    var value: Double = 0 { didSet { needsDisplay = true } }
    var onChange: ((Double) -> Void)?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); setAccessibilityRole(.slider); setAccessibilityLabel("Пролистывание альбомов")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 1, y: 3, width: bounds.width - 2, height: 9)
        gradient(track, 0x070707, 0x353535, radius: 5); stroke(track, color(0x686868), radius: 5)
        let width: CGFloat = min(76, max(28, bounds.width * 0.16))
        let thumb = NSRect(x: 2 + CGFloat(value) * max(0, bounds.width - width - 4), y: 4, width: width, height: 7)
        gradient(thumb, isEnabled ? 0xB5B5B5 : 0x565656, 0x575757, radius: 4); stroke(thumb, color(0xD9D9D9, 0.45), radius: 4)
    }
    override func mouseDown(with event: NSEvent) { update(event) }
    override func mouseDragged(with event: NSEvent) { update(event) }
    private func update(_ event: NSEvent) {
        guard isEnabled else { return }
        value = min(1, max(0, Double(convert(event.locationInWindow, from: nil).x / max(1, bounds.width))))
        onChange?(value)
    }
}

@MainActor final class PlayerView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    override var isFlipped: Bool { true }
    let library: Library
    let sortDefaults: UserDefaults
    var sorting: LibrarySortSettings
    let videoView = AVPlayerView()
    lazy var videoControls = InlineVideoControls(library: library)
    var showingVideo = false
    private var presentedVideoID: String?
    let table = LibraryTrackTable()
    let tableScroll = NSScrollView()
    let albumScroll = NSScrollView()
    let stage = AlbumStage()
    let flowDetail = AlbumDrawer(frame: .zero)
    let flowDetailScroll = NSScrollView()
    lazy var lyricsPane = LyricsPane(library: library)
    var showsLyrics = false
    var lyricsTrack: Track? {
        if let current = library.current { return current }
        if let selected = focusedDrawer?.selectedTracks.first ?? selectedTableTracks.first { return selected }
        if mode == 3, stage.gridGroups.indices.contains(stage.selected) { return stage.gridGroups[stage.selected].tracks.first }
        if mode == 2, stage.albums.indices.contains(stage.selected) { return stage.albums[stage.selected] }
        return nil
    }
    func toggleLyrics() { showsLyrics.toggle(); if showsLyrics { lyricsPane.update(lyricsTrack) }; needsLayout = true; layoutSubtreeIfNeeded() }
    let search = CenteredSearchField()
    let progress = AquaSlider()
    let volume = AquaSlider()
    let queueButton = QueueLCDButton()
    var queuePopover: QueuePopover?
    var playButton: RetroButton!
    var shuffleButton: RetroButton!
    var repeatButton: RetroButton!
    let viewPicker = ViewModePicker()
    var buttons: [String: RetroButton] = [:]
    private var libraryStats = "0 песен · 0 альбомов · 0 мин"
    var rows: [Track] = [] { didSet { libraryStats = Self.librarySummary(rows, videos: source == "Видеоклипы") } }
    static func librarySummary(_ tracks: [Track], videos: Bool = false) -> String {
        let minutes = Int(tracks.reduce(0) { $0 + $1.duration } / 60)
        if videos { return "\(tracks.count) видео · \(minutes) мин" }
        let albums = Set(tracks.map(\.albumKey)).count
        return AlbumSummary.inflect(tracks.count, "песня", "песни", "песен") + " · " + AlbumSummary.inflect(albums, "альбом", "альбома", "альбомов") + " · \(minutes) мин"
    }
    var mode = 3
    var gridGrouping: GridGrouping = .albums
    var groupFilter: Set<String>?
    var groupTitle: String?
    var groupingButtons: [RetroButton] = []
    static let gridScaleKey = "GridArtworkScale"
    let sidebarWidth: CGFloat = 196
    let coverSize = AquaSlider()
    var editor: MetadataEditor?
    var source = "Музыка"
    var query = ""
    var albumFilter: String?
    var showSidebarArtwork = true
    var mini = false
    var spectrum = false
    var importing = false
    var notice = "Локальная медиатека"
    private var cachedRevision = -1
    private var cachedSource = ""
    private var cachedQuery = ""
    private var cachedFilter: Set<String>?
    private var cachedSort = LibrarySortSettings()
    private var cachedVisible: [Track] = []
    private var cachedGroups: [GridGrouping: [LibraryGroup]] = [:]
    private var artworkObserver: NSObjectProtocol?
    var timer: Timer?
    var onMini: (() -> Void)?
    var onClose: (() -> Void)?
    var sourceRects: [(NSRect, String)] = []
    var active: Bool { NSApp.isActive && (window?.isKeyWindow == true || ClassicPopup.active?.anchor?.window === window) }
    var sidebarArtworkRect: NSRect {
        let side = sidebarWidth - 0.5
        return NSRect(x: 0, y: bounds.height - 24 - side, width: side, height: side)
    }
    var lcdMetrics: LCDMetrics { LCDMetrics(rect: lcdRect, mini: mini, total: library.hasPlayback ? library.playbackDuration : displayedMiniTrack?.duration ?? 0) }
    func setGridScale(_ value: Double) {
        let scale = value.isFinite ? min(1, max(0, value)) : 0.4
        coverSize.value = scale; stage.tileSize = 104 + 60 * scale
        sortDefaults.set(scale, forKey: Self.gridScaleKey); needsLayout = true
    }
    var titleRect: NSRect { NSRect(x: 80, y: 2, width: bounds.width - 160, height: 16) }
    var lcdRect: NSRect {
        if mini { return NSRect(x: 128, y: 8, width: bounds.width - 137, height: 46) }
        // Balance the left/right reserves so title, LCD and logo share the window axis.
        let inset = max(294, (bounds.width * 0.248).rounded(.up))
        return NSRect(x: inset, y: titleRect.maxY + 2, width: bounds.width - 2 * inset, height: 40)
    }
    var trafficArea: NSRect { mini ? NSRect(x: 3, y: 5, width: 19, height: 53) : NSRect(x: 8, y: 2, width: 68, height: 23) }
    var displayedMiniTrack: Track? {
        if let current = library.current { return current }
        if mode == 3, stage.gridGroups.indices.contains(stage.selected) { return stage.gridGroups[stage.selected].tracks.first }
        return rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : rows.first
    }

    private var trafficTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trafficTracking { removeTrackingArea(trafficTracking) }
        let area = NSTrackingArea(rect: trafficArea, options: [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag], owner: self)
        addTrackingArea(area); trafficTracking = area
    }
    override func mouseEntered(with event: NSEvent) { if event.trackingArea === trafficTracking { refreshTrafficHover() } }
    override func mouseExited(with event: NSEvent) { if event.trackingArea === trafficTracking { setTrafficHovered(false) } }
    func setTrafficHovered(_ hovered: Bool) {
        for key in ["close", "minimize", "zoom"] { if let button = buttons[key], button.showTrafficGlyphs != hovered { button.showTrafficGlyphs = hovered } }
    }

    static func trafficHovered(at point: NSPoint, area: NSRect, active: Bool) -> Bool { active && area.contains(point) }
    func refreshTrafficHover() {
        if CommandLine.arguments.contains("--snapshot") && CommandLine.arguments.contains("--hover") { setTrafficHovered(true); return }
        guard let window else { setTrafficHovered(false); return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        setTrafficHovered(Self.trafficHovered(at: point, area: trafficArea, active: NSApp.isActive && window.isKeyWindow && !window.isMiniaturized))
    }

    init(library: Library, sortDefaults: UserDefaults = .standard) {
        self.sortDefaults = sortDefaults; sorting = LibrarySortSettings.load(sortDefaults)
        self.library = library; super.init(frame: NSRect(x: 0, y: 0, width: 1160, height: 760))
        wantsLayer = true
        let initialContent = NSRect(x: sidebarWidth, y: 88, width: bounds.width - sidebarWidth, height: bounds.height - 112)
        for scroll in [albumScroll, tableScroll, flowDetailScroll] { scroll.frame = initialContent }
        flowDetail.frame = NSRect(origin: .zero, size: initialContent.size)
        registerForDraggedTypes([.fileURL])
        videoView.controlsStyle = .none; videoView.showsFullScreenToggleButton = true
        videoView.videoGravity = .resizeAspect; videoView.wantsLayer = true; videoView.layer?.backgroundColor = NSColor.black.cgColor
        addSubview(videoView); addSubview(videoControls)
        videoControls.onFullScreen = { [weak self] in self?.window?.toggleFullScreen(nil) }
        configureControls(); configureTable(); stage.grid = mode == 3
        addSubview(lyricsPane); lyricsPane.isHidden = true; lyricsPane.onEdit = { [weak self] track in self?.presentEditor([track],album:false) }
        queueButton.onPress = { [weak self] in
            guard let self else { return }
            if self.queuePopover?.isOpen == true { self.queuePopover?.close(); return }
            let popover = QueuePopover(library: self.library, anchor: self.queueButton)
            popover.onClose = { [weak self] in self?.queueButton.opened = false; self?.queuePopover = nil }
            self.queuePopover = popover; popover.show(); self.queueButton.opened = true
        }
        addSubview(queueButton)
        flowDetail.standalone = true
        flowDetail.onPlayTracks = { [weak self] track, queue in self?.library.play(track, within: queue) }
        for drawer in [flowDetail, stage.drawer] {
            drawer.onRevealAlbum = { [weak self] tracks in guard let self else { return }; NSWorkspace.shared.activateFileViewerSelecting(Self.finderURLs(self.albumMembers(tracks))) }
            drawer.onRemove = { [weak self] tracks,album in self?.confirmRemoval(tracks,album:album) }
            drawer.onEditTracks = { [weak self] tracks in self?.presentEditor(tracks, album: false) }
            drawer.playlistNames = { [weak self] in self?.library.playlists.keys.sorted() ?? [] }
            drawer.onAddToPlaylist = { [weak self] tracks, name in self?.addToPlaylist(tracks, name: name) }
        }
        flowDetail.onEditTrack = { [weak self] track in self?.presentEditor([track], album: false) }
        stage.drawer.onEditTrack = { [weak self] track in self?.presentEditor([track], album: false) }
        flowDetail.onQueue = { [weak self] tracks, next in self?.library.enqueue(tracks, next: next) }
        stage.drawer.onQueue = { [weak self] tracks, next in self?.library.enqueue(tracks, next: next) }
        flowDetail.onEdit = { [weak self] track in self?.editAlbum(track) }
        flowDetailScroll.documentView = flowDetail; flowDetailScroll.hasVerticalScroller = true; flowDetailScroll.autohidesScrollers = true
        flowDetailScroll.drawsBackground = false; flowDetailScroll.borderType = .noBorder; addSubview(flowDetailScroll)
        library.onChange = { [weak self] in self?.library.systemMedia?.update(); self?.refresh(); self?.queuePopover?.reload() }
        library.onQueueChange = { [weak self] in self?.queuePopover?.reload() }
        library.onPlaybackChange = { [weak self] in self?.library.systemMedia?.update(); self?.refreshPlayback() }
        artworkObserver = NotificationCenter.default.addObserver(forName: Covers.ready, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let key = note.object as? String else { return }
                self.stage.artworkDidLoad(key); self.needsDisplay = true
                self.queuePopover?.table.enumerateAvailableRowViews { row, _ in row.subviews.forEach { $0.needsDisplay = true } }
                if let first = self.flowDetail.orderedTracks.first, Covers.key(first) == key { self.flowDetail.refreshArtwork() }
                if let track = self.library.current, Covers.key(track) == key { self.library.systemMedia?.update() }
            }
        }
        library.onImportProgress = { [weak self] done, total in self?.notice = "Импорт: \(done) из \(total)…"; self?.needsDisplay = true }
        library.onError = { [weak self] message in self?.showError(message) }
        refresh()
        if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.showsLyrics { self.lyricsPane.update(self.lyricsTrack); self.lyricsPane.tick() }
                self.buttons["lyrics"]?.isEnabled = self.library.playing && self.library.current?.isVideo != true
                self.videoControls.refresh()
                self.refreshTrafficHover()
                self.library.enforcePlaybackRange()
                if let video = self.library.videoPlayer { self.volume.value = Double(video.volume) }
                let symbol = self.library.playing ? "Ⅱ" : "▶"
                if self.playButton.symbol != symbol { self.playButton.symbol = symbol; self.playButton.needsDisplay = true }
                if self.library.hasPlayback { self.progress.value = self.library.playbackDuration > 0 ? self.library.playbackTime / self.library.playbackDuration : 0 }
                self.needsDisplay = true
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    func addButton(_ key: String, _ symbol: String, _ label: String, round: Bool = false, action: @escaping () -> Void) -> RetroButton {
        let b = RetroButton(symbol, label: label, action: action); b.round = round; addSubview(b); buttons[key] = b; return b
    }
    func configureControls() {
        let closeVideo = addButton("close-video", "×", "Вернуться к видеоклипам") { [weak self] in self?.browseWhileVideoPlays() }
        let returnVideo=addButton("return-video", "Вернуться к клипу", "Вернуться к текущему клипу без перемотки") { [weak self] in self?.showCurrentVideo() }; returnVideo.fontSize=10
        closeVideo.round = true; closeVideo.dark = true
        let close = addButton("close", "", "Закрыть окно") { [weak self] in self?.window?.performClose(nil) }; close.traffic = 0xF4796C; close.trafficSymbol = .close
        let minimize = addButton("minimize", "", "Свернуть окно") { [weak self] in self?.window?.miniaturize(nil) }; minimize.traffic = 0xF3CA57; minimize.trafficSymbol = .minimize
        let zoom = addButton("zoom", "", "Мини-плеер") { [weak self] in self?.onMini?() }; zoom.traffic = 0x79C568; zoom.trafficSymbol = .zoom
        _ = addButton("previous", "◀◀", "Предыдущий трек", round: true) { [weak self] in self?.library.step(-1) }
        playButton = addButton("play", "▶", "Воспроизведение / пауза (пробел)", round: true) { [weak self] in self?.toggle() }
        _ = addButton("next", "▶▶", "Следующий трек", round: true) { [weak self] in self?.library.step(1) }
        _ = addButton("lcd", "▸", "Информация / уровень сигнала") { [weak self] in self?.spectrum.toggle(); self?.needsDisplay = true }
        viewPicker.onChange = { [weak self] index in self?.setMode([0, 3, 2][index]) }
        addSubview(viewPicker)
        let reveal = addButton("lcd-reveal", "↪", "Показать композицию в медиатеке") { [weak self] in
            guard let self else { return }; if self.mini { self.onMini?() }; self.revealCurrent()
        }
        reveal.lcdControl = true; buttons["lcd"]?.lcdControl = true
        shuffleButton = addButton("shuffle", "⤨", "Перемешать") { [weak self] in guard let self else { return }; self.library.shuffle.toggle(); self.refresh() }
        repeatButton = addButton("repeat", "↻", "Повтор: выключен / очередь / трек") { [weak self] in guard let self else { return }; self.library.repeatMode = (self.library.repeatMode + 1) % 3; self.refresh() }
        _ = addButton("playlist", "+", "Создать плейлист") { [weak self] in self?.createPlaylist() }
        let artworkButton = addButton("artwork", "▧", "Показать / скрыть обложку") { [weak self] in
            guard let self else { return }; self.showSidebarArtwork.toggle(); self.buttons["artwork"]?.selected = self.showSidebarArtwork; self.needsLayout = true; self.needsDisplay = true
        }
        let artworkHeader = addButton("artwork-header", "Выбранный объект", "Свернуть / развернуть обложку") { [weak self] in
            guard let self else { return }; self.showSidebarArtwork.toggle(); self.buttons["artwork"]?.selected = self.showSidebarArtwork; self.needsLayout = true; self.needsDisplay = true
        }
        artworkHeader.paneHeader = true; artworkHeader.fontSize = 9
        artworkButton.selected = true
        for (index, key) in ["playlist", "shuffle", "repeat", "artwork"].enumerated() { buttons[key]?.statusControl = true; buttons[key]?.segmentIndex = index }
        volume.flankingIcons = .speakers; volume.value = Double(library.volume); volume.onChange = { [weak self] in self?.library.volume = Float($0) }; volume.setAccessibilityLabel("Громкость"); addSubview(volume)
        progress.diamond = true; progress.value = 0; progress.onChange = { [weak self] value in guard let self else { return }; self.library.seek(to: value * self.library.playbackDuration) }; progress.setAccessibilityLabel("Позиция воспроизведения"); addSubview(progress)
        search.cell = CenteredSearchCell(textCell: ""); search.controlSize = .small; search.isEditable = true; search.isSelectable = true; search.isBezeled = true; search.drawsBackground = true; search.backgroundColor = .white
        search.placeholderString = "Поиск в медиатеке"; search.font = font(11); search.delegate = self; search.focusRingType = .none; search.sendsSearchStringImmediately = true; addSubview(search)
        _ = addButton("lyrics", "≡", "Показать / скрыть текст песни (⌘Y)") { [weak self] in self?.toggleLyrics() }
        _ = addButton("info", "i", "Информация (⌘I)") { [weak self] in self?.editSelection() }
        _ = addButton("back", "‹ Все", "Вернуться к сетке") { [weak self] in self?.groupFilter = nil; self?.groupTitle = nil; self?.setMode(3) }
        for kind in GridGrouping.allCases {
            let button = addButton("group-" + kind.rawValue, kind.rawValue, kind.rawValue) { [weak self] in self?.gridGrouping = kind; self?.groupFilter = nil; self?.groupTitle = nil; self?.stage.selected = 0; self?.refresh() }
            button.scopeTab = true; button.fontSize = 10; groupingButtons.append(button)
        }
        let storedScale = (sortDefaults.object(forKey: Self.gridScaleKey) as? NSNumber)?.doubleValue ?? 0.4
        let scale = storedScale.isFinite ? min(1, max(0, storedScale)) : 0.4
        coverSize.flankingIcons = .squares; coverSize.value = scale; stage.tileSize = 104 + 60 * scale
        coverSize.onChange = { [weak self] value in self?.setGridScale(value) }; coverSize.setAccessibilityLabel("Размер обложек"); addSubview(coverSize)
        stage.onOpenGroup = { [weak self] group in
            guard let self else { return }
            if let clip = group.tracks.first, clip.isVideo { self.library.play(clip, within: self.filtered()); return }
            self.groupFilter = Set(group.tracks.map(\.id)); self.groupTitle = group.title
            if self.gridGrouping == .albums, let track = group.tracks.first { self.albumFilter = track.albumKey; self.setMode(1) } else { self.setMode(0) }
        }
        stage.onEditAlbum = { [weak self] track in self?.editAlbum(track) }
        stage.onPlayTracks = { [weak self] track, queue in self?.library.play(track, within: queue) }
        stage.onSelect = { [weak self] track in
            guard let self else { return }
            if self.mode == 3 { self.selectAlbum(track); self.needsDisplay = true }
            else { self.selectAlbum(track); self.needsDisplay = true }
        }
        stage.onPlay = { [weak self] track in guard let self else { return }; if self.mode == 2, self.flowDetail.orderedTracks.first?.albumKey == track.albumKey { self.flowDetail.playAlbum(); return }; let album = self.filtered().filter { $0.albumKey == track.albumKey }; self.library.play(album.first ?? track, within: album) }
        albumScroll.documentView = stage; albumScroll.hasVerticalScroller = true; albumScroll.autohidesScrollers = true; albumScroll.borderType = .noBorder; addSubview(albumScroll)
    }
    func configureTable() {
        let specs: [(String, String, CGFloat)] = [("state", "", 36), ("title", "Название", 260), ("duration", "Время", 62), ("artist", "Исполнитель", 175), ("album", "Альбом", 170), ("genre", "Жанр", 95)]
        for (key, label, width) in specs {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key)); column.title = label; column.width = width; column.minWidth = key == "state" ? 36 : 48
            column.headerCell = LegacyHeader(textCell: label)
            if key != "state" { column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true) }
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 20; table.style = .plain; table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = false; table.backgroundColor = .white
        table.selectionHighlightStyle = .regular; table.allowsMultipleSelection = true
        table.target = self; table.doubleAction = #selector(playClickedTrack)
        table.headerView?.frame.size.height = 21
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.onContext = { [weak self] row, point in guard let self else { return }; self.showTrackContext(row: row, at: point) }
        tableScroll.documentView = table; tableScroll.hasVerticalScroller = true; tableScroll.hasHorizontalScroller = true; tableScroll.autohidesScrollers = true; tableScroll.borderType = .noBorder
        addSubview(tableScroll)
    }
    override func layout() {
        super.layout(); let w = bounds.width; let h = bounds.height
        for key in ["close", "minimize", "zoom", "previous", "play", "next"] { buttons[key]?.isHidden = false }
        let centerY = lcdRect.midY
        for (i, key) in ["close", "minimize", "zoom"].enumerated() {
            buttons[key]?.frame = mini ? NSRect(x: 4, y: 7 + CGFloat(i) * 16, width: 16, height: 16) : NSRect(x: 10 + CGFloat(i) * 22, y: 3, width: 20, height: 20)
            buttons[key]?.trafficMonochrome = mini
            buttons[key]?.trafficMini = mini
        }
        buttons["previous"]?.frame = mini ? NSRect(x: 27, y: 11, width: 27, height: 27) : NSRect(x: 22, y: centerY - 13, width: 26, height: 26)
        playButton.frame = mini ? NSRect(x: 57, y: 9, width: 31, height: 31) : NSRect(x: 53, y: centerY - 16, width: 32, height: 32)
        buttons["next"]?.frame = mini ? NSRect(x: 91, y: 11, width: 27, height: 27) : NSRect(x: 90, y: centerY - 13, width: 26, height: 26)
        volume.frame = mini ? NSRect(x: 37, y: 43, width: 66, height: 13) : NSRect(x: 146, y: centerY - 11, width: 128, height: 22)
        volume.compact = mini
        let lcd = lcdRect
        queueButton.isHidden = mini
        queueButton.frame = NSRect(x: lcd.maxX - 27, y: lcd.midY - 12, width: 24, height: 24)
        progress.isHidden = library.current == nil && !mini
        buttons["lcd"]?.isHidden = library.current == nil && !mini
        buttons["lcd"]?.frame = NSRect(x: lcd.minX + 5, y: lcd.minY + (mini ? 15 : 14), width: 13, height: 13)
        buttons["lcd-reveal"]?.frame = NSRect(x: lcd.maxX - 19, y: lcd.minY + 15, width: 13, height: 13)
        progress.frame = lcdMetrics.progress
        search.frame = NSRect(x: w - 188, y: centerY - 11, width: 168, height: 22)
        viewPicker.frame = NSRect(x: w - 280, y: centerY - 11, width: 75, height: 22)
        for (i, button) in groupingButtons.enumerated() { button.frame = NSRect(x: sidebarWidth + max(12, (w - sidebarWidth - 320) / 2) + CGFloat(i) * 80, y: 67, width: 80, height: 20) }
        buttons["lyrics"]?.frame = NSRect(x: w - 54, y: 68, width: 20, height: 18)
        buttons["info"]?.frame = NSRect(x: w - 28, y: 68, width: 20, height: 18)
        buttons["back"]?.frame = NSRect(x: 170, y: 68, width: 85, height: 18)
        coverSize.frame = NSRect(x: w - 180, y: 67, width: 108, height: 20)
        buttons["import"]?.frame = NSRect(x: w - 28, y: 68, width: 20, height: 18)
        buttons["playlist"]?.frame = NSRect(x: 10, y: h - 23, width: 30, height: 22)
        shuffleButton.frame = NSRect(x: 40, y: h - 23, width: 30, height: 22)
        repeatButton.frame = NSRect(x: 70, y: h - 23, width: 30, height: 22)
        buttons["artwork"]?.frame = NSRect(x: 100, y: h - 23, width: 30, height: 22)
        buttons["return-video"]?.frame = NSRect(x:w-138,y:h-23,width:130,height:22)
        buttons["import-library"]?.frame = NSRect(x: 10, y: 163, width: sidebarWidth - 20, height: 21)
        buttons["artwork-header"]?.frame = NSRect(x: 0, y: showSidebarArtwork ? sidebarArtworkRect.minY - 20 : h - 44, width: sidebarWidth - 0.5, height: 20)
        buttons["artwork-header"]?.symbol = library.current == nil ? "Выбранный объект" : "Сейчас играет"
        buttons["artwork-header"]?.selected = showSidebarArtwork
        buttons["artwork-header"]?.needsDisplay = true
        let left = sidebarWidth; let top: CGFloat = 88; let bottom: CGFloat = 24
        let lyricsWidth: CGFloat = showsLyrics && !mini && !showingVideo ? 292 : 0
        lyricsPane.isHidden = lyricsWidth == 0; lyricsPane.frame = NSRect(x:w-lyricsWidth,y:top,width:lyricsWidth,height:max(0,h-top-bottom))
        let content = NSRect(x: left, y: top, width: w - left - lyricsWidth, height: max(0, h - top - bottom))
        albumScroll.isHidden = mini || mode == 0 || mode == 1
        tableScroll.isHidden = mini || mode == 3 || mode == 2
        flowDetailScroll.isHidden = mini || mode != 2
        if mode == 2 {
            let stageHeight = min(340, max(180, content.height * 0.44))
            albumScroll.frame = NSRect(x: left, y: top, width: content.width, height: stageHeight)
            stage.frame = NSRect(origin: .zero, size: albumScroll.contentSize)
            flowDetailScroll.frame = NSRect(x: left, y: top + stageHeight, width: content.width, height: max(0, content.height - stageHeight))
            let width = flowDetailScroll.contentSize.width
            let height = max(flowDetailScroll.contentSize.height, flowDetail.preferredHeight(width: width))
            flowDetail.fullHeight = height; flowDetail.frame = NSRect(x: 0, y: 0, width: width, height: height); flowDetail.needsLayout = true
        } else if mode == 3 {
            albumScroll.frame = content
            let height = max(content.height, stage.gridContentHeight(width: albumScroll.contentSize.width))
            stage.frame = NSRect(x: 0, y: 0, width: albumScroll.contentSize.width, height: height)
        } else if mode == 1 { tableScroll.frame = NSRect(x: left + 192, y: top, width: content.width - 192, height: content.height) }
        else { tableScroll.frame = content }
        for (key, b) in buttons { if !["close", "minimize", "zoom", "previous", "play", "next", "lcd", "lcd-reveal"].contains(key) { b.isHidden = mini } }
        volume.isHidden = false; search.isHidden = mini; viewPicker.isHidden = mini
        buttons["lcd-reveal"]?.isHidden = !mini
        buttons["return-video"]?.isHidden = mini || showingVideo || library.current?.isVideo != true || library.videoPlayer == nil
        layer?.cornerRadius = mini ? 4 : 0; layer?.masksToBounds = mini
        for button in groupingButtons { button.isHidden = mini || mode != 3 || source == "Видеоклипы" }
        buttons["back"]?.isHidden = mini || groupFilter == nil
        coverSize.isHidden = mini || mode != 3
        buttons["lyrics"]?.isEnabled = library.playing && library.current?.isVideo != true
        buttons["lyrics"]?.selected = showsLyrics
        buttons["info"]?.isEnabled = mode != 3 || gridGrouping == .albums
        let fullScreenVideo = window?.styleMask.contains(.fullScreen) == true && showingVideo && library.videoPlayer != nil
        videoView.frame = fullScreenVideo ? bounds : NSRect(x: 0, y: 66, width: w, height: max(0, h - 90))
        videoView.isHidden = mini || !showingVideo || library.videoPlayer == nil
        videoControls.frame = NSRect(x: (w - min(345, w - 32)) / 2, y: h - (fullScreenVideo ? 86 : 90), width: min(345, w - 32), height: 46)
        videoControls.bounds.size = NSSize(width: 420, height: 56)
        videoControls.isHidden = videoView.isHidden
        videoControls.refresh()
        videoView.controlsStyle = .none
        buttons["close-video"]?.frame = NSRect(x: 8, y: 74, width: 24, height: 24)
        buttons["close-video"]?.isHidden = videoView.isHidden
        if !videoView.isHidden {
            albumScroll.isHidden = true; tableScroll.isHidden = true; flowDetailScroll.isHidden = true
            for key in ["info", "lyrics", "back", "import", "import-library", "artwork-header"] { buttons[key]?.isHidden = true }
            groupingButtons.forEach { $0.isHidden = true }; coverSize.isHidden = true
        }
        if fullScreenVideo { subviews.forEach { $0.isHidden = $0 !== videoView && $0 !== videoControls }; videoControls.isHidden = false }
        stage.needsDisplay = true; stage.needsLayout = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width; let h = bounds.height
        if window?.styleMask.contains(.fullScreen) == true && showingVideo && library.videoPlayer != nil { fill(bounds, .black); return }
        gradient(bounds, 0xE7E7E7, 0xC1C1C1)
        let chromeHeight: CGFloat = mini ? h : 66
        let highlightHeight: CGFloat = mini ? h / 2 : lcdRect.midY
        gradient(NSRect(x: 0, y: 0, width: w, height: highlightHeight), active ? 0xEFEFEF : 0xF6F6F6, active ? 0xDFDFDF : 0xEBEBEB)
        gradient(NSRect(x: 0, y: highlightHeight, width: w, height: chromeHeight - highlightHeight), active ? 0xD2D2D2 : 0xE9E9E9, active ? 0xBDBDBD : 0xDFDFDF)
        fill(NSRect(x: 0, y: 0, width: w, height: 1), color(0xFFFFFF, 0.8))
        if !mini {
            centeredGlyphText("iTunes", in: titleRect, size: 10, ink: color(0x3F3F3F))
        }
        if mini {
            drawSpeaker(NSRect(x: 26, y: 44, width: 8, height: 9), loud: false)
            drawSpeaker(NSRect(x: 105, y: 44, width: 15, height: 9), loud: true)
        }
        if mini {
            for i in 0..<3 {
                let p = NSBezierPath(); p.move(to: NSPoint(x: w - 4 - CGFloat(i) * 3, y: h - 3)); p.line(to: NSPoint(x: w - 3, y: h - 4 - CGFloat(i) * 3)); color(0x777777, 0.55).setStroke(); p.stroke()
            }
        }
        drawLCD()
        guard !mini else { return }
        gradient(NSRect(x: 0, y: 66, width: w, height: 22), 0xE4E4E4, 0xCFCFCF)
        fill(NSRect(x: 0, y: 65.5, width: w, height: 0.5), color(0x8E8E8E))
        fill(NSRect(x: 0, y: 66, width: w, height: 0.5), .white)
        fill(NSRect(x: 0, y: 87.5, width: w, height: 0.5), color(0xA5A5A5))
        if mode != 3 || source == "Видеоклипы" {
            engravedText(groupTitle ?? source, NSRect(x: sidebarWidth + (groupFilter == nil ? 12 : 106), y: 71, width: w - 400, height: 15), size: 10, ink: color(0x4A4A4A), bold: true)
        }
        drawSidebar()
        if mode == 1 {
            fill(NSRect(x: sidebarWidth, y: 88, width: 192, height: h - 112), color(0xEBEDF0))
            if let track = rows.first { Covers.draw(track, in: NSRect(x: sidebarWidth + 17, y: 154, width: 154, height: 154)); text(track.album, NSRect(x: sidebarWidth + 17, y: 321, width: 154, height: 36), size: 12, bold: true); text(track.albumDisplayArtist, NSRect(x: sidebarWidth + 17, y: 362, width: 154, height: 30), size: 11, ink: color(0x777777)) }
            fill(NSRect(x: sidebarWidth + 191, y: 88, width: 1, height: h - 112), color(0xB0B3B8))
        }
        if rows.isEmpty && mode != 2 {
            text(source == "Видеоклипы" ? "Видеоклипы появятся здесь" : "Музыка появится здесь", NSRect(x: 420, y: h / 2, width: w - 470, height: 25), size: 18, ink: color(0x7C8187), alignment: .center)
        }
        gradient(NSRect(x: 0, y: h - 24, width: w, height: 24), 0xE8E8E8, 0xCFCFCF)
        fill(NSRect(x: 0, y: h - 24, width: w, height: 0.5), color(0x999999)); fill(NSRect(x: 0, y: h - 23.5, width: w, height: 0.5), .white)
        for x: CGFloat in [40, 70, 100] {
            fill(NSRect(x: x, y: h - 20, width: 0.5, height: 16), color(0xB0B0B0))
        }
        let stats = libraryStats
        engravedText(importing || library.upgradingMetadata ? notice : stats, NSRect(x: 170, y: h - 18, width: w - 340, height: 14), size: 10, ink: color(0x4B4B4B), alignment: .center)
    }

    func drawLCD() {
        let r = lcdRect
        gradient(r, 0x555B50, 0xF4F5ED, radius: 4)
        gradient(r.insetBy(dx: 1, dy: 1), 0xEBF0D5, 0xD6DFB9, radius: 2)
        stroke(r, color(0x7C8272), radius: 4)
        fill(NSRect(x: r.minX + 1, y: r.minY + 1, width: r.width - 2, height: 0.5), color(0x59634C, 0.5))
        fill(NSRect(x: r.minX + 1, y: r.minY + 1, width: 0.5, height: r.height - 2), color(0x59634C, 0.35))
        fill(NSRect(x: r.maxX - 1.5, y: r.minY + 1, width: 0.5, height: r.height - 2), color(0x59634C, 0.35))
        fill(NSRect(x: r.minX + 2, y: r.maxY, width: r.width - 4, height: 0.5), color(0xFFFFFF, 0.85))
        if library.current == nil && !mini {
            centeredGlyphText("", in: r.insetBy(dx: 10, dy: 4), size: 25, ink: color(0x66714F))
            return
        }
        let shown = mini ? displayedMiniTrack : library.current
        let inner = NSRect(x: r.minX + 22, y: r.minY + 5, width: r.width - (mini ? 44 : 72), height: 26)
        let metrics = lcdMetrics
        if spectrum {
            library.player?.updateMeters()
            let db = library.player?.averagePower(forChannel: 0) ?? -100
            let strength = library.playing && db.isFinite ? min(1, max(0, (Double(db) + 55) / 55)) : 0
            let bars = metrics.spectrum
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: bars).addClip()
            for i in 0..<25 {
                let level = strength * (0.2 + 0.8 * abs(sin(Double(i) * 1.8 + (library.playbackTime) * 4)))
                let bh = CGFloat(level) * bars.height
                fill(NSRect(x: bars.minX + CGFloat(i) * (bars.width / 25), y: bars.maxY - bh, width: max(1, bars.width / 25 - 2), height: bh), color(0x657449))
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            text(shown?.title ?? "iTunes", NSRect(x: inner.minX, y: r.minY + 3, width: inner.width, height: mini ? 15 : 12), size: 10, ink: color(0x3F4832), bold: true, alignment: .center)
            text(shown.map { mini ? $0.artist : $0.artist + " — " + $0.album } ?? "Нет выбранной композиции", NSRect(x: inner.minX, y: r.minY + (mini ? 16 : 14), width: inner.width, height: mini ? 13 : 10), size: 9, ink: color(0x60694D), alignment: .center)
        }
        let elapsed = library.playbackTime; let duration = library.hasPlayback ? library.playbackDuration : shown?.duration ?? 0
        text(timeString(elapsed), metrics.elapsed, size: 9, ink: color(0x60694D))
        text(mini ? timeString(duration) : "−" + timeString(duration - elapsed), metrics.duration, size: 9, ink: color(0x60694D), alignment: .right)
    }
    func drawSidebar() {
        let h = bounds.height
        fill(NSRect(x: 0, y: 66, width: sidebarWidth, height: h - 90), active ? color(0xD1D7E2) : color(0xE5E5E5))
        fill(NSRect(x: sidebarWidth - 0.5, y: 66, width: 0.5, height: h - 90), color(0x9DA5B1))
        sourceRects = []
        func section(_ title: String, _ y: CGFloat) {
            engravedText(title, NSRect(x: 13, y: y, width: 140, height: 15), size: 10, ink: color(0x586375), bold: true)
        }
        func row(_ title: String, _ icon: String, _ y: CGFloat, _ c: UInt32) {
            let r = NSRect(x: 0, y: y, width: sidebarWidth - 0.5, height: 20)
            if source == title { gradient(r, active ? 0x6A9CD8 : 0xA1AABB, active ? 0x336DB9 : 0x8794A8); fill(NSRect(x: 0, y: y, width: sidebarWidth - 0.5, height: 0.5), color(0x4D7CB3)) }
            let asset = title == "Музыка" ? "music" : title == "Видеоклипы" ? "movies" : title == "Недавно добавленные" ? "smart-playlist" : "playlist"
            if let image = LegacyAssets.icon(asset) {
                image.draw(in: NSRect(x: 19, y: y + 2, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            } else {
                text(icon, NSRect(x: 18, y: y + 1, width: 22, height: 20), size: 17, ink: source == title ? .white : color(c), bold: true)
            }
            text(title, NSRect(x: 40, y: y + 3, width: sidebarWidth - 44, height: 18), size: 11, ink: source == title ? .white : color(0x26313F), bold: source == title)
            sourceRects.append((r, title))
        }
        section("МЕДИАТЕКА", 72)
        row("Музыка", "♫", 89, 0x2960B5)
        row("Видеоклипы", "▣", 110, 0x39759B)
        row("Недавно добавленные", "◷", 131, 0x65914D)
        section("ПЛЕЙЛИСТЫ", 174)
        var y: CGFloat = 194
        for name in library.playlists.keys.sorted() { row(name, "♫", y, 0x697FB8); y += 21 }
        if library.playlists.isEmpty { engravedText("Кнопка + создаст первый", NSRect(x: 12, y: 200, width: 140, height: 17), size: 10, ink: color(0x606B7D)) }
        if showSidebarArtwork {
            fill(sidebarArtworkRect, color(0xD1D7E2))
            let selectedTrack: Track?
            if mode == 3 && stage.gridGroups.indices.contains(stage.selected) { selectedTrack = stage.gridGroups[stage.selected].tracks.first }
            else if mode == 2 && stage.albums.indices.contains(stage.selected) { selectedTrack = stage.albums[stage.selected] }
            else { selectedTrack = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : rows.first }
            if let track = library.current ?? selectedTrack {
                Covers.draw(track, in: sidebarArtworkRect)
            }
        }
    }

    func filtered() -> [Track] {
        var result = source == "Видеоклипы" ? library.tracks.filter { $0.isVideo } : library.tracks.filter { !$0.isVideo }
        if source == "Недавно добавленные" {
            result=result.enumerated().sorted { a,b in
                let left=a.element.importedAt ?? .distantPast, right=b.element.importedAt ?? .distantPast
                if left != right { return left > right }
                return a.element.importedAt == nil ? a.offset > b.offset : a.offset < b.offset
            }.map(\.element)
        }
        else if let ids = library.playlists[source] { result = ids.compactMap { id in library.tracks.first { $0.id == id } } }
        if !query.isEmpty { result = result.filter { ($0.title + " " + $0.artist + " " + $0.album + " " + $0.genre + " " + ($0.composer ?? "")).localizedCaseInsensitiveContains(query) } }
        if let groupFilter { result = result.filter { groupFilter.contains($0.id) } }
        return result
    }
    private func prepareGroups() {
        if cachedRevision != library.contentRevision || cachedSource != source || cachedQuery != query || cachedFilter != groupFilter || cachedSort != sorting {
            cachedRevision = library.contentRevision; cachedSource = source; cachedQuery = query; cachedFilter = groupFilter; cachedSort = sorting
            cachedVisible = filtered(); cachedGroups.removeAll()
        }
    }
    private func groupsFor(_ kind: GridGrouping) -> [LibraryGroup] {
        if let groups = cachedGroups[kind] { return groups }
        let sortedGroups = sorting.groups(source == "Видеоклипы" ? cachedVisible.map { LibraryGroup(key: $0.id, title: $0.title, subtitle: $0.artist, tracks: [$0]) } : Self.groups(cachedVisible, by: kind), kind: source == "Видеоклипы" ? .albums : kind)
        let order=Dictionary(uniqueKeysWithValues:cachedVisible.enumerated().map { ($0.element.id,$0.offset) })
        let groups=source == "Недавно добавленные" ? sortedGroups.sorted { ($0.tracks.map { order[$0.id] ?? Int.max }.min() ?? Int.max) < ($1.tracks.map { order[$0.id] ?? Int.max }.min() ?? Int.max) } : sortedGroups
        cachedGroups[kind] = groups; return groups
    }
    deinit { if let artworkObserver { NotificationCenter.default.removeObserver(artworkObserver) } }
    private func updateFlowDetail() {
        guard mode == 2 else { return }
        guard stage.albums.indices.contains(stage.selected), let group = groupsFor(.albums).first(where: { $0.key == stage.albums[stage.selected].albumKey || $0.tracks.first?.id == stage.albums[stage.selected].id }) else { flowDetail.clear(); return }
        if flowDetail.group?.key != group.key || flowDetail.group?.tracks != group.tracks {
            flowDetail.configure(group); flowDetailScroll.contentView.scroll(to: .zero); flowDetailScroll.reflectScrolledClipView(flowDetailScroll.contentView)
            needsLayout = true
        }
        flowDetail.currentID = library.currentID; flowDetail.playing = library.playing
    }
    func refreshPlayback() {
        flowDetail.currentID = library.currentID; flowDetail.playing = library.playing
        stage.drawer.currentID = library.currentID; stage.drawer.playing = library.playing
        if let clip = library.current, clip.isVideo, library.videoPlayer != nil {
            if presentedVideoID != clip.id || videoView.player !== library.videoPlayer { showingVideo = true; presentedVideoID = clip.id; videoView.player = library.videoPlayer }
        } else { showingVideo = false; presentedVideoID = nil; videoView.player = nil }
        playButton.symbol = library.playing ? "Ⅱ" : "▶"; playButton.needsDisplay = true
        if mode != 2 && !rows.isEmpty { table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count), columnIndexes: IndexSet(integer: 0)) }
        needsLayout = true; needsDisplay = true
    }
    func refresh() {
        if let clip = library.current, clip.isVideo, library.videoPlayer != nil {
            if presentedVideoID != clip.id { presentedVideoID = clip.id; showingVideo = true }
            if videoView.player !== library.videoPlayer { showingVideo = true; videoView.player = library.videoPlayer }
        } else { showingVideo = false; presentedVideoID = nil; videoView.player = nil }
        if library.upgradingMetadata { notice = "Чтение метаданных: \(library.metadataProgress) из \(library.metadataTotal)…" }
        let previousGroup = mode == 3 && stage.gridGroups.indices.contains(stage.selected) ? stage.gridGroups[stage.selected].key : nil
        let previousAlbum = stage.albums.indices.contains(stage.selected) ? stage.albums[stage.selected].albumKey : nil
        let selectionIDs = Set(selectedTableTracks.map(\.id))
        stage.drawer.currentID = library.currentID; stage.drawer.playing = library.playing
        prepareGroups()
        let visible = cachedVisible
        stage.gridGrouping = gridGrouping
        stage.gridGroups = groupsFor(gridGrouping)
        for (i, button) in groupingButtons.enumerated() { button.selected = GridGrouping.allCases[i] == gridGrouping; button.needsDisplay = true }
        stage.albums = groupsFor(.albums).compactMap { $0.tracks.first }
        if mode != 3 { stage.selected = previousAlbum.flatMap { key in stage.albums.firstIndex { $0.albumKey == key } } ?? min(stage.selected, max(0, stage.albums.count - 1)) }
        if mode == 3 { stage.selected = previousGroup.flatMap { key in stage.gridGroups.firstIndex { $0.key == key } } ?? min(stage.selected, max(0, stage.gridGroups.count - 1)) }
        rows = visible.filter { mode != 1 || albumFilter == nil || $0.albumKey == albumFilter }
        if mode == 1, albumFilter == nil, let first = rows.first { albumFilter = first.albumKey; rows = rows.filter { $0.albumKey == first.albumKey } }
        if mode != 3 && mode != 2 { applySort(); table.reloadData() }
        table.selectRowIndexes(IndexSet(rows.indices.filter { selectionIDs.contains(rows[$0].id) }), byExtendingSelection: false)
        playButton.symbol = library.playing ? "Ⅱ" : "▶"; playButton.needsDisplay = true
        shuffleButton.selected = library.shuffle; repeatButton.selected = library.repeatMode != 0; repeatButton.symbol = library.repeatMode == 2 ? "↻¹" : "↻"
        if mode == 2 { updateFlowDetail() }
        viewPicker.selectedIndex = mode == 3 ? 1 : mode == 2 ? 2 : 0
        needsLayout = true; needsDisplay = true
    }
    func changeSort(primary: LibrarySortField? = nil, secondary: LibrarySortField? = nil, clearSecondary: Bool = false, ascending: Bool? = nil, yearAscending: Bool? = nil) {
        if let primary { sorting.primary = primary }
        if clearSecondary { sorting.secondary = nil } else if let secondary { sorting.secondary = secondary }
        if sorting.secondary == sorting.primary { sorting.secondary = nil }
        if let ascending { sorting.ascending = ascending }
        if let yearAscending { sorting.yearAscending = yearAscending }
        sorting.save(sortDefaults)
        table.sortDescriptors = []; refresh()
    }
    func setMode(_ value: Int) { stage.stopFlowMotion(); if value == 3 { groupFilter = nil; groupTitle = nil }; mode = value; stage.grid = mode == 3; refresh() }
    func selectAlbum(_ track: Track) {
        if mode == 2 { updateFlowDetail(); needsDisplay = true; return }
        if let i = rows.firstIndex(where: { $0.albumKey == track.albumKey }) { table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false); table.scrollRowToVisible(i) }
    }
    func toggle() {
        if mode == 2 && !library.hasPlayback { flowDetail.playAlbum(); return }
        if !library.hasPlayback, rows.indices.contains(table.selectedRow) { library.play(rows[table.selectedRow], within: rows, contextTitle: playbackContextTitle) }
        else { library.toggle(rows, contextTitle: playbackContextTitle) }
    }
    var playbackContextTitle: String? { library.playlists[source] == nil ? nil : "Из плейлиста «" + source + "»" }
    var selectedTableTracks: [Track] { table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil } }
    var focusedDrawer: AlbumDrawer? { [stage.drawer, flowDetail].first { window?.firstResponder === $0 && !$0.isHiddenOrHasHiddenAncestor } }
    func selectAllTracks() { if let drawer = focusedDrawer { drawer.selectAllTracks() } else if mode == 0 || mode == 1 { table.selectAll(nil) } }
    func routeSelectionKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.control) else { return false }
        if event.keyCode == 53, mode == 3, stage.expandedKey != nil { stage.closeDrawer(); window?.makeFirstResponder(stage); return true }
        if let drawer = focusedDrawer, [UInt16(36),53,123,124,125,126].contains(event.keyCode) { drawer.keyDown(with: event); return true }
        return false
    }
    @objc func playSelected() {
        if let drawer = focusedDrawer { drawer.playSelectedTracks(); return }
        if let track = selectedTableTracks.first { library.play(track, within: table.selectedRowIndexes.count > 1 ? selectedTableTracks : rows, contextTitle: playbackContextTitle) }
    }
    @objc func playClickedTrack() { if rows.indices.contains(table.clickedRow) { library.play(rows[table.clickedRow], within: rows, contextTitle: playbackContextTitle) } }
    func addToPlaylist(_ tracks: [Track], name: String) {
        guard library.playlists[name] != nil else { return }
        for track in tracks where !(library.playlists[name] ?? []).contains(track.id) { library.playlists[name, default: []].append(track.id) }
        library.save(); refresh()
    }
    func browseWhileVideoPlays() { showingVideo=false; source="Видеоклипы"; refresh() }
    @discardableResult func showCurrentVideo() -> Bool {
        guard let track=library.current, track.isVideo, let player=library.videoPlayer else { return false }
        showingVideo=true; presentedVideoID=track.id; videoView.player=player
        needsLayout=true; layoutSubtreeIfNeeded(); needsDisplay=true
        return true
    }
    func revealCurrent() {
        if showCurrentVideo() { return }
        source = "Музыка"; query = ""; search.stringValue = ""; albumFilter = nil; groupFilter = nil; groupTitle = nil; setMode(2)
        if let track = library.current, let index = stage.albums.firstIndex(where: { $0.albumKey == track.albumKey }) { stage.choose(index) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let key = tableColumn?.identifier.rawValue else { return nil }
        let track = rows[row]; let cell = NSTextField(labelWithString: ""); cell.font = font(11); cell.lineBreakMode = .byTruncatingTail
        switch key {
        case "state": cell.stringValue = library.currentID == track.id ? (library.playing ? "♫" : "Ⅱ") : String(row + 1); cell.alignment = .center; cell.textColor = color(0x66758B); cell.font = font(9)
        case "title": cell.stringValue = track.title
        case "duration": cell.stringValue = timeString(track.duration); cell.alignment = .right
        case "artist": cell.stringValue = track.artist
        case "album": cell.stringValue = track.album
        case "genre": cell.stringValue = track.genre
        default: break
        }
        let container = NSTableCellView(); container.textField = cell; container.addSubview(cell); cell.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([cell.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 7), cell.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7), cell.centerYAnchor.constraint(equalTo: container.centerYAnchor)])
        return container
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { let view = StripedRow(); view.alternate = row % 2 != 0; return view }
    func tableViewSelectionDidChange(_ notification: Notification) {
        needsDisplay = true
        if mode == 2, rows.indices.contains(table.selectedRow), let i = stage.albums.firstIndex(where: { $0.albumKey == rows[table.selectedRow].albumKey }) { stage.selected = i; stage.needsDisplay = true }
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        if mode != 3 {
            let selected = Set(selectedTableTracks.map(\.id)); applySort(); table.reloadData()
            table.selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0].id) }), byExtendingSelection: false)
        }
    }
    func applySort() {
        if source == "Недавно добавленные" { return }
        guard let sort = table.sortDescriptors.first, let key = sort.key else {
            if mode == 0 { rows.sort { sorting.compare($0, $1) } }
            else {
                let order = Dictionary(uniqueKeysWithValues: stage.albums.enumerated().map { ($0.element.albumKey, $0.offset) })
                rows.sort { a, b in
                    if a.albumKey != b.albumKey { return (order[a.albumKey] ?? 0) < (order[b.albumKey] ?? 0) }
                    if (a.discNumber ?? 1) != (b.discNumber ?? 1) { return (a.discNumber ?? 1) < (b.discNumber ?? 1) }
                    if a.number != b.number { return a.number < b.number }
                    let name = a.title.localizedStandardCompare(b.title); return name == .orderedSame ? a.id < b.id : name == .orderedAscending
                }
            }
            return
        }
        rows.sort { a, b in
            if key == "duration" { return sort.ascending ? a.duration < b.duration : a.duration > b.duration }
            func value(_ t: Track) -> String { switch key { case "artist": return t.sortArtist ?? t.artist; case "album": return t.sortAlbum ?? t.album; case "genre": return t.genre; default: return t.sortTitle ?? t.title } }
            let cmp = value(a).localizedStandardCompare(value(b)); return sort.ascending ? cmp == .orderedAscending : cmp == .orderedDescending
        }
    }
    func controlTextDidChange(_ obj: Notification) { query = search.stringValue; albumFilter = nil; refresh() }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let (_, name) = sourceRects.first(where: { $0.0.contains(p) }) { source = name; if name == "Видеоклипы" { gridGrouping = .albums }; showingVideo = false; albumFilter = nil; groupFilter = nil; groupTitle = nil; refresh() }
        else if !mini && showSidebarArtwork && sidebarArtworkRect.contains(p) && showCurrentVideo() { return }
        else if p.y < 66 { window?.performDrag(with: event) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        importMusic(urls); return true
    }
    func importLibrary() {
        guard !importing, let window else { return }
        let panel = NSOpenPanel(); panel.title = "Выберите папку медиатеки"; panel.prompt = "Добавить медиатеку"
        panel.message = "Музыка и клипы во всех вложенных папках будут добавлены автоматически. Исходные файлы останутся на месте."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] result in if result == .OK { self?.importMusic(panel.urls) } }
    }
    func importFiles() {
        guard !importing, let window else { return }
        let panel = NSOpenPanel(); panel.title = "Добавить музыку и видеоклипы"; panel.prompt = "Добавить"; panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] result in if result == .OK { self?.importMusic(panel.urls) } }
    }
    func importMusic(_ urls: [URL]) {
        guard !importing else { return }; importing = true; notice = "Чтение музыки и видеоклипов…"; needsDisplay = true
        Task {
            let (added, failed) = await library.importURLs(urls)
            importing = false; source = "Музыка"; albumFilter = nil
            groupFilter = nil; groupTitle = nil
            notice = "Добавлено: \(added)" + (failed > 0 ? " · не удалось прочитать: \(failed)" : " · файлы остаются в исходных папках")
            refresh()
        }
    }
    func createPlaylist() {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = "Новый плейлист"; alert.informativeText = "Добавляйте композиции через контекстное меню списка."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 25)); input.stringValue = "Новый плейлист"; alert.accessoryView = input; alert.addButton(withTitle: "Создать"); alert.addButton(withTitle: "Отмена")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !["Музыка", "Недавно добавленные"].contains(name), self.library.playlists[name] == nil else { self.showError("Выберите другое имя плейлиста."); return }
            self.library.playlists[name] = []; self.library.save(); self.refresh()
        }
    }
    static func groups(_ tracks: [Track], by kind: GridGrouping) -> [LibraryGroup] {
        let grouped = Dictionary(grouping: tracks) { track -> String in
            switch kind {
            case .albums: return track.albumKey
            case .artists: return Track.normalized(track.albumDisplayArtist)
            case .genres: return Track.normalized(track.genre == "—" ? "Без жанра" : track.genre)
            case .composers: return Track.normalized(Track.nonempty(track.composer) ?? "Неизвестный композитор")
            }
        }
        return grouped.map { key, records in
            let first = records[0]; let title: String
            switch kind { case .albums: title = first.isVideo ? first.title : first.album; case .artists: title = first.albumDisplayArtist; case .genres: title = first.genre == "—" ? "Без жанра" : first.genre; case .composers: title = Track.nonempty(first.composer) ?? "Неизвестный композитор" }
            let albumCount = Set(records.map(\.albumKey)).count
            let subtitle = kind == .albums ? first.albumDisplayArtist : "\(albumCount) альб. · \(records.count) песен"
            return LibraryGroup(key: key, title: title, subtitle: subtitle, tracks: records)
        }.sorted { a, b in
            let aa = kind == .albums ? (a.tracks[0].sortAlbum ?? a.title) : a.title
            let bb = kind == .albums ? (b.tracks[0].sortAlbum ?? b.title) : b.title
            return aa.localizedStandardCompare(bb) == .orderedAscending
        }
    }
    func editSelection(forceTrack: Bool = false) {
        if let drawer = focusedDrawer, !drawer.selectedTracks.isEmpty { presentEditor(drawer.selectedTracks, album: false); return }
        if window?.firstResponder === table, !selectedTableTracks.isEmpty { presentEditor(selectedTableTracks, album: false); return }
        if mode == 2, let first = flowDetail.orderedTracks.first { if forceTrack { presentEditor([first], album: false) } else { editAlbum(first) }; return }
        if !forceTrack, mode == 1, let track = rows.first { editAlbum(track); return }
        if !forceTrack, mode == 3, stage.gridGroups.indices.contains(stage.selected), let track = stage.gridGroups[stage.selected].tracks.first { editAlbum(track); return }
        guard rows.indices.contains(table.selectedRow) else { return }
        presentEditor(selectedTableTracks, album: false)
    }
    func editAlbum(_ track: Track) { presentEditor(library.tracks.filter { $0.albumKey == track.albumKey }, album: true) }
    private func presentEditor(_ records: [Track], album: Bool) {
        guard editor == nil, let window, !records.isEmpty else { return }
        let controller = MetadataEditor(library: library, records: records, albumMode: album)
        editor = controller
        controller.onClose = { [weak self] in self?.editor = nil }
        controller.onSaved = { [weak self] in self?.albumFilter = nil; self?.groupTitle = nil; self?.notice = "Изменения сохранены"; self?.refresh() }
        controller.present(for: window)
    }
    func showError(_ message: String) { let alert = NSAlert(); alert.messageText = "iTunes"; alert.informativeText = message; if let window { alert.beginSheetModal(for: window) } }
}

extension PlayerView: NSMenuDelegate {
    func showTrackContext(row: Int, at point: NSPoint) {
        guard rows.indices.contains(row) else { return }
        if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        window?.makeFirstResponder(table)
        let tracks = selectedTableTracks, track = rows[row]
        var actions: [(String, () -> Void)] = [
            ("Воспроизвести", { [weak self] in guard let self, let first = tracks.first else { return }; self.library.play(first, within: tracks.count > 1 ? tracks : self.rows, contextTitle: self.playbackContextTitle) }),
            ("Воспроизвести следующим", { [weak self] in self?.library.enqueue(tracks, next: true) }),
            ("Добавить в очередь позже", { [weak self] in self?.library.enqueue(tracks, next: false) }),
            ("", {}),
            (tracks.count > 1 ? "Информация о композициях…" : "Информация о композиции…", { [weak self] in self?.presentEditor(tracks, album: false) }),
            ("Информация об альбоме…", { [weak self] in self?.editAlbum(track) })
        ]
        for name in library.playlists.keys.sorted() { actions.append(("Добавить в плейлист «" + name + "»", { [weak self] in self?.addToPlaylist(tracks, name: name) })) }
        if tracks.contains(where: { $0.path != nil }) { actions.append(("Показать в Finder", { NSWorkspace.shared.activateFileViewerSelecting(tracks.compactMap { $0.path.map { URL(fileURLWithPath: $0) } }) })) }
        if library.playlists[source] != nil { let name = source; actions.append(("Убрать из плейлиста", { [weak self] in guard let self else { return }; let ids = Set(tracks.map(\.id)); self.library.playlists[name]?.removeAll { ids.contains($0) }; self.library.save(); self.refresh() })) }
        actions += [("", {}), ("Удалить из медиатеки…", { [weak self] in self?.confirmRemoval(tracks) })]
        ClassicActionMenu.show(actions, from: table, at: point)
    }
    @objc func contextPlay() { playSelected() }
    @objc func contextQueueNext() { library.enqueue(selectedTableTracks, next: true) }
    @objc func contextQueueLater() { library.enqueue(selectedTableTracks, next: false) }
    @objc func contextEditTrack() { editSelection(forceTrack: true) }
    @objc func contextEditAlbum() { if rows.indices.contains(table.selectedRow) { editAlbum(rows[table.selectedRow]) } }
    @objc func contextAdd(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? [String: Any], let ids = value["ids"] as? [String], let name = value["playlist"] as? String {
            let selected = Set(ids); addToPlaylist(rows.filter { selected.contains($0.id) }, name: name)
        }
    }
    @objc func contextReveal(_ sender: NSMenuItem) { NSWorkspace.shared.activateFileViewerSelecting(selectedTableTracks.compactMap { $0.path.map { URL(fileURLWithPath: $0) } }) }
    @objc func contextRemove(_ sender: NSMenuItem) { let ids = Set(selectedTableTracks.map(\.id)); library.playlists[source]?.removeAll { ids.contains($0) }; library.save(); refresh() }
}

/// Glossy black QuickTime-era HUD, shared by embedded and full-screen video.
@MainActor final class VideoHUDButton: NSButton {
    enum Glyph { case previous, rewind, play, pause, forward, next, fullScreen }
    var glyph: Glyph { didSet { needsDisplay = true } }
    private let invoke: () -> Void
    init(_ glyph: Glyph, label: String, action: @escaping () -> Void) {
        self.glyph = glyph; invoke = action; super.init(frame: .zero); title = label; setAccessibilityLabel(label); isBordered = false; target = self; self.action = #selector(press)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func press() { invoke() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath()
        func triangle(_ x: CGFloat, _ width: CGFloat, reverse: Bool = false) {
            p.move(to: NSPoint(x: reverse ? x + width : x, y: 3)); p.line(to: NSPoint(x: reverse ? x : x + width, y: bounds.midY)); p.line(to: NSPoint(x: reverse ? x + width : x, y: bounds.height - 3)); p.close()
        }
        switch glyph {
        case .play: triangle(4, bounds.width - 8)
        case .pause: p.appendRect(NSRect(x: 5, y: 3, width: 6, height: bounds.height - 6)); p.appendRect(NSRect(x: bounds.width - 11, y: 3, width: 6, height: bounds.height - 6))
        case .rewind, .forward:
            triangle(2, bounds.width / 2 - 2, reverse: glyph == .rewind); triangle(bounds.width / 2, bounds.width / 2 - 2, reverse: glyph == .rewind)
        case .previous, .next:
            let reverse = glyph == .previous; triangle(reverse ? 6 : 2, bounds.width - 8, reverse: reverse); p.appendRect(NSRect(x: reverse ? 3 : bounds.width - 5, y: 3, width: 2, height: bounds.height - 6))
        case .fullScreen:
            for flipped in [false, true] {
                let x: CGFloat = flipped ? 17 : 4, y: CGFloat = flipped ? 20 : 5, d: CGFloat = flipped ? -1 : 1
                p.move(to: NSPoint(x: x, y: y + d * 6)); p.line(to: NSPoint(x: x, y: y)); p.line(to: NSPoint(x: x + d * 6, y: y)); p.line(to: NSPoint(x: x + d * 4, y: y + d * 2)); p.line(to: NSPoint(x: x + d * 7, y: y + d * 5)); p.line(to: NSPoint(x: x + d * 5, y: y + d * 7)); p.line(to: NSPoint(x: x + d * 2, y: y + d * 4)); p.close()
            }
        }
        let gradient = NSGradient(starting: color(isHighlighted ? 0x888888 : 0xEFEFEF), ending: color(isHighlighted ? 0x555555 : 0x929292))!
        gradient.draw(in: p, angle: 90)
    }
}

@MainActor final class VideoHUDSlider: NSControl {
    var value: Double = 0 { didSet { value = min(1, max(0, value)); needsDisplay = true } }
    var onChange: ((Double) -> Void)?
    var diamond = false
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.slider) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func accessibilityValue() -> Any? { NSNumber(value: value) }
    override func accessibilityMinValue() -> Any? { 0 }
    override func accessibilityMaxValue() -> Any? { 1 }
    override func setAccessibilityValue(_ value: Any?) { if let n = value as? NSNumber { self.value = n.doubleValue; onChange?(self.value) } }
    override func accessibilityPerformIncrement() -> Bool { value += 0.02; onChange?(value); return true }
    override func accessibilityPerformDecrement() -> Bool { value -= 0.02; onChange?(value); return true }
    override func keyDown(with event: NSEvent) { if [123,125].contains(event.keyCode) { _ = accessibilityPerformDecrement() } else if [124,126].contains(event.keyCode) { _ = accessibilityPerformIncrement() } else { super.keyDown(with: event) } }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        func update(_ e: NSEvent) { value = (convert(e.locationInWindow, from: nil).x - 4) / max(1, bounds.width - 8); onChange?(value) }
        update(event)
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) { update(e); if e.type == .leftMouseUp { break } }
    }
    override func draw(_ dirtyRect: NSRect) {
        let groove = NSRect(x: 3, y: bounds.midY - 2.5, width: bounds.width - 6, height: 5)
        gradient(groove, 0x030303, 0x191919, radius: 2); stroke(groove, color(0x444444), radius: 2)
        let x = 4 + value * (bounds.width - 8), p = NSBezierPath()
        if diamond { p.move(to: NSPoint(x: x, y: bounds.midY - 4)); p.line(to: NSPoint(x: x + 4, y: bounds.midY)); p.line(to: NSPoint(x: x, y: bounds.midY + 4)); p.line(to: NSPoint(x: x - 4, y: bounds.midY)); p.close() }
        else { p.appendOval(in: NSRect(x: x - 4, y: bounds.midY - 4, width: 8, height: 8)) }
        NSGradient(starting: color(0xBFBFBF), ending: color(0x666666))!.draw(in: p, angle: 90)
    }
}

@MainActor final class InlineVideoControls: NSView {
    let library: Library
    let seek = VideoHUDSlider(), volume = VideoHUDSlider()
    let elapsed = NSTextField(labelWithString: "0:00"), remaining = NSTextField(labelWithString: "−0:00")
    private var transport: [VideoHUDButton] = []
    private var lastPointer = NSEvent.mouseLocation
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    var onFullScreen: (() -> Void)?
    override var isFlipped: Bool { true }
    init(library: Library) {
        self.library = library; super.init(frame: .zero); wantsLayer = true
        let actions: [(VideoHUDButton.Glyph, String, () -> Void)] = [(.previous,"Предыдущий клип",{ library.step(-1) }),(.rewind,"Назад на 10 секунд",{ library.seek(to: library.playbackTime - 10) }),(.play,"Воспроизведение / пауза клипа",{ library.toggle([]) }),(.forward,"Вперёд на 10 секунд",{ library.seek(to: library.playbackTime + 10) }),(.next,"Следующий клип",{ library.step(1) })]
        for (glyph,label,action) in actions { let b = VideoHUDButton(glyph,label:label,action:action); addSubview(b); transport.append(b) }
        let full = VideoHUDButton(.fullScreen,label:"Полный экран") { [weak self] in self?.onFullScreen?() }; addSubview(full); transport.append(full)
        volume.setAccessibilityLabel("Громкость клипа"); volume.onChange = { library.volume = Float($0) }; addSubview(volume)
        seek.diamond = true; seek.setAccessibilityLabel("Позиция клипа"); seek.onChange = { library.seek(to: $0 * library.playbackDuration) }; addSubview(seek)
        for label in [elapsed,remaining] { label.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular); label.textColor = color(0xC8C8C8); label.alignment = .center; addSubview(label) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout(); let middle = bounds.midX + 6
        for i in 0..<5 { transport[i].frame = NSRect(x: middle - 88 + CGFloat(i) * 34, y: 8, width: i == 2 ? 28 : 25, height: i == 2 ? 26 : 22) }
        transport[5].frame = NSRect(x: bounds.width - 33, y: 8, width: 23, height: 26)
        volume.frame = NSRect(x: 25, y: 10, width: 62, height: 20)
        elapsed.frame = NSRect(x: 8, y: 37, width: 42, height: 15); remaining.frame = NSRect(x: bounds.width - 52, y: 37, width: 46, height: 15)
        seek.frame = NSRect(x: 52, y: 35, width: max(1,bounds.width - 108), height: 18)
    }
    func refresh() {
        guard !isHidden else { lastActivity = ProcessInfo.processInfo.systemUptime; return }
        let now = ProcessInfo.processInfo.systemUptime, pointer = NSEvent.mouseLocation
        if pointer != lastPointer { lastPointer = pointer; lastActivity = now }
        let over = window.map { bounds.contains(convert($0.convertPoint(fromScreen: pointer), from: nil)) } ?? false
        let alpha: CGFloat = !library.playing || over || now - lastActivity < 2.5 ? 1 : 0
        if alphaValue != alpha { NSAnimationContext.runAnimationGroup { $0.duration = 0.2; animator().alphaValue = alpha } }
        seek.value = library.playbackDuration > 0 ? library.playbackTime / library.playbackDuration : 0
        volume.value = Double(library.volume); elapsed.stringValue = timeString(library.playbackTime); remaining.stringValue = "−" + timeString(max(0,library.playbackDuration - library.playbackTime))
        let glyph: VideoHUDButton.Glyph = library.playing ? .pause : .play
        if transport[2].glyph != glyph { transport[2].glyph = glyph }
    }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        gradient(r, 0x353535, 0x070707, radius: 6); stroke(r, .black, radius: 6)
        fill(NSRect(x: 5, y: 2, width: bounds.width - 10, height: 0.5), color(0x707070))
        func speaker(_ x: CGFloat, loud: Bool) {
            let p = NSBezierPath(); p.appendRect(NSRect(x:x,y:19,width:2,height:4)); p.move(to:NSPoint(x:x+2,y:19)); p.line(to:NSPoint(x:x+5,y:16)); p.line(to:NSPoint(x:x+5,y:26)); p.line(to:NSPoint(x:x+2,y:23)); p.close(); color(0xAAAAAA).setFill(); p.fill()
            for i in 0..<(loud ? 2 : 1) { let q = NSBezierPath(); let dx=x+7+CGFloat(i)*3; q.move(to:NSPoint(x:dx,y:18-CGFloat(i))); q.curve(to:NSPoint(x:dx,y:24+CGFloat(i)),controlPoint1:NSPoint(x:dx+3,y:19),controlPoint2:NSPoint(x:dx+3,y:23)); color(0xAAAAAA).setStroke(); q.stroke() }
        }
        speaker(12,loud:false); speaker(91,loud:true)
    }
}

struct LyricLine: Equatable { let time: Double; let text: String }
struct LyricDocument {
    let plain: String
    let lines: [LyricLine]
    init(_ source: String) {
        let expression = try! NSRegularExpression(pattern: #"\[(\d+):(\d{2})(?:[\.:](\d{1,3}))?\]"#)
        let offsetRE = try! NSRegularExpression(pattern: #"(?i)\[offset:([+-]?\d+)\]"#)
        let ns = source as NSString
        let offset = offsetRE.firstMatch(in: source, range: NSRange(location:0,length:ns.length)).map { Double(ns.substring(with:$0.range(at:1))) ?? 0 } ?? 0
        var result: [(Int,LyricLine)] = [], plainLines: [String] = []
        for raw in source.components(separatedBy:.newlines) {
            let text = raw as NSString, matches = expression.matches(in:raw,range:NSRange(location:0,length:text.length))
            if let last = matches.last {
                let content = text.substring(from:NSMaxRange(last.range)).trimmingCharacters(in:.whitespaces)
                for match in matches {
                    let seconds = Double(text.substring(with:match.range(at:2))) ?? 0
                    guard seconds < 60 else { continue }
                    let fraction = match.range(at:3).location == NSNotFound ? 0 : (Double("0." + text.substring(with:match.range(at:3))) ?? 0)
                    let time = max(0,(Double(text.substring(with:match.range(at:1))) ?? 0) * 60 + seconds + fraction + offset / 1000)
                    result.append((result.count,LyricLine(time:time,text:content)))
                }
                plainLines.append(content)
            } else if !raw.trimmingCharacters(in:.whitespaces).hasPrefix("[") { plainLines.append(raw) }
        }
        lines = result.sorted { $0.1.time == $1.1.time ? $0.0 < $1.0 : $0.1.time < $1.1.time }.map(\.1)
        plain = lines.isEmpty ? source : plainLines.joined(separator:"\n")
    }
    func index(at time:Double) -> Int? {
        var low = 0, high = lines.count
        while low < high { let mid = (low + high) / 2; if lines[mid].time <= time { low = mid + 1 } else { high = mid } }
        return low > 0 ? low - 1 : nil
    }
}

@MainActor final class LyricsScroll: NSScrollView {
    var onManualScroll: (() -> Void)?
    override func scrollWheel(with event:NSEvent) { onManualScroll?(); super.scrollWheel(with:event) }
}
@MainActor final class LyricsRow: NSButton {
    var active = false { didSet { setAccessibilitySelected(active) } }
    var past = false { didSet { if oldValue != past { needsDisplay = true } } }
    static var paragraph: NSParagraphStyle { let style = NSMutableParagraphStyle(); style.lineHeightMultiple = 1.45; return style }
    var emphasis: CGFloat = 0 { didSet { needsDisplay = true } }
    var onSelect: (() -> Void)?
    init(_ line:String) { super.init(frame:.zero); title = line.isEmpty ? "♪" : line; isBordered = false; target = self; action = #selector(choose); setAccessibilityLabel(title) }
    required init?(coder:NSCoder) { fatalError() }
    @objc private func choose() { onSelect?() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect:NSRect) {
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current?.cgContext.setAlpha(emphasis)
        let shadow = NSShadow(); shadow.shadowColor = color(0x2A65B3).withAlphaComponent(0.35); shadow.shadowOffset = NSSize(width:0,height:-1); shadow.shadowBlurRadius = 3; shadow.set()
        gradient(bounds.insetBy(dx:0,dy:2),0x5D96D8,0x2A65B3,radius:5)
        NSGraphicsContext.restoreGraphicsState()
        let textShadow = NSShadow(); textShadow.shadowColor = NSColor.black.withAlphaComponent(0.25 * emphasis); textShadow.shadowOffset = NSSize(width:0,height:-1)
        (title as NSString).draw(in:bounds.insetBy(dx:12,dy:10),withAttributes:[.font:NSFont(name:active ? "LucidaGrande-Bold" : "LucidaGrande",size:14) ?? NSFont.systemFont(ofSize:14,weight:active ? .semibold : .regular),.foregroundColor:color(past ? 0x7A7E85 : 0x333333).blended(withFraction:emphasis,of:.white) ?? NSColor.white,.paragraphStyle:Self.paragraph,.shadow:textShadow])
    }
}
@MainActor final class LyricsPane: NSView {
    let library: Library
    var onEdit: ((Track) -> Void)?
    let scroll = LyricsScroll()
    private let content = FlippedView()
    private let heading = NSTextField(labelWithString:"")
    private let status = NSTextField(wrappingLabelWithString:"")
    private var footerText: String {
        get { status.stringValue }
        set {
            let shadow = NSShadow(); shadow.shadowColor = NSColor.white.withAlphaComponent(0.8); shadow.shadowOffset = NSSize(width:0,height:-1)
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            status.attributedStringValue = NSAttributedString(string:newValue,attributes:[.font:font(10),.foregroundColor:color(0x6E737D),.shadow:shadow,.paragraphStyle:paragraph])
            status.toolTip = newValue
        }
    }
    private let plainView = NSTextView()
    private var buttons: [EditorButton] = []
    private(set) var rows: [LyricsRow] = []
    private var track: Track?
    private var signature = ""
    private var document = LyricDocument("")
    private var synchronized = true
    private(set) var follow = true
    private(set) var active: Int?
    private var motion: Timer?
    private var lastViewport = NSSize.zero
    private var localTask: Task<Void,Never>?
    private var record: LyricsRecord?
    private let service: LyricsService
    private var networkTask: Task<Void,Never>?
    override var isFlipped: Bool { true }
    init(library:Library, service:LyricsService = .shared) {
        self.library = library; self.service = service; super.init(frame:.zero)
        heading.font = font(12,bold:true); heading.lineBreakMode = .byTruncatingTail; addSubview(heading)
        status.font = font(10); status.textColor = color(0x6E737D); status.maximumNumberOfLines = 1; status.lineBreakMode = .byTruncatingTail; addSubview(status)
        for (i,title) in ["Текст","Синхронно","Открыть LRC…","К текущей строке","Изменить текст…","Найти текст","Действия…"].enumerated() {
            let b = EditorButton(title,label:title) { [weak self] in self?.action(i) }; addSubview(b); buttons.append(b)
        }
        scroll.documentView = content; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.onManualScroll = { [weak self] in self?.follow = false; self?.buttons[3].isHidden = false; self?.needsLayout = true }; addSubview(scroll)
        plainView.isEditable = false; plainView.isSelectable = true; plainView.isRichText = false; plainView.font = font(13); plainView.textColor = color(0x333333); plainView.backgroundColor = color(0xF2F4F8); plainView.textContainerInset = NSSize(width:12,height:14)
        render()
    }
    required init?(coder:NSCoder) { fatalError() }
    func update(_ newTrack:Track?) {
        let key = newTrack.map { LyricsService.key($0) + $0.id + ($0.lyrics ?? "") } ?? ""
        guard key != signature else { return }; signature = key; motion?.invalidate(); motion = nil; localTask?.cancel(); networkTask?.cancel(); track = newTrack; record = nil; follow = true; active = nil
        heading.stringValue = newTrack.map { $0.title + " — " + $0.artist } ?? "Текст песни"; render()
        if let newTrack {
            networkTask = Task { [weak self] in
                guard let self else { return }; let cached = await service.cached(newTrack)
                guard !Task.isCancelled, signature == key else { return }; record = cached; render()
            }
        }
    }
    private func action(_ index:Int) {
        switch index {
        case 0,1: synchronized = index == 1; follow = true; active = nil; render()
        case 2: importLRC()
        case 3: follow = true; buttons[3].isHidden = true; needsLayout = true; layoutSubtreeIfNeeded(); tick(force:true)
        case 4: if let track { onEdit?(track) }
        case 5: search()
        case 6:
            guard track != nil else { return }
            ClassicActionMenu.show([
                ("Найти текст в LRCLIB", { [weak self] in self?.search() }),
                ("Открыть LRC…", { [weak self] in self?.importLRC() }),
                ("Изменить текст…", { [weak self] in guard let self, let track = self.track else { return }; self.onEdit?(track) })
            ], from: buttons[6])
        default: break
        }
    }
    func importLRC() {
        guard track != nil, let window else { return }
        let panel = NSOpenPanel(); panel.title = "Выберите синхронный текст LRC"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }; let key = self.signature
            self.localTask = Task {
                let source = await Task.detached(priority:.utility) { () -> String? in
                    guard let data = try? Data(contentsOf:url), data.count < 2_000_000 else { return nil }; return String(data:data,encoding:.utf8) ?? String(data:data,encoding:.utf16)
                }.value
                guard !Task.isCancelled, self.signature == key else { return }
                guard let source, !LyricDocument(source).lines.isEmpty else { self.footerText = "В файле нет временных меток LRC или он не читается."; return }
                // LRC remains a library edit, never a rewrite of the original media file.
                guard let track = self.track else { return }
                var patch = MetadataPatch(); patch.fields[.lyrics] = source
                do { try await self.library.applyAsync(patch,to:[track.id]); self.update(self.library.tracks.first { $0.id == track.id }) }
                catch { self.footerText = error.localizedDescription }
            }
        }
    }
    func search() {
        guard let track else { return }; networkTask?.cancel(); let key = signature
        buttons[5].isEnabled = false; footerText = "Поиск в LRCLIB…"
        networkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.find(track)
                guard !Task.isCancelled, signature == key else { return }; record = result; follow = true; active = nil; render()
                if result == nil { footerText = "Совпадение не найдено. Проверьте название и исполнителя в метаданных." }
            } catch {
                guard !Task.isCancelled, signature == key else { return }; footerText = error.localizedDescription
            }
            buttons[5].isEnabled = true
        }
    }
    private func render() {
        motion?.invalidate(); motion = nil
        buttons[0].selected = !synchronized; buttons[1].selected = synchronized; buttons[2].isEnabled = track != nil; buttons[4].isEnabled = track != nil; buttons[3].isHidden = follow; buttons[5].isEnabled = track != nil; buttons[6].isEnabled = track != nil
        let source = track?.lyrics ?? "", local = LyricDocument(source)
        document = !local.lines.isEmpty ? local : LyricDocument(record?.syncedLyrics ?? "")
        let plain = !source.isEmpty ? local.plain : record?.plainLyrics ?? document.plain
        rows.forEach { $0.removeFromSuperview() }; rows = []; plainView.removeFromSuperview()
        if synchronized && !document.lines.isEmpty {
            for line in document.lines {
                let row = LyricsRow(line.text)
                row.onSelect = { [weak self] in guard let self, self.library.currentID == self.track?.id else { return }; self.library.seek(to:line.time); self.follow = true; self.buttons[3].isHidden = true; self.needsLayout = true; self.layoutSubtreeIfNeeded(); self.tick(force:true) }
                content.addSubview(row); rows.append(row)
            }
        } else { plainView.string = plain; content.addSubview(plainView) }
        if track == nil { footerText = "Выберите или включите песню." }
        else if record?.instrumental == true && source.isEmpty { footerText = "Инструментальная композиция · LRCLIB" }
        else if synchronized && !document.lines.isEmpty { footerText = local.lines.isEmpty ? "Синхронный текст · LRCLIB" : "Синхронный текст · из медиатеки" }
        else if !plain.isEmpty { footerText = !source.isEmpty ? "Текст из метаданных" : "Обычный текст · LRCLIB"; if synchronized { footerText += " · без синхронизации" } }
        else { footerText = "Текста пока нет. Найдите его в интернете или добавьте свой." }
        active = nil; needsLayout = true; layoutSubtreeIfNeeded(); tick(force:true)
    }
    static func motionProgress(_ elapsed: Double) -> CGFloat { let t = min(1,max(0,elapsed / 0.3)); return CGFloat(1 - pow(1 - t,3)) }
    func tick(force:Bool = false) {
        guard !isHiddenOrHasHiddenAncestor, library.currentID == track?.id, !rows.isEmpty else { return }
        let next = document.index(at:library.playbackTime)
        guard force || next != active else { return }
        motion?.invalidate(); motion = nil
        let previous = active; active = next
        if let previous, rows.indices.contains(previous) { rows[previous].active = false }
        if let next, rows.indices.contains(next) { rows[next].active = true }
        for index in rows.indices { rows[index].past = next.map { index < $0 } ?? false }
        let transitioning = rows.indices.filter { rows[$0].emphasis > 0 || $0 == next }
        let starts = transitioning.map { rows[$0].emphasis }
        let scrollStart = scroll.contentView.bounds.origin.y
        let scrollEnd: CGFloat = next.map { max(0,min(content.frame.height-scroll.contentSize.height,rows[$0].frame.midY-scroll.contentSize.height*0.5)) } ?? scrollStart
        func apply(_ p: CGFloat) {
            for (i,index) in transitioning.enumerated() { let target: CGFloat = index == next ? 1 : 0; rows[index].emphasis = starts[i] + (target-starts[i])*p }
            if follow { let y = max(0,min(content.frame.height-scroll.contentSize.height,scrollStart+(scrollEnd-scrollStart)*p)); scroll.contentView.scroll(to:NSPoint(x:0,y:y)); scroll.reflectScrolledClipView(scroll.contentView) }
        }
        guard !force, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { apply(1); return }
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval:1/60,repeats:true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let elapsed = CACurrentMediaTime()-began
                if self.isHiddenOrHasHiddenAncestor { timer.invalidate(); self.motion = nil; return }
                apply(Self.motionProgress(elapsed))
                if elapsed >= 0.3 { timer.invalidate(); self.motion = nil }
            }
        }
        motion = timer; RunLoop.main.add(timer,forMode:.common)
    }
    override func layout() {
        super.layout(); needsDisplay = true; let w = bounds.width
        guard w >= 180 else { return }
        let headerHeight: CGFloat = follow ? 104 : 136
        buttons[6].frame = NSRect(x:w-94,y:4,width:82,height:23)
        for i in [2,4,5] { buttons[i].isHidden = true }
        heading.frame = NSRect(x:14,y:39,width:w-28,height:20)
        buttons[0].frame = NSRect(x:12,y:66,width:(w-24)/2,height:24); buttons[1].frame = NSRect(x:w/2,y:66,width:(w-24)/2,height:24)
        buttons[3].frame = NSRect(x:12,y:102,width:w-24,height:24)
        status.frame = NSRect(x:12,y:max(headerHeight,bounds.height-20)+3,width:w-24,height:14)
        status.toolTip = status.stringValue
        scroll.frame = NSRect(x:2,y:headerHeight,width:w-2,height:max(0,bounds.height-headerHeight-20))
        let width = scroll.contentSize.width
        if !rows.isEmpty {
            let heights = rows.map { row in max(44,(row.title as NSString).boundingRect(with:NSSize(width:width-40,height:10000),options:.usesLineFragmentOrigin,attributes:[.font:font(14,bold:true),.paragraphStyle:LyricsRow.paragraph]).height + 24) }
            var y = max(24,scroll.contentSize.height/2 - heights[0]/2)
            for (index,row) in rows.enumerated() { let h = heights[index]; row.frame = NSRect(x:8,y:y,width:width-16,height:h); y += h }
            content.frame.size = NSSize(width:width,height:max(scroll.contentSize.height,y + max(24,scroll.contentSize.height/2 - heights.last!/2)))
        } else {
            plainView.frame = NSRect(x:0,y:0,width:width,height:max(1,scroll.contentSize.height)); plainView.textContainer?.containerSize = NSSize(width:width-24,height:CGFloat.greatestFiniteMagnitude)
            plainView.layoutManager?.ensureLayout(for:plainView.textContainer!)
            let height = (plainView.layoutManager?.usedRect(for:plainView.textContainer!).height ?? 0)+32
            plainView.frame.size.height = max(scroll.contentSize.height,height); content.frame.size = plainView.frame.size
        }
        if lastViewport != scroll.contentSize { lastViewport = scroll.contentSize; tick(force:true) }
    }
    override func draw(_ dirtyRect:NSRect) {
        let headerHeight: CGFloat = follow ? 104 : 136
        fill(bounds,color(0xF2F4F8))
        gradient(NSRect(x:0,y:0,width:bounds.width,height:headerHeight),0xEAECEF,0xDFE2E7)
        fill(NSRect(x:0,y:headerHeight-1,width:bounds.width,height:1),color(0xC6C9CE))
        let footerY = max(headerHeight,bounds.height-20)
        gradient(NSRect(x:0,y:footerY,width:bounds.width,height:20),0xEFF0F3,0xE2E5EA)
        fill(NSRect(x:0,y:footerY,width:bounds.width,height:1),color(0xC6C9CE))
        fill(NSRect(x:0,y:0,width:1,height:bounds.height),color(0xB8B8B8))
        fill(NSRect(x:1,y:0,width:1,height:bounds.height),NSColor.white.withAlphaComponent(0.8))
        engravedText("Текст песни",NSRect(x:14,y:7,width:bounds.width-116,height:20),size:12,ink:color(0x424B58),bold:true)
    }
}

struct LyricsRecord: Codable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: Double
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
    var usable: Bool { instrumental || !(plainLyrics ?? "").isEmpty || !LyricDocument(syncedLyrics ?? "").lines.isEmpty }
    static func matches(_ record:LyricsRecord,_ track:Track) -> Bool {
        Track.normalized(record.trackName) == Track.normalized(track.title) && Track.normalized(record.artistName) == Track.normalized(track.artist) && abs(record.duration-track.duration) <= 3
    }
}

enum LyricsFailure: LocalizedError {
    case message(String)
    var errorDescription:String? { if case .message(let message) = self { return message }; return nil }
}
actor LyricsService {
    static let shared = LyricsService()
    private var busy = false
    private var nextRequest = Date.distantPast
    private let folder:URL
    private let session:URLSession
    init(folder:URL = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("iTunes Prototype/Lyrics"),session:URLSession = .shared) { self.folder = folder; self.session = session }
    static func key(_ track:Track) -> String { SHA256.hash(data:Data([track.title,track.artist,track.album,String(track.duration)].joined(separator:"\u{0}").utf8)).map { String(format:"%02x",$0) }.joined() }
    func cached(_ track:Track) -> LyricsRecord? {
        guard let data = try? Data(contentsOf:folder.appendingPathComponent(Self.key(track)+".json")), data.count < 2_000_000, let result = try? JSONDecoder().decode(LyricsRecord.self,from:data), LyricsRecord.matches(result,track) else { return nil }; return result
    }
    func save(_ result:LyricsRecord,for track:Track) throws {
        guard LyricsRecord.matches(result,track), result.usable else { return }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true); try JSONEncoder().encode(result).write(to:folder.appendingPathComponent(Self.key(track)+".json"),options:.atomic)
    }
    func find(_ track:Track) async throws -> LyricsRecord? {
        guard !busy else { throw LyricsFailure.message("Поиск уже выполняется. Попробуйте чуть позже.") }
        guard Date() >= nextRequest else { throw LyricsFailure.message("Сервис просит подождать. Повторите поиск позже.") }
        busy = true; defer { busy = false }
        var parameters = [URLQueryItem(name:"track_name",value:track.title),URLQueryItem(name:"artist_name",value:track.artist),URLQueryItem(name:"album_name",value:track.album)]
        if track.duration >= 1 && track.duration <= 3600 { parameters.append(URLQueryItem(name:"duration",value:String(track.duration))) }
        if let data = try await request("get",parameters), let result = try? JSONDecoder().decode(LyricsRecord.self,from:data), LyricsRecord.matches(result,track), result.usable { try save(result,for:track); return result }
        let data = try await request("search",Array(parameters.prefix(2)))
        let results = try data.map { try JSONDecoder().decode([LyricsRecord].self,from:$0) } ?? []
        let matches = results.filter { LyricsRecord.matches($0,track) && $0.usable }.sorted {
            let a = LyricDocument($0.syncedLyrics ?? "").lines.isEmpty, b = LyricDocument($1.syncedLyrics ?? "").lines.isEmpty
            if a != b { return !a }; return abs($0.duration-track.duration) < abs($1.duration-track.duration)
        }
        if let result = matches.first { try save(result,for:track); return result }; return nil
    }
    private func request(_ path:String,_ parameters:[URLQueryItem]) async throws -> Data? {
        let wait = max(0,nextRequest.timeIntervalSinceNow)
        if wait > 0 { try await Task.sleep(nanoseconds:UInt64(wait * 1_000_000_000)) }
        try Task.checkCancellation()
        var url = URLComponents(string:"https://lrclib.net/api/"+path)!; url.queryItems = parameters
        var request = URLRequest(url:url.url!); request.timeoutInterval = 15
        let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.30"
        request.setValue("iTunes-Local-Prototype/\(version) (local macOS development build)",forHTTPHeaderField:"User-Agent")
        let (data,response) = try await session.data(for:request)
        nextRequest = Date().addingTimeInterval(0.4)
        guard let http = response as? HTTPURLResponse else { throw LyricsFailure.message("Нет ответа от сервиса текстов.") }
        if http.statusCode == 429 || http.statusCode == 503 {
            let retry = http.value(forHTTPHeaderField:"Retry-After") ?? "30"
            let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT:0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let delay = Double(retry) ?? formatter.date(from:retry)?.timeIntervalSinceNow ?? 30
            nextRequest = Date().addingTimeInterval(max(1,delay) * Double.random(in:1...1.3))
            throw LyricsFailure.message("Сервис временно занят. Повторите поиск позже.")
        }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200, data.count < 2_000_000, http.mimeType == "application/json" else { throw LyricsFailure.message("Не удалось получить текст. Попробуйте позже.") }
        return data
    }
}


@MainActor extension PlayerView {
    static func finderURLs(_ tracks: [Track]) -> [URL] { Array(Set(tracks.compactMap(\.path))).sorted().map { URL(fileURLWithPath:$0) } }
    func albumMembers(_ requested: [Track]) -> [Track] { let keys=Set(requested.map(\.albumKey)); return library.tracks.filter { keys.contains($0.albumKey) } }
    func confirmRemoval(_ requested: [Track], album: Bool = false) {
        guard let window else { return }
        let ids=Set((album ? albumMembers(requested) : requested).map(\.id)); let tracks=library.tracks.filter { ids.contains($0.id) }; guard !tracks.isEmpty else { return }
        let alert=NSAlert(); alert.messageText=album ? "Удалить альбом «\(tracks[0].album)»?" : (tracks.count == 1 ? "Удалить «\(tracks[0].title)»?" : "Удалить выбранные композиции (\(tracks.count))?")
        alert.informativeText="«Удалить из медиатеки» уберёт записи из библиотеки, плейлистов и очереди, сохранив файлы. «В Корзину» также переместит исходные файлы на Mac в Корзину."
        alert.addButton(withTitle:"Удалить из медиатеки"); alert.addButton(withTitle:"Отмена")
        if tracks.contains(where: { $0.path != nil }) { alert.addButton(withTitle:"В Корзину") }
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { self.library.removeRecords(ids); return }
            guard response == .alertThirdButtonReturn else { return }
            Task {
                let paths=Set(tracks.compactMap(\.path))
                let outcome=await Task.detached { () -> (Set<String>,[String]) in
                    var removed=Set<String>(), failures: [String]=[]
                    for path in paths {
                        switch MediaAudit.state(path) {
                        case .missing: removed.insert(path)
                        case .unavailable: failures.append("\(URL(fileURLWithPath:path).lastPathComponent): файл или диск недоступен")
                        case .present:
                            do { try FileManager.default.trashItem(at:URL(fileURLWithPath:path),resultingItemURL:nil); removed.insert(path) }
                            catch { failures.append("\(URL(fileURLWithPath:path).lastPathComponent): \(error.localizedDescription)") }
                        }
                    }
                    return (removed,failures)
                }.value
                let safe=Set(self.library.tracks.filter { track in track.path.map { outcome.0.contains($0) } ?? ids.contains(track.id) }.map(\.id))
                self.library.removeRecords(safe)
                if !outcome.1.isEmpty { self.showError("Не удалось переместить часть файлов в Корзину. Их записи сохранены.\n"+outcome.1.prefix(6).joined(separator:"\n")) }
            }
        }
    }
    func auditMediaFiles() {
        guard !importing, let window else { return }
        importing=true; notice="Проверка файлов медиатеки…"; needsDisplay=true
        let tracks=library.tracks
        Task { [self] in
            let audit=await Task.detached { MediaAudit.scan(tracks) }.value
            importing=false; needsDisplay=true
            let unavailable=audit.unavailable > 0 ? "\nНе удалось проверить: \(audit.unavailable). Записи с отключённых дисков и без доступа сохраняются." : ""
            guard !audit.missing.isEmpty else { AquaMessage.show(for:window,title:"Проверка медиатеки",message:"Отсутствующие файлы не найдены."+unavailable); return }
            let message="Не найдены файлы: \(audit.missing.count). Убрать их записи из медиатеки, плейлистов и очереди? Исходные файлы команда не удаляет."+unavailable+"\n\n"+audit.missing.prefix(12).map { $0.title }.joined(separator:"\n")
            AquaMessage.show(for:window,title:"Проверка медиатеки",message:message,confirm:"Убрать отсутствующие",cancel:true) { [weak self] accepted in
                guard let self, accepted else { return }
                Task {
                    let stillMissing=await Task.detached { MediaAudit.scan(audit.missing).missing }.value
                    let paths=Dictionary(uniqueKeysWithValues:stillMissing.map { ($0.id,$0.path) })
                    let ids=Set(self.library.tracks.filter { track in paths[track.id].map { $0 == track.path } ?? false }.map(\.id))
                    self.library.removeRecords(ids)
                }
            }
        }
    }
}
