import AppKit
import AVFoundation
import MediaPlayer

@MainActor final class PlayerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

enum WindowPlacement {
    static let key = "MainWindowFrame"
    static func constrained(_ saved: NSRect, to screens: [NSRect], minimum: NSSize) -> NSRect? {
        guard !screens.isEmpty, [saved.minX, saved.minY, saved.width, saved.height].allSatisfy({ $0.isFinite }), saved.width > 0, saved.height > 0 else { return nil }
        let screen = screens.max { a, b in
            let aa = saved.intersection(a), bb = saved.intersection(b)
            return (aa.isNull ? 0 : aa.width * aa.height) < (bb.isNull ? 0 : bb.width * bb.height)
        }!
        let width = min(screen.width, max(minimum.width, saved.width))
        let height = min(screen.height, max(minimum.height, saved.height))
        return NSRect(x: min(screen.maxX - width, max(screen.minX, saved.minX)), y: min(screen.maxY - height, max(screen.minY, saved.minY)), width: width, height: height)
    }
    static func restore(_ defaults: UserDefaults, screens: [NSRect], minimum: NSSize) -> NSRect? {
        guard let value = defaults.string(forKey: key) else { return nil }
        return constrained(NSRectFromString(value), to: screens, minimum: minimum)
    }
    static func save(_ frame: NSRect, defaults: UserDefaults) {
        guard frame.width >= 600, frame.height >= 300 else { return }
        defaults.set(NSStringFromRect(frame), forKey: key)
    }
}

@MainActor func testRefinements(track fixture: Track, root: URL) {
    let suite = "iTunes-refinements-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = Library(storage: root.appendingPathComponent("preferences.json"), defaults: defaults)
    precondition(abs(first.volume - 0.65) < 0.0001)
    first.volume = 0.27
    let restored = Library(storage: root.appendingPathComponent("preferences.json"), defaults: defaults)
    precondition(abs(restored.volume - 0.27) < 0.0001)
    first.volume = 2; precondition(first.volume == 1)
    first.volume = -1; precondition(first.volume == 0)
    first.volume = .nan; precondition(first.volume == 0)
    defaults.set(Double.infinity, forKey: Library.volumePreferenceKey)
    precondition(Library(storage: root.appendingPathComponent("invalid.json"), defaults: defaults).volume == 0.65)

    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900), minimum = NSSize(width: 1000, height: 620)
    let frame = NSRect(x: 70, y: 35, width: 1280, height: 840)
    WindowPlacement.save(frame, defaults: defaults)
    precondition(WindowPlacement.restore(defaults, screens: [screen], minimum: minimum) == frame)
    WindowPlacement.save(NSRect(x: 50, y: 700, width: 360, height: 64), defaults: defaults)
    precondition(WindowPlacement.restore(defaults, screens: [screen], minimum: minimum) == frame, "Mini player must not replace the normal window frame")
    let offscreen = NSRect(x: 5000, y: -2000, width: 2000, height: 1600)
    precondition(screen.contains(WindowPlacement.constrained(offscreen, to: [screen], minimum: minimum)!))
    precondition(WindowPlacement.constrained(NSRect(x: CGFloat.nan, y: 0, width: 1200, height: 800), to: [screen], minimum: minimum) == nil)
    precondition(WindowPlacement.constrained(frame, to: [], minimum: minimum) == nil)

    for (count, expected) in [(1,"1 песня"),(2,"2 песни"),(5,"5 песен"),(11,"11 песен"),(14,"14 песен"),(21,"21 песня"),(22,"22 песни"),(25,"25 песен"),(101,"101 песня")] {
        precondition(AlbumSummary.inflect(count, "песня", "песни", "песен") == expected)
    }
    for (minutes, expected) in [(0,"0 минут"),(1,"1 минута"),(2,"2 минуты"),(5,"5 минут"),(11,"11 минут"),(21,"21 минута"),(59,"59 минут"),(60,"1 час"),(61,"1 час 1 минута"),(62,"1 час 2 минуты"),(65,"1 час 5 минут"),(120,"2 часа"),(300,"5 часов")] {
        precondition(AlbumSummary.duration(Double(minutes) * 60) == expected)
    }
    var record = fixture; record.year = 2026; record.duration = 180
    let records = Array(repeating: record, count: 21)
    precondition(AlbumSummary.text(records) == "2026 · 21 песня · 1 час 3 минуты")
    let group = LibraryGroup(key: "refinement", title: "Альбом", subtitle: "Артист", tracks: records)
    let drawer = AlbumDrawer(frame: NSRect(x: 0, y: 0, width: 960, height: 500)); drawer.configure(group); drawer.layoutSubtreeIfNeeded()
    precondition(drawer.closeFrame.midY == drawer.titleFrame.midY && drawer.summary == AlbumSummary.text(records))
    let stage = AlbumStage(frame: NSRect(x: 0, y: 0, width: 960, height: 600)); stage.grid = true; stage.gridGroups = [group]
    let actions = stage.albumActions(at: 0)
    precondition(actions.map(\.0).contains("Добавить в очередь позже") && actions.map(\.0).contains("Информация об альбоме…"))
    var queued = 0; stage.drawer.onQueue = { tracks, next in queued = tracks.count; precondition(!next) }
    actions.first { $0.0 == "Добавить в очередь позже" }!.1(); precondition(queued == 21)

    let queueLibrary = Library(storage: root.appendingPathComponent("queue-bounds.json")); queueLibrary.tracks = [fixture]
    queueLibrary.playbackPlan.add([fixture.id], next: false)
    let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    let queueUI = QueuePopover(library: queueLibrary, anchor: anchor)
    queueUI.body.layoutSubtreeIfNeeded()
    let scroll = queueUI.body.scroll
    precondition(scroll.verticalScrollElasticity == .none && !scroll.hasVerticalScroller)
    var proposed = scroll.contentView.bounds; proposed.origin.y = 10_000
    precondition(scroll.contentView.constrainBoundsRect(proposed).minY == 0)
    queueLibrary.playbackPlan.add(Array(repeating: fixture.id, count: 30), next: false); queueUI.reload()
    precondition(scroll.hasVerticalScroller)
    proposed = scroll.contentView.bounds; proposed.origin.y = 10_000
    let maximum = queueUI.table.bounds.height - proposed.height
    precondition(abs(scroll.contentView.constrainBoundsRect(proposed).minY - maximum) < 0.01)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum))
    queueLibrary.playbackPlan.clearManual(); queueUI.reload()
    precondition(!scroll.hasVerticalScroller && scroll.contentView.bounds.minY == 0 && queueUI.items.isEmpty)

    var sixty = CoverFlowMotion(), oneTwenty = CoverFlowMotion()
    sixty.follow(3, at: 0); oneTwenty.follow(3, at: 0)
    for i in 1...6 { sixty.advance(at: Double(i) / 60) }
    for i in 1...12 { oneTwenty.advance(at: Double(i) / 120) }
    precondition(abs(sixty.position - oneTwenty.position) < 0.000001)
    precondition(abs(sixty.velocity - oneTwenty.velocity) < 0.000001)
    let before = oneTwenty.position
    oneTwenty.follow(4, at: 0.1); precondition(oneTwenty.position == before, "Input must update the target without jumping the rendered position")
    oneTwenty.advance(at: 0.11); precondition(oneTwenty.position > before && oneTwenty.position < 4)
    oneTwenty.settle(4, at: 0.11); oneTwenty.settle(4, at: 0.2)
    precondition(!oneTwenty.advance(at: 0.11 + CoverFlowMotion.settleDuration) && oneTwenty.position == 4 && oneTwenty.velocity == 0)
    precondition(CoverFlowGeometry.recession(depth: 0.00001) / 0.00001 < 0.01, "Depth velocity must also be continuous at the front cover")
    for f in [CoverFlowGeometry.offset(distance: 1, size: 1), CoverFlowGeometry.angle(depth: 1), CoverFlowGeometry.recession(depth: 1)] { precondition(f.isFinite) }
    let epsilon: CGFloat = 0.00001
    for curve: (CGFloat) -> CGFloat in [{ CoverFlowGeometry.offset(distance: $0, size: 1) }, { CoverFlowGeometry.angle(depth: $0) }, { CoverFlowGeometry.recession(depth: $0) }] {
        let left = (curve(1) - curve(1 - epsilon)) / epsilon, right = (curve(1 + epsilon) - curve(1)) / epsilon
        precondition(abs(left - right) < 0.01, "Cover geometry must have continuous velocity at the side stack")
    }
    print("PASS: Russian album summaries and hour boundaries, centered close control, classic album actions, saved/validated volume, normal-window restoration and detached-screen bounds, short/long/shrinking queue bounds, display-rate independent Cover Flow and continuous 3D geometry")
}

@MainActor func testSelectionAndYearSort(track fixture: Track, root: URL) {
    let order = ["a", "b", "c", "d", "e"]
    var selection = ItemSelection()
    selection.select("b", ordered: order); selection.select("d", ordered: order, modifiers: .shift)
    precondition(selection.ids == Set(["b", "c", "d"]))
    selection.select("e", ordered: order, modifiers: .command); precondition(selection.ids.count == 4)
    selection.select("c", ordered: order, context: true); precondition(selection.ids.count == 4)
    selection.select("c", ordered: order, modifiers: .command); precondition(!selection.ids.contains("c"))
    selection.select("a", ordered: order); precondition(selection.ids == ["a"])
    selection.retain(["b"]); precondition(selection.ids.isEmpty)
    let tracks = order.enumerated().map { index, id -> Track in var t = fixture; t.id = id; t.number = index + 1; return t }
    let drawer = AlbumDrawer(frame: NSRect(x: 0, y: 0, width: 950, height: 500))
    drawer.configure(LibraryGroup(key: "multi", title: "Album", subtitle: "Artist", tracks: tracks))
    var played = 0, queued: [String] = []
    drawer.onPlayTracks = { _, _ in played += 1 }
    drawer.onQueue = { records, next in precondition(!next); queued = records.map(\.id) }
    drawer.select("b"); drawer.select("d", modifiers: .shift)
    precondition(played == 0 && drawer.selectedTracks.map(\.id) == ["b","c","d"])
    precondition(drawer.rows.filter(\.aquaSelected).map { $0.track.id } == ["b","c","d"])
    drawer.select("c", context: true); drawer.actionsForSelection().first { $0.0 == "Добавить в очередь позже" }!.1()
    precondition(queued == ["b","c","d"] && played == 0)
    drawer.playSelectedTracks(); precondition(played == 1)
    drawer.configure(LibraryGroup(key: "other", title: "Other", subtitle: "Artist", tracks: tracks)); precondition(drawer.selectedTracks.isEmpty)
    let library = Library(storage: root.appendingPathComponent("list-selection.json")); library.tracks = tracks
    let defaultsName = "iTunes-025-" + UUID().uuidString; let defaults = UserDefaults(suiteName: defaultsName)!
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let ui = PlayerView(library: library, sortDefaults: defaults); ui.setMode(0)
    ui.table.selectRowIndexes(IndexSet([1,2,3]), byExtendingSelection: false); let selectedIDs = ui.selectedTableTracks.map(\.id)
    ui.contextQueueLater(); precondition(library.playbackPlan.later.map(\.trackID) == selectedIDs && library.currentID == nil)
    ui.refresh(); precondition(ui.selectedTableTracks.map(\.id) == selectedIDs)
    ui.contextQueueNext(); precondition(library.playbackPlan.manual.map(\.trackID) == selectedIDs)
    ui.timer?.invalidate()
    var sortedTracks = [Track]()
    for (id, artist, year) in [("z-old","Zulu",2000),("z-new","Zulu",2020),("a-old","Alpha",1990),("a-new","Alpha",2010)] {
        var t = fixture; t.id = id; t.artist = artist; t.albumArtist = artist; t.year = year; t.album = id; t.sortArtist = nil; t.sortAlbumArtist = nil; sortedTracks.append(t)
    }
    var settings = LibrarySortSettings(primary: .artist, secondary: .year, ascending: false)
    precondition(sortedTracks.sorted { settings.compare($0,$1) }.map(\.id) == ["z-old","z-new","a-old","a-new"])
    settings.yearAscending = false
    precondition(sortedTracks.sorted { settings.compare($0,$1) }.map(\.id) == ["z-new","z-old","a-new","a-old"])
    settings.save(defaults); precondition(!LibrarySortSettings.load(defaults).yearAscending)
    let legacy = Data(#"{"primary":"artist","secondary":"year","ascending":false}"#.utf8)
    let migrated = try! JSONDecoder().decode(LibrarySortSettings.self, from: legacy)
    precondition(migrated.primary == .artist && !migrated.ascending && migrated.yearAscending)
    let area = NSRect(x: 8, y: 2, width: 68, height: 23)
    precondition(PlayerView.trafficHovered(at: NSPoint(x: 20,y: 10), area: area, active: true))
    precondition(!PlayerView.trafficHovered(at: NSPoint(x: 200,y: 100), area: area, active: true))
    precondition(!PlayerView.trafficHovered(at: NSPoint(x: 20,y: 10), area: area, active: false))
    print("PASS: Cmd/Shift/context Aqua multi-selection, group queue actions without playback, selection preservation, independent artist/year directions and legacy settings, traffic hover bounds")
}

@MainActor func testCrossfade(track fixture: Track, root: URL) async throws {
    let suite = "iTunes-crossfade-" + UUID().uuidString; let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let library = Library(storage: root.appendingPathComponent("crossfade.json"), defaults: defaults)
    let tracks = ["fade-a","fade-b","fade-c"].map { id -> Track in var t = fixture; t.id = id; t.title = id; return t }
    library.tracks = tracks; library.crossfadeSeconds = 1; library.crossfadeEnabled = true
    let saved = Library(storage: library.storage, defaults: defaults)
    precondition(saved.crossfadeEnabled && saved.crossfadeSeconds == 1)
    saved.crossfadeSeconds = .nan; precondition(saved.crossfadeSeconds == 1)
    library.play(tracks[0], within: Array(tracks.prefix(2)))
    let outgoing = library.player!
    for _ in 0..<150 { if library.isCrossfading { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(library.isCrossfading && library.currentID == "fade-b" && library.outgoingPlayer === outgoing)
    precondition(library.player !== outgoing && library.player!.isPlaying && outgoing.isPlaying)
    library.toggle([]); precondition(!library.player!.isPlaying && !outgoing.isPlaying)
    let paused = library.playbackTime; try await Task.sleep(nanoseconds: 100_000_000)
    precondition(abs(library.playbackTime - paused) < 0.03)
    library.toggle([]); precondition(library.player!.isPlaying)
    for _ in 0..<100 { if !library.isCrossfading { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(!library.isCrossfading && library.currentID == "fade-b" && !outgoing.isPlaying)
    precondition(library.tracks[1].plays == tracks[1].plays + 1)
    library.play(tracks[0], within: Array(tracks.prefix(2)))
    library.enqueue([tracks[2]], next: true)
    for _ in 0..<150 { if library.isCrossfading { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    precondition(library.isCrossfading && library.currentID == "fade-c", "Preparation must honor newly inserted Play Next tracks")
    precondition(library.tracks[2].plays == tracks[2].plays + 1)
    library.seek(to: 0.05); precondition(!library.isCrossfading && library.currentID == "fade-c")
    library.step(1); precondition(library.currentID == "fade-b" && !library.isCrossfading)
    library.crossfadeEnabled = false; library.stopPlayback(); library.flushPendingSave()
    let preferences = PlaybackPreferences(library: library); preferences.reload()
    precondition(preferences.enabled.state == .off && !preferences.seconds.isEnabled)
    print("PASS: overlapping real audio crossfade, persisted duration/enable, pause/resume of both players, correct album/Play Next order, one play count, seek/manual interruption and preferences")
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var window: NSWindow!
    var view: PlayerView!
    var eventMonitor: Any?
    var hoverMonitor: Any?
    var playbackPreferences: PlaybackPreferences?
    var aboutWindow: ClassicAboutWindow?
    var androidSyncWindow: AndroidSyncWindow?
    private var openMenus = Set<ObjectIdentifier>()
    private var sortMenuSnapshot: String?
    private var changingWindowMode = false
    private var fullScreenTransition = false
    var fullFrame: NSRect?
    var previewStorage: URL?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--inspect-metadata"), CommandLine.arguments.indices.contains(i + 1) {
            Task {
                let result = await ImportedMetadata.read(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                print(result?.fields.filter { [.genre, .year, .number, .discNumber].contains($0.key) }.map { $0.key.rawValue + "=" + $0.value }.sorted() ?? [])
                NSApp.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--self-test") { Task { await self.selfTest() }; return }
        if let i = CommandLine.arguments.firstIndex(of: "--profile-library"), CommandLine.arguments.indices.contains(i + 1) {
            let storage = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            func measure(_ label: String, _ body: () -> Void) { let start = Date(); body(); print("PROFILE " + label + " " + String(format: "%.3f s", Date().timeIntervalSince(start))); fflush(stdout) }
            var library: Library!
            measure("load") { library = Library(storage: storage) }
            print("PROFILE tracks \(library.tracks.count)"); fflush(stdout)
            measure("encode") { _ = try? JSONEncoder().encode(SavedLibrary(tracks: library.tracks, playlists: library.playlists, albumMetadataVersion: library.albumMetadataVersion)) }
            var ui: PlayerView!
            measure("initial UI") { ui = PlayerView(library: library) }
            for grouping in GridGrouping.allCases { measure(grouping.rawValue) { ui.gridGrouping = grouping; ui.refresh(); ui.layoutSubtreeIfNeeded() } }
            measure("playback refresh") { library.onPlaybackChange?() }
            for grouping in GridGrouping.allCases { measure("cached " + grouping.rawValue) { ui.gridGrouping = grouping; ui.refresh(); ui.layoutSubtreeIfNeeded() } }
            ui.timer?.invalidate(); NSApp.terminate(nil); return
        }
        let snapshot = CommandLine.arguments.contains("--snapshot")
        let previewIndex = CommandLine.arguments.firstIndex(of: "--preview-library")
        let previewURL = previewIndex.flatMap { i in CommandLine.arguments.indices.contains(i + 1) ? URL(fileURLWithPath: CommandLine.arguments[i + 1]) : nil }
        if snapshot || previewURL != nil { previewStorage = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("itunes-empty-preview-" + UUID().uuidString + "/library.json") }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url) {
            // Dock override avoids Tahoe's automatic legacy-icon backing without global settings.
            NSApp.applicationIconImage = image
        }
        let library = Library(storage: previewStorage)
        if !snapshot { library.systemMedia = SystemMedia(library) }
        view = PlayerView(library: library)
        window = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "iTunes"; window.titleVisibility = .hidden; window.titlebarSeparatorStyle = .none; window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua); window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1000, height: 620); window.contentView = view; window.delegate = self
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(type)?.isHidden = true }
        window.acceptsMouseMovedEvents = true
        if !snapshot, previewURL == nil, let frame = WindowPlacement.restore(.standard, screens: NSScreen.screens.map(\.visibleFrame), minimum: window.minSize) {
            window.setFrame(frame, display: false)
        } else { window.center() }
        window.makeKeyAndOrderFront(nil)
        // The transparent native title bar overlays this part of a full-size content view.
        // Observe window mouse movement as well as tracking areas so hovering works there.
        hoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let point = self.view.convert(event.locationInWindow, from: nil)
            self.view.refreshTrafficHover()
            if self.view.mode == 3 && !self.view.mini && self.view.albumScroll.frame.contains(point) {
                self.view.stage.scrub(at: self.view.stage.convert(event.locationInWindow, from: nil))
            } else { self.view.stage.clearScrub() }
            return event
        }
        view.onMini = { [weak self] in self?.toggleMini() }
        createMenu()
        if library.needsArtworkMigration && !snapshot && previewURL == nil { library.saveInBackground() }
        if let previewURL {
            Task {
                _ = await library.importURLs([previewURL]); self.view.source = "Видеоклипы"; self.view.refresh()
                if let clip = library.tracks.first(where: { $0.isVideo }) { library.play(clip, within: library.tracks.filter { $0.isVideo }) }
            }
        }
        if !snapshot, library.albumMetadataVersion != 3 {
            view.notice = "Чтение жанров и метаданных…"
            Task {
                await library.upgradeAlbumMetadata()
                self.view.notice = "Медиатека обновлена · исполнители треков сохранены"
                self.view.refresh()
            }
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.window === self.window, self.window.attachedSheet == nil, self.openMenus.isEmpty, ClassicPopup.active == nil else { return event }
            let command = event.modifierFlags.contains(.command)
            if command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "o": self.view.importFiles(); return nil
                case "l": if self.view.mini { self.toggleMini() }; self.view.revealCurrent(); return nil
                case "i": self.view.editSelection(); return nil
                case "f": self.focusSearch(); return nil
                case "a": if !(self.window.firstResponder is NSTextView) { self.view.selectAllTracks(); return nil }
                case "1", "2", "3": self.view.setMode([0, 3, 2][Int(event.charactersIgnoringModifiers!)! - 1]); return nil
                default: break
                }
            }
            if event.keyCode == 53 && self.view.showingVideo && self.window.styleMask.contains(.fullScreen) { self.window.toggleFullScreen(nil); return nil }
            if self.window.firstResponder is NSTextView { return event }
            if self.view.routeSelectionKey(event) { return nil }
            if self.window.firstResponder === self.view.table, [UInt16(123),124,125,126].contains(event.keyCode), !event.modifierFlags.contains(.control) { return event }
            if event.keyCode == 49 { self.view.toggle(); return nil }
            if event.keyCode == 123 || event.keyCode == 124 {
                // Let macOS handle Control/Fn window placement and desktop shortcuts.
                if event.modifierFlags.contains(.control) { return event }
                let direction = event.keyCode == 123 ? -1 : 1
                if self.view.mode == 2 && !self.view.mini && !event.modifierFlags.contains(.option) { self.view.stage.step(direction) }
                else { self.view.library.step(direction) }
                return nil
            }
            if event.keyCode == 36 { self.view.playSelected(); return nil }
            return event
        }
        NSApp.activate(ignoringOtherApps: true)
        if snapshot {
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--mode"), args.indices.contains(i + 1), let mode = Int(args[i + 1]) { view.setMode(mode) }
            if args.contains("--lyrics-demo") {
                var demo = Track(id:"lyrics-preview",title:"Пример синхронного текста",artist:"Локальная проверка",album:"Панель текста",genre:"—",duration:60,number:1)
                demo.lyrics = "[00:00.00]Первая строка следует за музыкой\n[00:05.00]Текущая строка выделяется синим\n[00:10.00]Остальной текст остаётся спокойным\n[00:15.00]Можно прокрутить и вернуться к песне"
                library.tracks = [demo]; library.currentID = demo.id; self.view.refresh(); self.view.toggleLyrics()
            }
            if args.contains("--android-sync-panel") { self.syncAndroid() }
            if args.contains("--hover") { view.setTrafficHovered(true) }
            if args.contains("--mini") { self.toggleMini() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.view.layoutSubtreeIfNeeded()
                let captured = self.androidSyncWindow?.window?.contentView ?? self.view!
                guard let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1), let bitmap = captured.bitmapImageRepForCachingDisplay(in: captured.bounds) else { NSApp.terminate(nil); return }
                captured.cacheDisplay(in: captured.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
                NSApp.terminate(nil)
            }
        } else { NSApp.activate(ignoringOtherApps: true) }
    }
    func toggleMini() {
        changingWindowMode = true
        defer { changingWindowMode = false; saveWindowPlacement() }
        window.minSize = .zero
        if view.mini {
            view.mini = false
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarSeparatorStyle = .none; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            window.isOpaque = true; window.backgroundColor = .windowBackgroundColor
            window.maxSize = NSSize(width: 10000, height: 10000)
            window.minSize = NSSize(width: 1000, height: 620)
            for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(type)?.isHidden = true }
            if let frame = fullFrame { window.setFrame(frame, display: true) }
        } else {
            fullFrame = window.frame; view.mini = true
            let origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - 64)
            window.styleMask = [.borderless, .closable, .miniaturizable, .resizable]
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
            window.minSize = NSSize(width: 360, height: 64); window.maxSize = NSSize(width: 600, height: 64)
            window.setFrame(NSRect(origin: origin, size: NSSize(width: 360, height: 64)), display: true)
        }
        updateMiniLevel()
        view.needsLayout = true; view.layoutSubtreeIfNeeded(); view.updateTrackingAreas(); view.needsDisplay = true
        window.makeKeyAndOrderFront(nil)
    }
    private func saveWindowPlacement() {
        guard !changingWindowMode, !fullScreenTransition, previewStorage == nil, let window, let view, !window.styleMask.contains(.fullScreen) else { return }
        if let frame = view.mini ? fullFrame : window.frame { WindowPlacement.save(frame, defaults: .standard) }
    }
    func windowDidResize(_ notification: Notification) { saveWindowPlacement() }
    func windowDidMove(_ notification: Notification) { saveWindowPlacement() }
    func windowWillEnterFullScreen(_ notification: Notification) { saveWindowPlacement(); fullScreenTransition = true }
    func windowDidEnterFullScreen(_ notification: Notification) { view.needsLayout = true }
    func windowDidExitFullScreen(_ notification: Notification) { fullScreenTransition = false; view.needsLayout = true; saveWindowPlacement() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { fullScreenTransition = false; saveWindowPlacement() }
    func windowDidBecomeKey(_ notification: Notification) { redrawWindowState() }
    func windowDidResignKey(_ notification: Notification) { view?.stage.clearScrub(); view?.setTrafficHovered(false); redrawWindowState() }
    private func redrawWindowState() {
        view?.refreshTrafficHover()
        if window?.isKeyWindow == false { for key in ["close", "minimize", "zoom"] { view?.buttons[key]?.highlight(false) } }
        view?.needsDisplay = true
        view?.buttons.values.forEach { $0.needsDisplay = true }
    }
    func applicationWillTerminate(_ notification: Notification) {
        saveWindowPlacement()
        view?.library.stopPlayback(); view?.library.systemMedia?.finish(); view?.library.flushPendingSave()
        if let previewStorage { try? FileManager.default.removeItem(at: previewStorage.deletingLastPathComponent()) }
    }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func createMenu() {
        let menu = NSMenu(); let app = NSMenuItem(); let appMenu = NSMenu(); app.submenu = appMenu; menu.addItem(app)
        appMenu.addItem(withTitle: "Об iTunes", action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Настройки…", action: #selector(showPlaybackPreferences), keyEquivalent: ",").target = self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "Завершить iTunes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenuItem(); file.title = "Файл"; let fileMenu = NSMenu(title: "Файл"); file.submenu = fileMenu; menu.addItem(file)
        fileMenu.addItem(withTitle: "Добавить музыку и видеоклипы…", action: #selector(importFiles), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: "Добавить медиатеку…", action: #selector(importLibrary), keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: "Синхронизировать с Android…", action: #selector(syncAndroid), keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: "Информация…", action: #selector(editInfo), keyEquivalent: "i").target = self
        fileMenu.addItem(withTitle: "Новый плейлист…", action: #selector(newPlaylist), keyEquivalent: "n").target = self
        let edit = NSMenuItem(); edit.title = "Правка"; let editMenu = NSMenu(title: "Правка"); edit.submenu = editMenu; menu.addItem(edit)
        for (name, selector, key) in [("Отменить", Selector(("undo:")), "z"), ("Вырезать", #selector(NSText.cut(_:)), "x"), ("Копировать", #selector(NSText.copy(_:)), "c"), ("Вставить", #selector(NSText.paste(_:)), "v"), ("Выбрать всё", #selector(NSText.selectAll(_:)), "a")] { editMenu.addItem(withTitle: name, action: selector, keyEquivalent: key) }
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Найти в медиатеке", action: #selector(focusSearch), keyEquivalent: "f").target = self
        let viewItem = NSMenuItem(title: "Вид", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "Вид"); viewItem.submenu = viewMenu; menu.addItem(viewItem)
        viewMenu.addItem(withTitle: "Показать / скрыть текст песни", action: #selector(toggleLyrics), keyEquivalent: "y").target = self
        let sortItem = NSMenuItem(title: "Сортировка", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu(title: "Сортировка"); sortMenu.identifier = NSUserInterfaceItemIdentifier("library-sort"); sortMenu.delegate = self
        sortItem.submenu = sortMenu; viewMenu.addItem(sortItem)
        let windowItem = NSMenuItem(title: "Окно", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Окно")
        windowItem.submenu = windowMenu; menu.addItem(windowItem)
        windowMenu.addItem(withTitle: "Свернуть", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Изменить масштаб", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Все окна — на передний план", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        // AppKit supplies native placement/full-screen commands and the window list.
        NSApp.windowsMenu = windowMenu
        let help = NSMenuItem(); help.title = "Справка"; let helpMenu = NSMenu(title: "Справка"); help.submenu = helpMenu; menu.addItem(help)
        helpMenu.addItem(withTitle: "Управление iTunes", action: #selector(showHelp), keyEquivalent: "").target = self
        func observe(_ menu: NSMenu) {
            menu.delegate = self
            for item in menu.items { if let submenu = item.submenu { observe(submenu) } }
        }
        observe(menu)
        NSApp.mainMenu = menu
    }
    @objc func syncAndroid() {
        if androidSyncWindow == nil { let controller=AndroidSyncWindow(library:view.library); controller.onClose={ [weak self] in self?.androidSyncWindow=nil }; androidSyncWindow=controller }
        androidSyncWindow?.showWindow(nil); androidSyncWindow?.window?.makeKeyAndOrderFront(nil)
    }
    func menuWillOpen(_ menu: NSMenu) { openMenus.insert(ObjectIdentifier(menu)) }
    func menuDidClose(_ menu: NSMenu) { openMenus.remove(ObjectIdentifier(menu)) }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.identifier?.rawValue == "library-sort" else { return }
        let snapshot = view.sorting.primary.rawValue + ":" + (view.sorting.secondary?.rawValue ?? "none") + ":" + String(view.sorting.ascending) + ":" + String(view.sorting.yearAscending)
        guard menu.numberOfItems == 0 || sortMenuSnapshot != snapshot else { return }
        sortMenuSnapshot = snapshot
        menu.removeAllItems()
        for field in LibrarySortField.allCases {
            let item = NSMenuItem(title: field.label, action: #selector(sortPrimary(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = field.rawValue; item.state = view.sorting.primary == field ? .on : .off; menu.addItem(item)
        }
        menu.addItem(.separator())
        let extra = NSMenuItem(title: "Дополнительно", action: nil, keyEquivalent: "")
        let extraMenu = NSMenu(title: "Дополнительно")
        let none = NSMenuItem(title: "Без дополнительного критерия", action: #selector(sortSecondary(_:)), keyEquivalent: "")
        none.target = self; none.state = view.sorting.secondary == nil ? .on : .off; extraMenu.addItem(none)
        for field in LibrarySortField.allCases {
            let item = NSMenuItem(title: field.label, action: #selector(sortSecondary(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = field.rawValue; item.state = view.sorting.secondary == field ? .on : .off
            item.isEnabled = field != view.sorting.primary; extraMenu.addItem(item)
        }
        extraMenu.delegate = self; extraMenu.autoenablesItems = false; extra.submenu = extraMenu; menu.addItem(extra)
        if view.sorting.primary != .year && view.sorting.secondary == .year {
            let year = NSMenuItem(title: "Порядок года внутри групп", action: nil, keyEquivalent: "")
            let directions = NSMenu(title: year.title)
            for (title, ascending) in [("Сначала ранние альбомы", true), ("Сначала новые альбомы", false)] {
                let item = NSMenuItem(title: title, action: #selector(sortYearDirection(_:)), keyEquivalent: "")
                item.target = self; item.tag = ascending ? 1 : 0; item.state = view.sorting.yearAscending == ascending ? .on : .off; directions.addItem(item)
            }
            year.submenu = directions; menu.addItem(year)
        }
        menu.addItem(.separator())
        for (title, ascending) in [("По возрастанию", true), ("По убыванию", false)] {
            let item = NSMenuItem(title: title, action: #selector(sortDirection(_:)), keyEquivalent: "")
            item.target = self; item.tag = ascending ? 1 : 0; item.state = view.sorting.ascending == ascending ? .on : .off; menu.addItem(item)
        }
    }
    @objc private func sortPrimary(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let field = LibrarySortField(rawValue: raw) else { return }
        view.changeSort(primary: field)
    }
    @objc private func sortSecondary(_ item: NSMenuItem) {
        let field = (item.representedObject as? String).flatMap(LibrarySortField.init(rawValue:))
        view.changeSort(secondary: field, clearSecondary: field == nil)
    }
    @objc private func sortYearDirection(_ item: NSMenuItem) { view.changeSort(yearAscending: item.tag == 1) }
    @objc private func sortDirection(_ item: NSMenuItem) { view.changeSort(ascending: item.tag == 1) }
    static func applyMiniLevel(_ window: NSWindow, mini: Bool, defaults: UserDefaults) {
        let floating = mini && defaults.bool(forKey: "MiniPlayerAlwaysOnTop")
        window.level = floating ? .floating : .normal
        window.collectionBehavior = floating ? [.canJoinAllSpaces, .fullScreenAuxiliary] : mini ? [.managed, .fullScreenAuxiliary] : [.managed, .fullScreenPrimary]
    }
    func updateMiniLevel() { Self.applyMiniLevel(window, mini: view.mini, defaults: .standard) }
    @objc func showPlaybackPreferences() {
        if playbackPreferences == nil {
            let controller = PlaybackPreferences(library: view.library)
            controller.onMiniLevelChange = { [weak self] in self?.updateMiniLevel() }
            controller.onClose = { [weak self] in self?.playbackPreferences = nil }; playbackPreferences = controller
        }
        playbackPreferences?.reload(); playbackPreferences?.showWindow(nil); playbackPreferences?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func focusSearch() {
        if view.mini { toggleMini() }
        window.makeKeyAndOrderFront(nil); view.layoutSubtreeIfNeeded(); window.makeFirstResponder(view.search)
    }
    @objc func editInfo() { view.editSelection() }
    @objc func importLibrary() { view.importLibrary() }
    @objc func importFiles() { view.importFiles() }
    @objc func newPlaylist() { view.createPlaylist() }
    @objc func toggleLyrics() { view.toggleLyrics() }
    @objc func about() {
        if aboutWindow == nil { let controller = ClassicAboutWindow(); controller.onClose = { [weak self] in self?.aboutWindow = nil }; aboutWindow = controller }
        aboutWindow?.showWindow(nil); aboutWindow?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func showHelp() {
        let alert = NSAlert(); alert.messageText = "Управление iTunes"
        alert.informativeText = "⌘O — добавить файлы или папку\nПробел — воспроизведение / пауза\n← / → — альбомы в Cover Flow\n⌥← / ⌥→ — предыдущий / следующий трек\n⌘L — текущая композиция\n⌘F — поиск · ⌘1–3 — список, сетка, Cover Flow\n\nПрокрутка или нижний ползунок — пролистывание альбомов. Двойной щелчок по обложке — воспроизведение. Зелёная кнопка окна — мини-плеер."
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") { alert.icon = NSImage(contentsOf: url) }
        alert.beginSheetModal(for: window)
    }
    func selfTest() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("iTunes-test-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let library = Library(storage: root.appendingPathComponent("library.json"))
            precondition(library.tracks.isEmpty && library.playlists.isEmpty)
            let file = root.appendingPathComponent("Test Tone.wav"); try Self.testAudio().write(to: file)
            let first = await library.importURLs([file]); precondition(first.0 == 1 && first.1 == 0)
            let second = await library.importURLs([file]); precondition(second.0 == 0)
            testRefinements(track: library.tracks[0], root: root)
            testPlaybackQueue(track: library.tracks[0], storage: root.appendingPathComponent("queue.json"))
            MetadataEditor.testAquaEditor(track: library.tracks[0], storage: root.appendingPathComponent("aqua-editor.json"))
            try await testAndroidSync(track: library.tracks[0], root: root)
            testLocalLyrics(track: library.tracks[0], root: root)
            try await testAnimatedLyrics(track: library.tracks[0], root: root)
            try await testLyricsService(root: root)
            testSelectionAndYearSort(track: library.tracks[0], root: root)
            try await testCrossfade(track: library.tracks[0], root: root)
            var edit = MetadataPatch(); edit.fields = [.genre: "Edited genre", .composer: "Edited composer", .year: "2026"]
            try library.apply(edit, to: [library.tracks[0].id])
            library.playlists["Keep"] = [library.tracks[0].id]; library.save()
            let loaded = Library(storage: root.appendingPathComponent("library.json"))
            precondition(loaded.tracks.count == 1 && loaded.tracks[0].genre == "Edited genre" && loaded.tracks[0].composer == "Edited composer" && loaded.playlists["Keep"] == [loaded.tracks[0].id])
            var albumTracks = [
                Track(id: "solo", title: "Solo", artist: "Artist", album: "Release", genre: "Pop", duration: 1, number: 1, path: "/Music/Artist/Release/1.aiff"),
                Track(id: "guest", title: "Duet", artist: "Artist & Guest", album: "Release", genre: "Pop", duration: 1, number: 2, path: "/Music/Artist/Release/2.aiff"),
                Track(id: "other", title: "Other", artist: "Other Artist", album: "Release", genre: "Pop", duration: 1, number: 1, path: "/Music/Other/Release/1.aiff")
            ]
            Library.reconcileAlbumArtists(&albumTracks)
            precondition(albumTracks[0].albumKey == albumTracks[1].albumKey && albumTracks[0].albumKey != albumTracks[2].albumKey)
            precondition(albumTracks[1].artist == "Artist & Guest")
            // Verify that cleanup only removes known built-in entries with no audio-file path.
            let oldEntry = Track(id: "demo-0-0", title: "Legacy", artist: "Legacy", album: "Legacy", genre: "—", duration: 30, number: 1)
            let oldPath = root.appendingPathComponent("old.json")
            try JSONEncoder().encode(SavedLibrary(tracks: [oldEntry, loaded.tracks[0]], playlists: ["Keep": [oldEntry.id, loaded.tracks[0].id]], albumMetadataVersion: 1)).write(to: oldPath)
            let cleaned = Library(storage: oldPath)
            precondition(cleaned.tracks.map(\.id) == loaded.tracks.map(\.id))
            precondition(cleaned.playlists["Keep"] == loaded.tracks.map(\.id))
            precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.before-0.3.json").path))
            let ui = PlayerView(library: loaded); ui.frame.size = NSSize(width: 1160, height: 760); ui.layoutSubtreeIfNeeded()
            precondition(ui.stage.renderedCoverCount == 0)
            ui.setMode(2); ui.layoutSubtreeIfNeeded(); precondition(ui.stage.renderedCoverCount == 1); ui.setMode(3)
            ui.stage.gridGroups = [LibraryGroup(key: "test", title: "Album", subtitle: "Artist", tracks: albumTracks)]
            let stage = ui.stage
            let columns = max(1, Int(stage.bounds.width / (stage.tileSize + 48)))
            let start = (stage.bounds.width / CGFloat(columns) - stage.tileSize) / 2
            stage.scrub(at: NSPoint(x: start + stage.tileSize - 1, y: 30))
            precondition(stage.scrubbedTrack == albumTracks.count - 1 && library.player == nil)
            stage.scrub(at: NSPoint(x: start + 1, y: 30)); precondition(stage.scrubbedTrack == 0)
            stage.scrub(at: NSPoint(x: start + 1, y: 0)); precondition(stage.scrubbedTrack == nil)

            ui.query = "no match"; ui.refresh(); precondition(ui.rows.isEmpty)
            ui.query = ""; ui.refresh(); precondition(ui.rows.count == 1)
            ui.source = "Keep"; ui.refresh(); precondition(ui.rows.count == 1)
            ui.setMode(3); precondition(ui.stage.albums.count == 1); ui.timer?.invalidate()
            precondition(PlayerView.groups(loaded.tracks, by: .genres).first?.title == "Edited genre")
            let media = SystemMedia(loaded); loaded.systemMedia = media
            loaded.play(loaded.tracks[0], within: loaded.tracks); media.update()
            let center = MPNowPlayingInfoCenter.default()
            precondition(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == loaded.tracks[0].title)
            precondition(center.playbackState == .playing)
            loaded.toggle(loaded.tracks); media.update(); precondition(center.playbackState == .paused)
            loaded.player?.currentTime = 0.05; media.update()
            precondition(abs((center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? -1) - 0.05) < 0.01)
            media.finish(); loaded.player?.stop(); loaded.flushPendingSave(); precondition(center.nowPlayingInfo == nil)

            var batch = MetadataPatch(); batch.fields = [.album: "Renamed", .genre: "Electronic"]
            let batchLibrary = Library(storage: root.appendingPathComponent("batch.json")); batchLibrary.tracks = albumTracks
            try batchLibrary.apply(batch, to: ["solo", "guest"])
            precondition(batchLibrary.tracks[1].artist == "Artist & Guest" && batchLibrary.tracks[1].album == "Renamed")
            precondition(batchLibrary.tracks[2].album == "Release")
            // Migrate a legacy manifest, deduplicate artwork, retain IDs and edits, and
            // prove that a cancelled delayed play-count save cannot undo a metadata edit.
            let legacyFolder = root.appendingPathComponent("artwork-migration")
            try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
            let legacyURL = legacyFolder.appendingPathComponent("library.json")
            let artURL = Bundle.main.url(forResource: "genre-pop", withExtension: "jpg", subdirectory: "GenreArtwork")!
            let coverBytes = try Data(contentsOf: artURL)
            var legacyTracks = albumTracks
            for i in legacyTracks.indices { legacyTracks[i].artwork = coverBytes; legacyTracks[i].plays = 9 }
            let legacyBytes = try JSONEncoder().encode(SavedLibrary(tracks: legacyTracks, playlists: ["Keep": ["guest"]], albumMetadataVersion: 3))
            try legacyBytes.write(to: legacyURL)
            let artLibrary = Library(storage: legacyURL)
            precondition(artLibrary.needsArtworkMigration)
            artLibrary.saveInBackground()
            for _ in 0..<100 { if !artLibrary.needsArtworkMigration { break }; try await Task.sleep(nanoseconds: 20_000_000) }
            precondition(!artLibrary.needsArtworkMigration)
            precondition(artLibrary.tracks.allSatisfy { $0.artwork == nil && $0.artworkData == coverBytes && $0.plays == 9 })
            let manifest = try Data(contentsOf: legacyURL)
            precondition(manifest.count < legacyBytes.count / 2)
            let backup = try Data(contentsOf: legacyFolder.appendingPathComponent("library.before-0.16.json"))
            precondition(backup == legacyBytes)
            let artworkFiles = try FileManager.default.contentsOfDirectory(at: legacyFolder.appendingPathComponent("Artwork"), includingPropertiesForKeys: nil)
            precondition(artworkFiles.count == 1)
            artLibrary.tracks[0].plays += 1; artLibrary.saveInBackground()
            var raceEdit = MetadataPatch(); raceEdit.fields = [.genre: "Newest edit"]
            try artLibrary.apply(raceEdit, to: ["solo"])
            try await Task.sleep(nanoseconds: 350_000_000)
            let artReloaded = Library(storage: legacyURL)
            precondition(artReloaded.tracks[0].genre == "Newest edit" && artReloaded.tracks[0].plays == 10)
            precondition(artReloaded.playlists["Keep"] == ["guest"] && artReloaded.tracks.map(\.id) == legacyTracks.map(\.id))
            var removeArt = MetadataPatch(); removeArt.artwork = .remove
            try artLibrary.apply(removeArt, to: ["solo"])
            precondition(artLibrary.tracks[0].artworkData == nil && artLibrary.tracks[0].artworkPath == nil)
            var replaceArt = MetadataPatch(); replaceArt.artwork = .replace(coverBytes)
            try artLibrary.apply(replaceArt, to: ["solo"])
            precondition(artLibrary.tracks[0].artworkData == coverBytes)
            Covers.invalidate(); _ = Covers.image(artLibrary.tracks[0])
            for _ in 0..<100 { if Covers.cached(artLibrary.tracks[0]) != nil { break }; try await Task.sleep(nanoseconds: 20_000_000) }
            precondition(Covers.cached(artLibrary.tracks[0]) != nil && Covers.cached(artLibrary.tracks[0])!.size.width <= 512)
            let flow = AlbumStage(frame: NSRect(x: 0, y: 0, width: 1000, height: 350)); flow.grid = true
            flow.albums = (0..<200).map { Track(id: "flow-\($0)", title: "Song", artist: "Artist", album: "Album \($0)", genre: "Pop", duration: 1, number: 1) }
            precondition(flow.renderedCoverCount == 0)
            flow.grid = false; flow.layoutSubtreeIfNeeded(); flow.selected = 100
            precondition(flow.renderedCoverCount > 0 && flow.renderedCoverCount <= 21)
            flow.grid = true; precondition(flow.renderedCoverCount == 0)
            print("PASS: external artwork migration, exact backup, deduplication, preserved IDs/playlists/plays, autosave/edit ordering, artwork remove/replace, async thumbnail, bounded Cover Flow")
            let drawerStage = AlbumStage(frame: NSRect(x: 0, y: 0, width: 1000, height: 600)); drawerStage.grid = true
            var drawerTracks = (0..<17).map { Track(id: "drawer-\($0)", title: "Song \($0)", artist: "Artist", album: "Drawer album", genre: "Pop", duration: 60, number: $0 + 1) }
            drawerTracks[0].discNumber = 2
            let drawerGroups = (0..<7).map { i in LibraryGroup(key: "drawer-group-\(i)", title: "Album \(i)", subtitle: "Artist", tracks: i == 0 ? drawerTracks : [drawerTracks[1]]) }
            drawerStage.gridGroups = drawerGroups
            let cleanUI = PlayerView(library: library)
            precondition(cleanUI.buttons["import"] == nil && cleanUI.buttons["import-library"] == nil)
            cleanUI.mode = 3; cleanUI.stage.grid = true; cleanUI.stage.gridGroups = drawerGroups
            cleanUI.stage.toggleDrawer(at: 0, animated: false)
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            precondition(cleanUI.routeSelectionKey(escape))
            try await Task.sleep(nanoseconds: 320_000_000)
            precondition(cleanUI.stage.expandedKey == nil)
            let controls = cleanUI.videoControls; controls.frame = NSRect(x: 0, y: 0, width: 1000, height: 52); controls.layoutSubtreeIfNeeded()
            precondition(!controls.seek.frame.intersects(controls.volume.frame))
            cleanUI.timer?.invalidate()
            print("PASS: Escape closes grid drawer, import commands have no duplicate buttons, inline video slider geometry")
            let originalY = drawerStage.tileRect(at: 5).minY
            drawerStage.toggleDrawer(at: 0, animated: false)
            precondition(drawerStage.expandedKey == drawerGroups[0].key && drawerStage.drawer.rows.count == 17)
            precondition(drawerStage.drawer.orderedTracks.last?.id == drawerTracks[0].id)
            precondition(drawerStage.tileRect(at: 5).minY == originalY + drawerStage.drawerExpansion)
            precondition(drawerStage.gridIndex(at: NSPoint(x: 100, y: drawerStage.drawer.frame.midY)) == nil)
            let shifted = drawerStage.tileRect(at: 5); precondition(drawerStage.gridIndex(at: NSPoint(x: shifted.midX, y: shifted.midY)) == 5)
            var playedIDs: [String] = []
            drawerStage.onPlayTracks = { _, queue in playedIDs = queue.map(\.id) }
            drawerStage.drawer.playAlbum(); precondition(playedIDs == drawerStage.drawer.orderedTracks.map(\.id))
            drawerStage.drawer.playAlbum(shuffle: true); precondition(Set(playedIDs) == Set(drawerTracks.map(\.id)))
            drawerStage.toggleDrawer(at: 0, animated: false); precondition(drawerStage.expandedKey == nil && drawerStage.drawerExpansion == 0)
            drawerStage.toggleDrawer(at: 0, animated: false); drawerStage.gridGroups.reverse()
            precondition(drawerStage.expandedKey == drawerGroups[0].key && drawerStage.selected == 6)
            drawerStage.gridGrouping = .artists; precondition(drawerStage.expandedKey == nil)
            drawerStage.gridGrouping = .albums; drawerStage.gridGroups = drawerGroups
            drawerStage.toggleDrawer(at: 0, animated: false)
            let wideHeight = drawerStage.drawerExpansion
            drawerStage.frame.size.width = 600; drawerStage.layoutSubtreeIfNeeded(); precondition(drawerStage.drawerExpansion > wideHeight)
            drawerStage.gridGroups = Array(drawerGroups.dropFirst()); precondition(drawerStage.expandedKey == nil)
            drawerStage.toggleDrawer(at: 0); drawerStage.closeDrawer()
            try await Task.sleep(nanoseconds: 320_000_000); precondition(drawerStage.expandedKey == nil && drawerStage.drawerExpansion == 0)
            let autoScroll = NSScrollView(frame: NSRect(x: 0,y: 0,width: 1000,height: 300))
            let autoStage = AlbumStage(frame: NSRect(x: 0,y: 0,width: 1000,height: 600)); autoStage.grid = true; autoStage.gridGroups = drawerGroups; autoScroll.documentView = autoStage
            autoScroll.contentView.scroll(to: .zero); autoStage.toggleDrawer(at: 6)
            try await Task.sleep(nanoseconds: 80_000_000)
            let midway = autoScroll.contentView.bounds.origin.y
            precondition(midway > 0 && autoStage.drawerExpansion > 0, "Scrolling must start during expansion, not jump at completion")
            try await Task.sleep(nanoseconds: 240_000_000)
            precondition(autoScroll.contentView.bounds.origin.y >= midway && autoStage.expandedKey == drawerGroups[6].key)
            let slider = AquaSlider(frame: NSRect(x: 0,y: 0,width: 280,height: 28)); slider.ticked = true
            slider.setAccessibilityValue(NSNumber(value: 0.65)); precondition(abs(slider.value - 0.65) < 0.001)
            let aboutUI = ClassicAboutWindow(); precondition(aboutUI.window?.contentView is ClassicWindowChrome)
            let prefsUI = PlaybackPreferences(library: library); precondition(prefsUI.window?.contentView is ClassicWindowChrome && prefsUI.seconds.ticked)
            print("PASS: simultaneous album expansion/scrolling, ticked slider accessibility, shared classic About/preferences chrome")
            for hex: UInt32 in [0x000000, 0xFFFFFF, 0x777777, 0x808080, 0x00FF00, 0xFF00FF, 0x2369B8] {
                let cg = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                cg.setFillColor(color(hex).cgColor); cg.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
                precondition(AlbumPalette.extract(cg.makeImage()!).textContrast >= 4.5)
            }
            print("PASS: inline album drawer open/close, shifted hit testing, disc order, play/shuffle queues, selection after sorting, grouping/filter cleanup, responsive height, interrupted animation and palette contrast")
            let before = batchLibrary.tracks
            var invalid = MetadataPatch(); invalid.fields = [.year: "not a year"]
            do { try batchLibrary.apply(invalid, to: ["solo"]); preconditionFailure("Expected validation failure") } catch {}
            precondition(batchLibrary.tracks == before)
            let blocker = root.appendingPathComponent("blocker"); try Data().write(to: blocker)
            let unwritable = Library(storage: blocker.appendingPathComponent("library.json")); unwritable.tracks = albumTracks
            do { try unwritable.apply(batch, to: ["solo"]); preconditionFailure("Expected write failure") } catch {}
            precondition(unwritable.tracks == albumTracks)
            let unchangedAudio = try Data(contentsOf: file); precondition(unchangedAudio == Self.testAudio())
            precondition(ImportedMetadata.genre("(17)") == "Rock")
            if let i = CommandLine.arguments.firstIndex(of: "--fixtures"), CommandLine.arguments.indices.contains(i + 1) {
                let tagLibrary = Library(storage: root.appendingPathComponent("tags.json"))
                let result = await tagLibrary.importURLs([URL(fileURLWithPath: CommandLine.arguments[i + 1])])
                precondition(result.0 == 3 && tagLibrary.tracks.count == 3)
                precondition(tagLibrary.tracks.allSatisfy { $0.albumDisplayArtist == "Fixture Artist" })
                precondition(Set(tagLibrary.tracks.map(\.albumKey)).count == 1)
                precondition(Set(tagLibrary.tracks.map(\.artist)).count > 1)
                precondition(tagLibrary.tracks.allSatisfy { $0.genre == "Pop" && $0.year == 2004 && $0.composer == "Fixture Composer" })
                precondition(tagLibrary.tracks.allSatisfy { $0.number == 2 && $0.trackTotal == 8 && $0.discNumber == 1 && $0.discTotal == 2 })
                var custom = MetadataPatch(); custom.fields = [.genre: "My genre"]
                try tagLibrary.apply(custom, to: [tagLibrary.tracks[0].id])
                let outdated = SavedLibrary(tracks: tagLibrary.tracks, playlists: [:], albumMetadataVersion: 1)
                try JSONEncoder().encode(outdated).write(to: tagLibrary.storage)
                let migrated = Library(storage: tagLibrary.storage); await migrated.upgradeAlbumMetadata()
                precondition(migrated.tracks[0].genre == "My genre" && migrated.tracks[1].genre == "Pop")
            }
            if let i = CommandLine.arguments.firstIndex(of: "--video-fixtures"), CommandLine.arguments.indices.contains(i + 1) {
                let clips = Library(storage: root.appendingPathComponent("clips.json"))
                let folder = URL(fileURLWithPath: CommandLine.arguments[i + 1])
                let imported = await clips.importURLs([folder])
                precondition(imported.0 == 2 && clips.tracks.filter { $0.isVideo }.count == 1)
                let duplicate = await clips.importURLs([folder]); precondition(duplicate.0 == 0)
                let clip = clips.tracks.first { $0.isVideo }!; precondition(clip.artworkData != nil)
                let videoUI = PlayerView(library: clips); videoUI.source = "Видеоклипы"; videoUI.refresh()
                precondition(videoUI.rows.count == 1 && videoUI.rows[0].id == clip.id)
                videoUI.source = "Музыка"; videoUI.refresh(); precondition(videoUI.rows.count == 1 && !videoUI.rows[0].isVideo)
                clips.play(clip, within: [clip])
                for _ in 0..<50 { if clips.videoPlayer?.currentItem?.status != .unknown { break }; try await Task.sleep(nanoseconds: 100_000_000) }
                precondition(clips.videoPlayer?.currentItem?.status == .readyToPlay && clips.player == nil)
                clips.toggle([]); precondition(!clips.playing)
                clips.seek(to: 2); try await Task.sleep(nanoseconds: 300_000_000); precondition(abs(clips.playbackTime - 2) < 0.2)
                let currentPlayer=clips.videoPlayer!
                videoUI.refreshPlayback(); videoUI.layoutSubtreeIfNeeded(); precondition(videoUI.showingVideo)
                videoUI.browseWhileVideoPlays(); videoUI.layoutSubtreeIfNeeded()
                precondition(!videoUI.showingVideo && !videoUI.buttons["return-video"]!.isHidden)
                clips.enqueue([clips.tracks.first { !$0.isVideo }!],next:false)
                for _ in 0..<3 {
                    videoUI.showCurrentVideo(); videoUI.layoutSubtreeIfNeeded()
                    precondition(videoUI.showingVideo && videoUI.videoView.player === currentPlayer && clips.videoPlayer === currentPlayer)
                    precondition(!clips.playing && abs(clips.playbackTime-2) < 0.2 && videoUI.buttons["return-video"]!.isHidden)
                    videoUI.browseWhileVideoPlays()
                }
                videoUI.revealCurrent(); precondition(videoUI.showingVideo && clips.videoPlayer === currentPlayer)
                clips.play(clips.tracks.first { !$0.isVideo }!); precondition(clips.videoPlayer == nil && clips.player != nil)
                videoUI.refreshPlayback(); videoUI.layoutSubtreeIfNeeded(); precondition(videoUI.buttons["return-video"]!.isHidden && !videoUI.showCurrentVideo())
                clips.stopPlayback(); clips.flushPendingSave(); videoUI.timer?.invalidate()
                let restored = Library(storage: clips.storage); precondition(restored.tracks.filter { $0.isVideo }.count == 1)
                print("PASS: recursive mixed media import, duplicates, poster, video/music filters, embedded playback, video seek/pause, close/browse/queue/return preserving player and time, audio handoff, persistence")
            }
            for (tag, name) in [("Pop", "genre-pop"), ("pop", "genre-pop"), ("electronics", "genre-electronic"), ("Dance;Pop", "genre-dance"), ("Хип-хоп/Рэп", "genre-hiphop"), ("R&B/Soul", "genre-rb")] {
                precondition(LegacyAssets.genreName(tag) == name && LegacyAssets.genre(tag) != nil)
            }
            precondition(LegacyAssets.genre("unmapped custom genre") == nil)
            for icon in ["music", "movies", "smart-playlist", "playlist"] { precondition(LegacyAssets.icon(icon) != nil) }
            print("PASS: bundled legacy icons, genre artwork, aliases, composite tags, unknown genre fallback")
            let suite = "iTunes-sort-test-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var sortTracks = [
                Track(id: "sort10", title: "Track 10", artist: "Zulu", album: "Album 10", genre: "Rock", duration: 1, number: 1, year: 2020),
                Track(id: "sort2", title: "Track 2", artist: "Alpha", album: "Album 2", genre: "Pop", duration: 1, number: 1, year: 2000),
                Track(id: "unknown", title: "Unknown", artist: "Alpha", album: "Album 1", genre: "Pop", duration: 1, number: 1)
            ]
            var settings = LibrarySortSettings(primary: .year, secondary: .title, ascending: false)
            let testGroups = PlayerView.groups(sortTracks, by: .albums)
            precondition(settings.groups(testGroups, kind: .albums).map { $0.tracks[0].id } == ["sort10", "sort2", "unknown"])
            settings.ascending = true
            precondition(settings.groups(testGroups, kind: .albums).map { $0.tracks[0].id } == ["sort2", "sort10", "unknown"])
            settings.primary = .artist; settings.secondary = .year
            precondition(settings.groups(testGroups, kind: .albums).map { $0.tracks[0].id } == ["sort2", "unknown", "sort10"])
            settings.primary = .title; settings.secondary = nil
            precondition(settings.groups(testGroups, kind: .albums).map { $0.title } == ["Album 1", "Album 2", "Album 10"])
            sortTracks[0].sortAlbum = "Album 0"
            precondition(settings.groups(PlayerView.groups(sortTracks, by: .albums), kind: .albums).first?.tracks.first?.id == "sort10")
            let sortedLibrary = Library(storage: root.appendingPathComponent("sorted.json")); sortedLibrary.tracks = sortTracks
            let sortUI = PlayerView(library: sortedLibrary, sortDefaults: defaults)
            let selectedKey = sortUI.stage.gridGroups[sortUI.stage.selected].key
            sortUI.changeSort(primary: .artist, secondary: .year, ascending: false)
            precondition(sortUI.stage.gridGroups[sortUI.stage.selected].key == selectedKey)
            let persisted = LibrarySortSettings.load(defaults)
            precondition(persisted.primary == .artist && persisted.secondary == .year && !persisted.ascending)
            sortUI.changeSort(primary: .year); precondition(sortUI.sorting.secondary == nil)
            precondition(sortedLibrary.tracks == sortTracks); sortUI.timer?.invalidate()
            sortUI.setGridScale(0.83)
            let restoredScale = PlayerView(library: sortedLibrary, sortDefaults: defaults)
            precondition(abs(restoredScale.coverSize.value - 0.83) < 0.0001 && abs(restoredScale.stage.tileSize - 153.8) < 0.0001)
            precondition(restoredScale.sidebarArtworkRect.minX == 0 && restoredScale.sidebarArtworkRect.width == restoredScale.sidebarArtworkRect.height)
            precondition(restoredScale.sidebarArtworkRect.maxY == restoredScale.bounds.height - 24)
            let recentWidth = ("Недавно добавленные" as NSString).size(withAttributes: [.font: font(11, bold: true)]).width
            precondition(recentWidth <= restoredScale.sidebarWidth - 44)
            restoredScale.timer?.invalidate()
            for mini in [false, true] {
                for duration in [30.0, 3600.0, 72000.0] {
                    let rect = NSRect(x: 0, y: 0, width: mini ? 223 : 312, height: mini ? 46 : 40)
                    let metrics = LCDMetrics(rect: rect, mini: mini, total: duration)
                    precondition(!metrics.spectrum.intersects(metrics.elapsed) && !metrics.spectrum.intersects(metrics.duration) && !metrics.spectrum.intersects(metrics.progress))
                    precondition(metrics.progress.minX > metrics.elapsed.maxX && metrics.progress.maxX < metrics.duration.minX)
                    precondition(rect.contains(metrics.progress) && rect.contains(metrics.elapsed) && rect.contains(metrics.duration))
                }
            }
            var nav = CoverFlowScrollState(); nav.reset(to: 10)
            let half = nav.update(x: -70, y: 1, precise: true, phase: .began, momentum: [], timestamp: 1, presented: 10, count: 100)
            precondition(abs(half - 10.5) < 0.0001)
            let whole = nav.update(x: -70, y: 500, precise: true, phase: .changed, momentum: [], timestamp: 1.02, presented: 10, count: 100)
            precondition(abs(whole - 11) < 0.0001) // Ignore diagonal noise after locking the horizontal axis.
            let fingerUp = nav.update(x: 0, y: 0, precise: true, phase: .ended, momentum: [], timestamp: 1.03, presented: 11, count: 100)
            precondition(fingerUp == 12)
            for n in 0..<20 { precondition(nav.update(x:-1400,y:0,precise:true,phase:[],momentum:.changed,timestamp:1.04+Double(n)/100,presented:11,count:100) == fingerUp) }
            let snapped = nav.update(x: 0, y: 0, precise: true, phase: [], momentum: .ended, timestamp: 1.4, presented: 11, count: 100)
            precondition(snapped == 12)
            let reverse = nav.update(x: 140, y: 0, precise: true, phase: .began, momentum: [], timestamp: 2, presented: 12, count: 100)
            precondition(reverse == 11)
            nav.reset(to: 10)
            precondition(nav.update(x: 0, y: -100, precise: false, phase: [], momentum: [], timestamp: 3, presented: 10, count: 100) == 11)
            precondition(nav.update(x: 0, y: 100, precise: false, phase: [], momentum: [], timestamp: 4, presented: 11, count: 100) == 10)
            nav.reset(to: 0)
            precondition(nav.update(x: 140, y: 0, precise: true, phase: .began, momentum: [], timestamp: 5, presented: 0, count: 100) == 0)
            precondition(nav.update(x: -14000, y: 0, precise: true, phase: .began, momentum: [], timestamp: 6, presented: 98, count: 100) == 99)
            precondition(nav.update(x: -100, y: 0, precise: true, phase: .began, momentum: [], timestamp: 7, presented: 0, count: 0) == 0)
            sortUI.setMode(2); sortUI.layoutSubtreeIfNeeded()
            precondition(sortUI.tableScroll.isHidden && !sortUI.flowDetailScroll.isHidden && sortUI.flowDetail.standalone)
            precondition(sortUI.flowDetail.frame.height >= sortUI.flowDetailScroll.contentSize.height)
            precondition(sortUI.flowDetail.subviews.compactMap { $0 as? DrawerIconButton }.first { $0.kind == .close }!.isHidden)
            let target = sortUI.stage.albums.count - 1
            sortUI.stage.choose(target)
            for _ in 0..<80 { if sortUI.flowDetail.orderedTracks.first?.albumKey == sortUI.stage.albums[target].albumKey { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(sortUI.flowDetail.orderedTracks.first?.albumKey == sortUI.stage.albums[target].albumKey)
            precondition(sortUI.stage.renderedCoverCount <= 21)
            sortUI.query = "no match for flow"; sortUI.refresh(); precondition(sortUI.flowDetail.orderedTracks.isEmpty)
            sortUI.query = ""; sortUI.setMode(3); sortUI.layoutSubtreeIfNeeded(); precondition(sortUI.flowDetailScroll.isHidden && sortUI.stage.renderedCoverCount == 0)
            for target: CGFloat in [-10, -1, 1, 10] {
                precondition(CoverFlowGeometry.settledPosition(from: 0, to: target, elapsed: 0) == 0)
                precondition(CoverFlowGeometry.settledPosition(from: 0, to: target, elapsed: CoverFlowMotion.settleDuration) == target)
                precondition(CoverFlowGeometry.settledPosition(from: 0, to: target, elapsed: 1) == target)
            }
            // Independently project the two inner edges. They must stay apart at
            // every intermediate angle, including the exact half-album handoff.
            for size: CGFloat in [60, 180, 250] {
                for step in 0...1000 {
                    let t = CGFloat(step) / 1000
                    func edge(_ depth: CGFloat) -> CGFloat {
                        let angle = CoverFlowGeometry.angle(depth: depth)
                        let x = -size / 2 * cos(angle)
                        let z = -CoverFlowGeometry.recession(depth: depth) + size / 2 * sin(angle)
                        return CoverFlowGeometry.offset(distance: depth, size: size) + x / (1 - z / 850)
                    }
                    precondition(-edge(t) < edge(1 - t), "Central covers must never cross")
                }
            }
            var tail = CoverFlowScrollState(); tail.reset(to:10)
            var gestureMotion=CoverFlowMotion(); gestureMotion.reset(to:10)
            for i in 1...18 {
                let time=Double(i)/120
                let value=tail.update(x:-8,y:0,precise:true,phase:i == 1 ? .began : .changed,momentum:[],timestamp:time,presented:gestureMotion.position,count:100)
                gestureMotion.follow(value,at:time); gestureMotion.advance(at:time+1.0/240)
            }
            let released=19.0/120
            let destination=tail.update(x:0,y:0,precise:true,phase:.ended,momentum:[],timestamp:released,presented:gestureMotion.position,count:100)
            precondition(destination == 12 && tail.finishing)
            gestureMotion.settle(destination,at:released)
            var lastFrame=gestureMotion.position
            for frame in 1...24 {
                let time=released+Double(frame)/120
                let target=tail.update(x:-2000,y:0,precise:true,phase:[],momentum:.changed,timestamp:time,presented:gestureMotion.position,count:100)
                precondition(target == destination)
                gestureMotion.settle(target,at:time); gestureMotion.advance(at:time)
                precondition(gestureMotion.position >= lastFrame && gestureMotion.position <= destination)
                precondition(gestureMotion.position-lastFrame < 0.2)
                lastFrame=gestureMotion.position
            }
            precondition(gestureMotion.position == destination && gestureMotion.velocity == 0)
            precondition(tail.update(x:0,y:0,precise:true,phase:[],momentum:.ended,timestamp:1,presented:destination,count:100) == destination)
            let reversed=tail.update(x:14,y:0,precise:true,phase:.began,momentum:[],timestamp:1.1,presented:destination,count:100)
            precondition(reversed < destination && !tail.finishing)
            let hitStage = AlbumStage(frame: NSRect(x: 0, y: 0, width: 1000, height: 350))
            hitStage.albums = Array(flow.albums.prefix(3)); hitStage.layoutSubtreeIfNeeded()
            precondition(hitStage.flowIndex(at: NSPoint(x: 500, y: 177.5)) == 0)
            precondition(hitStage.flowIndex(at: NSPoint(x: 697.5, y: 177.5)) == 1)
            precondition(hitStage.flowIndex(at: NSPoint(x: 10, y: 10)) == nil)
            print("PASS: finite Cover Flow finish, continuous bounded momentum and non-crossing projected cover edges through the whole center exchange")
            print("PASS: Cover Flow axis lock, direction, bounded momentum, reversal, wheel steps, edge clamping, standalone album detail, selection sync, empty filters and grid transition")
            print("PASS: saved grid scale restored, full sidebar title, edge-to-edge artwork and non-overlapping LCD spectrum/time/seek geometry including long tracks")
            print("PASS: natural album order, year directions, missing years last, secondary criterion, sort tags, selected album, saved preferences, unchanged library")
            for mini in [false, true] {
                for kind: RetroButton.TrafficSymbol in [.close, .minimize, .zoom] {
                    for state in [(true, false, false), (true, true, false), (true, true, true), (false, true, true)] {
                        for edited in [false, true] {
                            precondition(TrafficLightArtwork.image(kind, mini: mini, active: state.0, hovered: state.1, pressed: state.2, edited: edited) != nil)
                        }
                    }
                    precondition(TrafficLightArtwork.image(kind, mini: mini, active: true, hovered: false, pressed: false, monochrome: true) != nil)
                }
            }
            print("PASS: bundled Snow Leopard traffic light states, mini variants, inactive and edited variants")
            print("PASS: Now Playing playback/pause/seek/cleanup, empty library, import, duplicates, metadata editing, mixed album fields, validation, atomic failure, source preservation, genres, import, duplicates, playlists, persistence, migration, filters")
        } catch { print("FAIL: \(error)"); exit(1) }
        NSApp.terminate(nil)
    }
    static func testAudio() -> Data {
        var data = Data()
        func ascii(_ value: String) { data.append(value.data(using: .ascii)!) }
        func u32(_ value: UInt32) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(44136); ascii("WAVEfmt "); u32(16); u16(1); u16(1); u32(22050); u32(44100); u16(2); u16(16); ascii("data"); u32(44100)
        data.append(Data(repeating: 0, count: 44100)); return data
    }

}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()

@MainActor func testLocalLyrics(track fixture: Track, root: URL) {
    precondition(LyricsPane.motionProgress(0) == 0 && LyricsPane.motionProgress(0.3) == 1)
    precondition(LyricsPane.motionProgress(0.1) > 0 && LyricsPane.motionProgress(0.1) < LyricsPane.motionProgress(0.2))
    var one = fixture; one.album = "One"; var two = fixture; two.id = "two"; two.album = "Two"
    precondition(PlayerView.librarySummary([one,one,two]).contains("3 песни · 2 альбома"))
    precondition(PlayerView.librarySummary([]) == "0 песен · 0 альбомов · 0 мин")
    let parsed = LyricDocument("[offset:+100]\r\n[00:02.50][00:04.500]Повтор\r\n[00:01.00]Раннее\n[00:03.00]\n[00:75.00]Неверное")
    precondition(parsed.lines.map(\.text) == ["Раннее","Повтор","","Повтор"])
    precondition(abs(parsed.lines[1].time - 2.6) < 0.001 && parsed.index(at:0) == nil && parsed.index(at:3.2) == 2 && parsed.index(at:99) == 3)
    precondition(LyricDocument("Обычный\nТекст").plain == "Обычный\nТекст")
    let library = Library(storage:root.appendingPathComponent("lyrics.json"))
    var track = fixture; track.id = "lyrics-test"; track.lyrics = "[00:00]Начало\n[00:01]Продолжение"
    library.tracks = [track]; library.currentID = track.id
    let pane = LyricsPane(library:library); pane.frame = NSRect(x:0,y:0,width:292,height:600); pane.update(track); pane.layoutSubtreeIfNeeded(); pane.tick(force:true)
    precondition(pane.rows.count == 2 && pane.active == 0)
    precondition(!pane.subviews.compactMap { $0 as? NSButton }.contains { $0.title == "×" })
    precondition(pane.scroll.frame.minY == 104 && pane.scroll.frame.maxY == pane.bounds.height - 20)
    precondition(abs(pane.rows[0].frame.midY - pane.scroll.contentSize.height/2) < 1)
    let actions = pane.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Действия…" }!
    precondition(pane.bounds.maxX - actions.frame.maxX == 12)
    pane.scroll.onManualScroll?(); precondition(!pane.follow)
    var changed = track; changed.id = "second"; changed.lyrics = "Обычный текст"; pane.update(changed)
    precondition(pane.rows.isEmpty && pane.follow)
    let ui = PlayerView(library:library); ui.frame = NSRect(x:0,y:0,width:1160,height:760); ui.toggleLyrics(); ui.layoutSubtreeIfNeeded()
    precondition(ui.showsLyrics && !ui.lyricsPane.isHidden && ui.albumScroll.frame.maxX <= ui.lyricsPane.frame.minX + 1)
    ui.toggleLyrics(); ui.layoutSubtreeIfNeeded(); precondition(ui.lyricsPane.isHidden); ui.timer?.invalidate()
    print("PASS: LRC offsets/repeated timestamps/order/blank lines, plain text, active line, manual follow, track changes and non-overlapping lyrics panel")
}

final class LyricsMockProtocol: URLProtocol, @unchecked Sendable {
    static var responder: ((URLRequest) -> (Int,Data,[String:String]))?
    static var requests = 0
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1; let result = Self.responder!(request)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:result.0,httpVersion:nil,headerFields:result.2)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:result.1); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor func testLyricsService(root:URL) async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LyricsMockProtocol.self]
    let session = URLSession(configuration:config)
    let track = Track(id:"lookup",title:"Test title",artist:"Test artist",album:"Test album",genre:"—",duration:120,number:1)
    let record = LyricsRecord(id:1,trackName:track.title,artistName:track.artist,albumName:track.album,duration:120,instrumental:false,plainLyrics:"Own test line",syncedLyrics:"[00:00]Own test line")
    let data = try JSONEncoder().encode(record)
    LyricsMockProtocol.requests = 0
    LyricsMockProtocol.responder = { request in
        precondition(request.url?.host == "lrclib.net" && request.value(forHTTPHeaderField:"User-Agent")?.contains("iTunes-Local-Prototype") == true)
        let query = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
        precondition(query.contains { $0.name == "track_name" && $0.value == track.title })
        return (200,data,["Content-Type":"application/json"])
    }
    let folder = root.appendingPathComponent("lyrics-cache")
    let service = LyricsService(folder:folder,session:session)
    let found = try await service.find(track); precondition(found?.id == 1)
    let restored = await LyricsService(folder:folder,session:session).cached(track); precondition(restored?.id == 1)
    var changed = track; changed.title = "Another song"; let stale = await service.cached(changed); precondition(stale == nil)
    LyricsMockProtocol.responder = { _ in (429,Data(),["Retry-After":"60"]) }
    let limited = LyricsService(folder:root.appendingPathComponent("limited"),session:session)
    do { _ = try await limited.find(track); preconditionFailure("Expected throttling") } catch {}
    let count = LyricsMockProtocol.requests
    do { _ = try await limited.find(track); preconditionFailure("Expected cooldown") } catch {}
    precondition(LyricsMockProtocol.requests == count)
    LyricsMockProtocol.responder = { request in request.url!.path.hasSuffix("search") ? (200,Data(("[" + String(data:data,encoding:.utf8)! + "]").utf8),["Content-Type":"application/json"]) : (404,Data(),["Content-Type":"application/json"]) }
    let fallback = try await LyricsService(folder:root.appendingPathComponent("fallback"),session:session).find(track)
    precondition(fallback?.id == 1)
    precondition(!LyricsRecord.matches(record,changed))
    session.invalidateAndCancel(); LyricsMockProtocol.responder = nil
    print("PASS: mocked LRCLIB exact/fallback lookup, client identification, strict metadata matching, persistent cache and Retry-After cooldown without network")
}

@MainActor func testAnimatedLyrics(track fixture: Track, root: URL) async throws {
    let library = Library(storage: root.appendingPathComponent("animated-lyrics.json"))
    var track = fixture; track.id = "animated-lyrics"; track.lyrics = "[00:00]Начало\n[00:00.05]Продолжение"
    library.tracks = [track]; library.currentID = track.id
    library.player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: track.path!))
    defer { library.stopPlayback() }
    let pane = LyricsPane(library: library, service: LyricsService(folder: root.appendingPathComponent("animation-cache")))
    pane.frame = NSRect(x: 0, y: 0, width: 292, height: 600); pane.update(track)
    try await Task.sleep(nanoseconds: 50_000_000)
    pane.layoutSubtreeIfNeeded(); pane.tick(force: true)
    precondition(pane.rows[0].emphasis == 1)
    library.player?.currentTime = 0.1; pane.tick()
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        precondition(pane.rows[1].emphasis == 0 && pane.rows[0].emphasis == 1)
    }
    pane.scroll.onManualScroll?()
    try await Task.sleep(nanoseconds: 450_000_000)
    precondition(pane.rows[1].emphasis == 1 && pane.rows[0].emphasis == 0 && !pane.follow)
    library.player?.currentTime = 0; pane.tick(); pane.tick(force: true)
    precondition(pane.rows[0].emphasis == 1 && pane.rows[1].emphasis == 0)
    print("PASS: timed synchronized lyric fade, asynchronous start, completion, manual follow and interrupted seek")
}
