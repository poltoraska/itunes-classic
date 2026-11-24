import AppKit
import AVFoundation
import MediaPlayer
import CryptoKit
import AudioToolbox
import CoreMedia

private enum MetadataTextCache {
    static let normalized: NSCache<NSString, NSString> = { let cache = NSCache<NSString, NSString>(); cache.countLimit = 20000; return cache }()
    static let primary: NSCache<NSString, NSString> = { let cache = NSCache<NSString, NSString>(); cache.countLimit = 20000; return cache }()
    static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)
    static let guest = try! NSRegularExpression(pattern: #"(?i)\s+[\(\[]?(?:feat\.?|ft\.?|featuring)\s+.*$"#)
}

struct Track: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var genre: String
    var duration: Double
    var number: Int
    var managedCopy: Bool?
    var managedSourcePath: String?
    var importedAt: Date?
    var path: String?
    var artwork: Data?
    var artworkPath: String?
    var artworkData: Data? { artwork ?? artworkPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0), options: .mappedIfSafe) } }
    var isExplicit: Bool?
    var mediaKind: String?
    var isVideo: Bool { mediaKind == "video" }
    var plays = 0
    var composer: String?
    var grouping: String?
    var year: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?
    var bpm: Int?
    var comments: String?
    var lyrics: String?
    var sortTitle: String?
    var sortArtist: String?
    var sortAlbum: String?
    var sortAlbumArtist: String?
    var sortComposer: String?
    var volumeAdjustment: Double?
    var startTime: Double?
    var stopTime: Double?
    var skipShuffle: Bool?
    var metadataOverrides: Set<String>?
    var albumArtist: String?
    var inferredAlbumArtist: String?
    var isCompilation: Bool?
    var albumDisplayArtist: String {
        Self.nonempty(albumArtist) ?? Self.nonempty(inferredAlbumArtist)
            ?? (isCompilation == true ? "Разные исполнители" : Self.primaryArtist(artist))
    }
    var albumKey: String { if isVideo { return "video:" + id }; return Self.normalized(albumDisplayArtist) + "\u{1f}" + Self.normalized(album) }
    static func nonempty(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }; return v
    }
    static func normalized(_ value: String) -> String {
        if let cached = MetadataTextCache.normalized.object(forKey: value as NSString) { return cached as String }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = MetadataTextCache.whitespace.stringByReplacingMatches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed), withTemplate: " ").folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        MetadataTextCache.normalized.setObject(result as NSString, forKey: value as NSString); return result
    }
    static func primaryArtist(_ value: String) -> String {
        if let cached = MetadataTextCache.primary.object(forKey: value as NSString) { return cached as String }
        let result = MetadataTextCache.guest.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
        MetadataTextCache.primary.setObject(result as NSString, forKey: value as NSString); return result
    }

}
struct SavedLibrary: Codable {
    var artworkStorageVersion: Int? = nil
    var tracks: [Track]
    var playlists: [String: [String]]
    var albumMetadataVersion: Int?
}

/// One serial writer orders autosaves and explicit edits. Artwork is content-addressed,
/// written before the atomic manifest, and never re-encoded into every track record.
private final class SaveCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private enum LibraryStorage {
    static let queue = DispatchQueue(label: "local.itunes.library-writer", qos: .utility)
    static func write(_ snapshot: SavedLibrary, to storage: URL, backupLegacy: Bool) throws -> [Track] {
        let folder = storage.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if backupLegacy, FileManager.default.fileExists(atPath: storage.path) {
            let backup = folder.appendingPathComponent("library.before-0.16.json")
            if !FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.copyItem(at: storage, to: backup) }
        }
        var records = snapshot.tracks
        let artFolder = folder.appendingPathComponent("Artwork", isDirectory: true)
        if records.contains(where: { $0.artwork != nil }) { try FileManager.default.createDirectory(at: artFolder, withIntermediateDirectories: true) }
        for i in records.indices {
            if let data = records[i].artwork {
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let file = artFolder.appendingPathComponent(hash + ".image")
                if !FileManager.default.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic) }
                records[i].artworkPath = file.path; records[i].artwork = nil
            }
        }
        let manifest = SavedLibrary(artworkStorageVersion: 1, tracks: records, playlists: snapshot.playlists, albumMetadataVersion: snapshot.albumMetadataVersion)
        try JSONEncoder().encode(manifest).write(to: storage, options: .atomic)
        return records
    }
}

@MainActor final class Library: NSObject, AVAudioPlayerDelegate {
    private(set) var importingFiles=false
    var contentRevision = 0
    var tracks: [Track] = [] { didSet { contentRevision += 1 } }
    var playlists: [String: [String]] = [:]
    var currentID: String?
    var systemMedia: SystemMedia?
    var player: AVAudioPlayer?
    var videoMeterTask: Task<Void,Never>?
    var videoMeterLevels: [Float]=[]
    var videoMeterGeneration=UUID()
    var videoPlayer: AVPlayer?
    private var videoEndObserver: NSObjectProtocol?
    private var videoStatusObserver: NSKeyValueObservation?
    var playbackTime: Double { videoPlayer.map { max(0, $0.currentTime().seconds.isFinite ? $0.currentTime().seconds : 0) } ?? player?.currentTime ?? 0 }
    var playbackDuration: Double { current?.isVideo == true ? (current?.duration ?? 0) : (player?.duration ?? current?.duration ?? 0) }
    var hasPlayback: Bool { player != nil || videoPlayer != nil }
    func seek(to time: Double) {
        finishCrossfade()
        let position = min(playbackDuration, max(current?.startTime ?? 0, time))
        if let videoPlayer { videoPlayer.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
        else { player?.currentTime = position }
        systemMedia?.update()
    }
    func stopPlayback() {
        videoMeterTask?.cancel(); videoMeterTask=nil; videoMeterGeneration=UUID(); videoMeterLevels=[]
        stopCrossfadeResources()
        player?.stop(); player = nil; videoPlayer?.pause(); videoPlayer = nil
        if let videoEndObserver { NotificationCenter.default.removeObserver(videoEndObserver) }
        videoEndObserver = nil; videoStatusObserver = nil
    }
    var queue: [String] = []
    var playbackPlan = PlaybackPlan() { didSet { invalidateCrossfadePreparation() } }
    var onQueueChange: (() -> Void)?
    var shuffle = false { didSet { if shuffle && !oldValue { playbackPlan.shuffleRemaining() }; onQueueChange?() } }
    var repeatMode = 0 { didSet { invalidateCrossfadePreparation() } }
    static let volumePreferenceKey = "PlaybackVolume"
    fileprivate let playbackDefaults: UserDefaults?
    fileprivate var storedCrossfadeEnabled = false
    fileprivate var storedCrossfadeSeconds = 3.0
    fileprivate var crossfadeTimer: Timer?
    fileprivate var crossfadeTask: Task<Void, Never>?
    fileprivate var preparedTransition: PreparedTransition?
    fileprivate var preparedCandidate: String?
    fileprivate var crossfadeGeneration = 0
    private(set) var outgoingPlayer: AVAudioPlayer?
    var fadingTrack: Track?
    var incomingGain: Float = 1
    var outgoingGain: Float = 0
    fileprivate var fadeIncomingStart = 0.0
    fileprivate var fadeDuration = 0.0
    private var storedVolume: Float = 0.65
    var volume: Float {
        get { storedVolume }
        set {
            guard newValue.isFinite else { return }
            storedVolume = min(1, max(0, newValue))
            playbackDefaults?.set(Double(storedVolume), forKey: Self.volumePreferenceKey)
            applyPlayerSettings()
        }
    }
    var onPlaybackChange: (() -> Void)?
    var onChange: (() -> Void)?
    private var pendingSave: DispatchWorkItem?
    private var pendingCancellation: SaveCancellation?
    private var pendingSnapshot: SavedLibrary?
    private var saveGeneration = 0
    private(set) var needsArtworkMigration = false
    var onError: ((String) -> Void)?
    var onImportProgress: ((Int, Int) -> Void)?
    var current: Track? { tracks.first { $0.id == currentID } }
    var playing: Bool { videoPlayer.map { $0.rate != 0 } ?? player?.isPlaying ?? false }
    let mediaRoot: URL
    let legacyMediaRoots: [URL]
    let managedImports: Bool
    let storage: URL
    private(set) var albumMetadataVersion: Int?
    private(set) var upgradingMetadata = false
    private(set) var metadataProgress = 0
    private(set) var metadataTotal = 0

    init(storage: URL? = nil, defaults: UserDefaults? = nil, managedImports: Bool? = nil) {
        // Temporary/private test libraries never write the user's playback preferences.
        self.managedImports=managedImports ?? (storage == nil)
        let musicDirectory=FileManager.default.urls(for:.musicDirectory,in:.userDomainMask)[0]
        mediaRoot=storage.map { $0.deletingLastPathComponent().appendingPathComponent("Media") } ?? ManagedMedia.defaultRoot(musicDirectory:musicDirectory)
        legacyMediaRoots=storage == nil ? [musicDirectory.appendingPathComponent("iTunes Classic Media")] : []
        playbackDefaults = defaults ?? (storage == nil ? .standard : nil)
        if let saved = playbackDefaults?.object(forKey: Self.volumePreferenceKey) as? NSNumber, saved.doubleValue.isFinite {
            storedVolume = Float(min(1, max(0, saved.doubleValue)))
        }
        storedCrossfadeEnabled = playbackDefaults?.bool(forKey: Self.crossfadeEnabledKey) ?? false
        if let seconds = playbackDefaults?.object(forKey: Self.crossfadeSecondsKey) as? NSNumber, seconds.doubleValue.isFinite { storedCrossfadeSeconds = min(12, max(1, seconds.doubleValue)) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.storage = storage ?? support.appendingPathComponent("iTunes Prototype/library.json")
        // Only the previous application's private JSON database is migrated; never Apple's library.
        let previousStorage = support.appendingPathComponent(("Silver" + "Tunes") + "/library.json")
        let source = storage == nil && !FileManager.default.fileExists(atPath: self.storage.path)
            && FileManager.default.fileExists(atPath: previousStorage.path) ? previousStorage : self.storage
        super.init()
        if let data = try? Data(contentsOf: source), let saved = try? JSONDecoder().decode(SavedLibrary.self, from: data) {
            tracks = saved.tracks; playlists = saved.playlists; albumMetadataVersion = saved.albumMetadataVersion
            needsArtworkMigration = saved.artworkStorageVersion != 1 && saved.tracks.contains { $0.artwork != nil }
        } else { tracks = []; albumMetadataVersion = 3 }
        // Built-in entries have fixed IDs and no file path. Imported files always have a path.
        let removed = Set(tracks.filter { $0.path == nil && $0.id.range(of: #"^demo-[0-5]-[0-3]$"#, options: .regularExpression) != nil }.map(\.id))
        tracks.removeAll { removed.contains($0.id) }
        for name in playlists.keys { playlists[name]?.removeAll { removed.contains($0) } }
        Self.reconcileAlbumArtists(&tracks)
        if source != self.storage || !removed.isEmpty {
            do {
                try FileManager.default.createDirectory(at: self.storage.deletingLastPathComponent(), withIntermediateDirectories: true)
                let backup = self.storage.deletingLastPathComponent().appendingPathComponent("library.before-0.3.json")
                if !FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.copyItem(at: source, to: backup) }
                try JSONEncoder().encode(SavedLibrary(tracks: tracks, playlists: playlists, albumMetadataVersion: albumMetadataVersion)).write(to: self.storage, options: .atomic)
            } catch { print("Library migration could not be saved: \(error)") }
        }
    }
    @discardableResult func persist(_ records: [Track]) throws -> [Track] {
        pendingCancellation?.cancel(); pendingSave?.cancel(); pendingSave = nil; pendingSnapshot = nil; saveGeneration += 1
        let snapshot = SavedLibrary(tracks: records, playlists: playlists, albumMetadataVersion: albumMetadataVersion)
        let backup = needsArtworkMigration
        let result = try LibraryStorage.queue.sync { try LibraryStorage.write(snapshot, to: storage, backupLegacy: backup) }
        needsArtworkMigration = false; return result
    }
    @discardableResult func save() -> Bool {
        do { tracks = try persist(tracks); return true }
        catch { onError?("Не удалось сохранить библиотеку: \(error.localizedDescription)"); return false }
    }
    func saveInBackground() {
        pendingCancellation?.cancel(); pendingSave?.cancel(); saveGeneration += 1
        let generation = saveGeneration; let revision = contentRevision
        let externalizing = tracks.contains { $0.artwork != nil }
        let snapshot = SavedLibrary(tracks: tracks, playlists: playlists, albumMetadataVersion: albumMetadataVersion)
        pendingSnapshot = snapshot
        let storage = self.storage; let backup = needsArtworkMigration
        let cancellation = SaveCancellation(); pendingCancellation = cancellation
        let work = DispatchWorkItem { [weak self] in
            guard !cancellation.isCancelled else { return }
            do {
                let normalized = try LibraryStorage.write(snapshot, to: storage, backupLegacy: backup)
                Task { @MainActor [weak self] in
                    guard let self, self.saveGeneration == generation else { return }
                    if self.contentRevision == revision && externalizing { self.tracks = normalized; self.onChange?() }
                    self.needsArtworkMigration = false; self.pendingSnapshot = nil; self.pendingSave = nil
                }
            } catch {
                Task { @MainActor [weak self] in self?.onError?("Не удалось сохранить библиотеку: " + error.localizedDescription) }
            }
        }
        pendingSave = work
        LibraryStorage.queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    func flushPendingSave() {
        guard let snapshot = pendingSnapshot else { return }
        pendingCancellation?.cancel(); pendingSave?.cancel(); pendingSave = nil; pendingSnapshot = nil; saveGeneration += 1
        let backup = needsArtworkMigration
        do {
            let normalized = try LibraryStorage.queue.sync { try LibraryStorage.write(snapshot, to: storage, backupLegacy: backup) }
            tracks = normalized; needsArtworkMigration = false
        } catch { onError?("Не удалось сохранить библиотеку: " + error.localizedDescription) }
    }
    @discardableResult func play(_ track: Track, within visible: [Track]? = nil, contextTitle: String? = nil) -> Bool {
        let priorPlan = playbackPlan
        if let visible { beginPlaybackContext(visible, at: track, title: contextTitle) }
        else if playbackPlan.current?.entry.trackID != track.id { beginPlaybackContext([track], at: track) }
        do {
            let next: AVAudioPlayer
            guard let path = track.path else { throw NSError(domain: "Library", code: 2, userInfo: [NSLocalizedDescriptionKey: "Для композиции не указан аудиофайл"]) }
            if track.isVideo {
                guard FileManager.default.isReadableFile(atPath: path) else { throw CocoaError(.fileReadNoPermission) }
                let item = AVPlayerItem(url: URL(fileURLWithPath: path))
                // Keep AVPlayerView's rendering connection intact across clip changes.
                // Only the item changes; observers and metering still belong to the new clip.
                let video = videoPlayer ?? AVPlayer()
                stopPlayback(); currentID = track.id
                video.replaceCurrentItem(with: item); videoPlayer = video
                applyPlayerSettings(); startVideoMeter(URL(fileURLWithPath:path))
                videoEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor in guard self?.videoPlayer?.currentItem === item else { return }; self?.advanceAfterFinish() }
                }
                videoStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    Task { @MainActor in
                        guard self?.videoPlayer?.currentItem === item else { return }
                        self?.onError?("Не удалось открыть видеоклип: " + (item.error?.localizedDescription ?? "Неподдерживаемый формат"))
                        self?.stopPlayback(); self?.onPlaybackChange?()
                    }
                }
                seek(to: track.startTime ?? 0); video.play()
                if let i = tracks.firstIndex(where: { $0.id == track.id }) { tracks[i].plays += 1 }
                saveInBackground(); refreshCrossfadeClock(); onPlaybackChange?(); onQueueChange?(); return true
            }
            next = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            stopPlayback(); player = next; currentID = track.id
            next.currentTime = track.startTime ?? 0; applyPlayerSettings(); next.delegate = self; next.isMeteringEnabled = true
            guard next.prepareToPlay(), next.play() else { throw NSError(domain: "Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Аудиоустройство недоступно"]) }
            if let i = tracks.firstIndex(where: { $0.id == track.id }) { tracks[i].plays += 1 }
            saveInBackground(); refreshCrossfadeClock(); onPlaybackChange?(); onQueueChange?(); return true
        } catch { playbackPlan = priorPlan; onError?("Не удалось воспроизвести «\(track.title)». \(error.localizedDescription)"); return false }
    }
    func toggle(_ visible: [Track], contextTitle: String? = nil) {
        if let videoPlayer { if playing { videoPlayer.pause() } else { if playbackTime >= playbackDuration - 0.1 { seek(to: current?.startTime ?? 0) }; videoPlayer.play() }; onPlaybackChange?() }
        else if let player {
            if player.isPlaying { player.pause(); outgoingPlayer?.pause() }
            else { player.play(); if let outgoingPlayer, outgoingPlayer.currentTime < outgoingPlayer.duration - 0.02 { outgoingPlayer.play() } else { finishCrossfade() } }
            refreshCrossfadeClock(); onPlaybackChange?()
        }
        else if playbackPlan.hasExplicit { step(1) }
        else if let first = visible.first { play(first, within: visible, contextTitle: contextTitle) }
    }
    func step(_ direction: Int) {
        if playbackPlan.current == nil && !playbackPlan.hasExplicit {
            let visible = tracks.filter { !shuffle || $0.skipShuffle != true }
            guard let first = current ?? visible.first else { return }
            beginPlaybackContext(visible, at: first)
            if currentID == nil { play(first); return }
        }
        let before = playbackPlan
        var id = direction < 0 ? playbackPlan.previous() : playbackPlan.next(repeatAll: repeatMode == 1, shuffled: shuffle)
        // Missing/deleted files in the library cannot block the remaining queue.
        var remaining = playbackPlan.manual.count + playbackPlan.continuation.count + playbackPlan.later.count + 1
        while let candidate = id, !tracks.contains(where: { $0.id == candidate }), remaining > 0 {
            remaining -= 1; id = playbackPlan.next()
        }
        if let id, let track = tracks.first(where: { $0.id == id }) {
            if !play(track) { playbackPlan = before; onQueueChange?() }
        } else { onQueueChange?() }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in guard self.player === player else { return }; self.advanceAfterFinish() }
    }
    func advanceAfterFinish() {
        if repeatMode == 2, playbackPlan.manual.isEmpty, let track = current { play(track) }
        else if playbackPlan.hasUpcoming || repeatMode == 1 { step(1) }
        else { videoPlayer?.pause(); onPlaybackChange?() }
    }
    func importURLs(_ urls: [URL]) async -> (Int, Int) {
        guard !importingFiles else { return (0,urls.count) }; importingFiles=true; defer { importingFiles=false }
        let extensions = Set(["mp3", "m4a", "aac", "aif", "aiff", "wav", "caf", "flac", "alac", "mp4", "m4v", "mov"])
        let files = await Task.detached(priority: .userInitiated) {
            func discover() -> [URL] {
            var found: [URL] = []
            for url in urls {
                var dir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue {
                    if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                        for case let file as URL in enumerator where extensions.contains(file.pathExtension.lowercased()) { found.append(file) }
                    }
                } else if extensions.contains(url.pathExtension.lowercased()) { found.append(url) }
            }
            return found.sorted { $0.path < $1.path }
            }
            return discover()
        }.value
        let initialTracks=tracks
        let batchDate=Date()
        let firstNewIndex = tracks.count
        var added = 0; var failed = 0
        var paths = Set(tracks.compactMap(\.path)+tracks.compactMap(\.managedSourcePath))
        for (offset, file) in files.enumerated() {
            defer { onImportProgress?(offset + 1, files.count) }
            let path = file.standardizedFileURL.path
            if paths.contains(path) { continue }
            let asset = AVURLAsset(url: file)
            do {
                guard try await asset.load(.isPlayable) else { failed += 1; continue }
                let isVideo = !(try await asset.loadTracks(withMediaType: .video)).isEmpty
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else { failed += 1; continue }
                let metadata = try await asset.load(.commonMetadata)
                var title = file.deletingPathExtension().lastPathComponent
                var artist = file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent; var album = file.deletingLastPathComponent().lastPathComponent
                var artwork: Data?
                for item in metadata {
                    switch item.commonKey {
                    case .commonKeyTitle: if let v = try? await item.load(.stringValue), !v.isEmpty { title = v }
                    case .commonKeyArtist: if let v = try? await item.load(.stringValue), !v.isEmpty { artist = v }
                    case .commonKeyAlbumName: if let v = try? await item.load(.stringValue), !v.isEmpty { album = v }
                    case .commonKeyArtwork: artwork = try? await item.load(.dataValue)
                    default: break
                    }
                }
                if isVideo && artwork == nil {
                    artwork = await Task.detached(priority: .utility) {
                        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
                        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 640, height: 640)
                        guard let cg = try? generator.copyCGImage(at: CMTime(seconds: min(1, duration / 2), preferredTimescale: 600), actualTime: nil) else { return nil as Data? }
                        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
                    }.value
                }
                tracks.append(Track(id: UUID().uuidString, title: title, artist: artist, album: album, genre: "—", duration: duration, number: 0, path: path, artwork: artwork, mediaKind: isVideo ? "video" : "audio"))
                tracks[tracks.count-1].importedAt=batchDate
                paths.insert(path); added += 1
            } catch { failed += 1 }
        }
        // Read album-level metadata independently of track-level Artist.
        for i in firstNewIndex..<tracks.count {
            if let path = tracks[i].path { await updateAlbumMetadata(at: i, url: URL(fileURLWithPath: path)) }
        }
        Self.reconcileAlbumArtists(&tracks)
        var created: [String]=[]
        if managedImports {
            var rejected=Set<String>()
            for i in firstNewIndex..<tracks.count {
                let track=tracks[i], root=mediaRoot
                do { let imported=try await Task.detached { try ManagedMedia.copyImport(track,root:root) }.value; tracks[i]=imported; created.append(imported.path!) }
                catch { rejected.insert(track.id); added -= 1; failed += 1 }
            }
            tracks.removeAll { rejected.contains($0.id) }
        }
        if !save() { for path in created { try? FileManager.default.removeItem(atPath:path) }; tracks=initialTracks; failed += added; added=0 }
        onChange?(); return (added, failed)
    }
    // Re-read legacy tag formats once, preserving all explicit edits and playlist membership.
    func upgradeAlbumMetadata() async {
        guard albumMetadataVersion != 3, !upgradingMetadata else { return }
        upgradingMetadata = true
        let backup = storage.deletingPathExtension().appendingPathExtension("before-0.5.json")
        if FileManager.default.fileExists(atPath: storage.path), !FileManager.default.fileExists(atPath: backup.path) {
            do { try FileManager.default.copyItem(at: storage, to: backup) }
            catch { upgradingMetadata = false; onError?("Не удалось создать резервную копию медиатеки: \(error.localizedDescription)"); return }
        }
        let ids = tracks.filter { $0.path != nil }.map(\.id)
        metadataTotal = ids.count; metadataProgress = 0; onChange?()
        for (offset, id) in ids.enumerated() {
            guard let i = tracks.firstIndex(where: { $0.id == id }), let path = tracks[i].path else { continue }
            await updateAlbumMetadata(at: i, url: URL(fileURLWithPath: path))
            metadataProgress = offset + 1
            if metadataProgress % 5 == 0 { onChange?(); print("Metadata update: \(metadataProgress)/\(metadataTotal)") }
        }
        Self.reconcileAlbumArtists(&tracks)
        albumMetadataVersion = 3; upgradingMetadata = false
        save(); onChange?()
    }
    private func updateAlbumMetadata(at index: Int, url: URL) async {
        guard let metadata = await Task.detached(priority: .utility, operation: { await ImportedMetadata.read(url) }).value else { return }
        if let explicit = metadata.isExplicit { tracks[index].isExplicit = explicit }
        for (field, value) in metadata.fields where !(tracks[index].metadataOverrides ?? []).contains(field.rawValue) {
            try? tracks[index].setValue(value, for: field)
        }
    }
    static func reconcileAlbumArtists(_ tracks: inout [Track]) {
        for i in tracks.indices { tracks[i].inferredAlbumArtist = nil }
        // Only infer within the same physical release folder and album title.
        let groups = Dictionary(grouping: tracks.indices.filter { tracks[$0].path != nil }) { i in
            let folder = URL(fileURLWithPath: tracks[i].path!).deletingLastPathComponent().standardizedFileURL.path
            return folder + "\u{1f}" + Track.normalized(tracks[i].album)
        }
        for indices in groups.values {
            let explicit = Dictionary(grouping: indices.compactMap { Track.nonempty(tracks[$0].albumArtist) }, by: Track.normalized)
            if explicit.count == 1, let name = explicit.values.first?.first {
                for i in indices where Track.nonempty(tracks[i].albumArtist) == nil { tracks[i].inferredAlbumArtist = name }
                continue
            }
            if explicit.count > 1 { continue } // Conflicting release tags are authoritative; don't guess.
            if indices.contains(where: { tracks[$0].isCompilation == true }) {
                for i in indices { tracks[i].inferredAlbumArtist = "Разные исполнители" }; continue
            }
            let names = indices.map { Track.primaryArtist(tracks[$0].artist) }
            let counts = Dictionary(grouping: names, by: Track.normalized)
            // A solo credit must exist, and every other credit must start with that same artist
            // followed by an explicit guest separator. This avoids merging unrelated artists.
            let candidates = counts.values.sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return ($0.first ?? "").count < ($1.first ?? "").count
            }
            for candidate in candidates.compactMap(\.first) {
                let base = Track.normalized(candidate)
                guard !base.isEmpty, names.allSatisfy({ name in
                    let n = Track.normalized(name)
                    return n == base || [" & ", "/", ", ", " with ", " x "].contains { n.hasPrefix(base + $0) }
                }) else { continue }
                for i in indices { tracks[i].inferredAlbumArtist = candidate }; break
            }
        }
    }
}

/// Publishes local playback only; never queries or authorizes an Apple Music library.
@MainActor final class SystemMedia: NSObject {
    weak var library: Library?
    private var timer: Timer?
    private var artworkKey: String?
    private var artwork: MPMediaItemArtwork?
    private let commands = MPRemoteCommandCenter.shared()
    init(_ library: Library) {
        self.library = library; super.init()
        commands.playCommand.addTarget(self, action: #selector(play(_:)))
        commands.pauseCommand.addTarget(self, action: #selector(pause(_:)))
        commands.togglePlayPauseCommand.addTarget(self, action: #selector(toggle(_:)))
        commands.nextTrackCommand.addTarget(self, action: #selector(next(_:)))
        commands.previousTrackCommand.addTarget(self, action: #selector(previous(_:)))
        commands.changePlaybackPositionCommand.addTarget(self, action: #selector(seek(_:)))
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }
    func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let library, let track = library.current, library.hasPlayback else {
            center.nowPlayingInfo = nil; center.playbackState = .stopped; return
        }
        let key = Covers.key(track)
        if key != artworkKey || artwork == nil {
            artworkKey = key
            if let image = Covers.cached(track) {
                artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            } else { _ = Covers.image(track); artwork = nil }
        }
        var info: [String: Any] = [MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist, MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: library.playbackDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: library.playbackTime,
            MPNowPlayingInfoPropertyPlaybackRate: library.playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: (track.isVideo ? MPNowPlayingInfoMediaType.video : MPNowPlayingInfoMediaType.audio).rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = library.playing ? .playing : .paused
    }
    func finish() {
        timer?.invalidate()
        for command in [commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand,
                        commands.nextTrackCommand, commands.previousTrackCommand, commands.changePlaybackPositionCommand] {
            command.removeTarget(self)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
    nonisolated private func handle(_ action: @escaping @MainActor (Library) -> Void) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor [weak self] in
            guard let self, let library = self.library else { return }
            action(library); self.update()
        }
        return .success
    }
    @objc nonisolated private func play(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        handle { if !$0.playing { $0.toggle($0.tracks) } }
    }
    @objc nonisolated private func pause(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        handle { if $0.playing { $0.toggle($0.tracks) } }
    }
    @objc nonisolated private func toggle(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        handle { $0.toggle($0.tracks) }
    }
    @objc nonisolated private func next(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        handle { $0.step(1) }
    }
    @objc nonisolated private func previous(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        handle { $0.step(-1) }
    }
    @objc nonisolated private func seek(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
        let position = event.positionTime
        return handle { $0.seek(to: position) }
    }
}

/// Background preparation transfers ownership to the main actor before playback.
private final class PreparedAudioBox: @unchecked Sendable {
    let player: AVAudioPlayer
    init(_ player: AVAudioPlayer) { self.player = player }
}
private struct PreparedTransition {
    let track: Track
    let plan: PlaybackPlan
    let audio: PreparedAudioBox
}

@MainActor extension Library {
    static let crossfadeEnabledKey = "CrossfadeEnabled"
    static let crossfadeSecondsKey = "CrossfadeSeconds"
    var crossfadeEnabled: Bool {
        get { storedCrossfadeEnabled }
        set {
            storedCrossfadeEnabled = newValue; playbackDefaults?.set(newValue, forKey: Self.crossfadeEnabledKey)
            invalidateCrossfadePreparation(); if !newValue { finishCrossfade() }; refreshCrossfadeClock()
        }
    }
    var crossfadeSeconds: Double {
        get { storedCrossfadeSeconds }
        set {
            guard newValue.isFinite else { return }
            storedCrossfadeSeconds = min(12, max(1, newValue)); playbackDefaults?.set(storedCrossfadeSeconds, forKey: Self.crossfadeSecondsKey)
            invalidateCrossfadePreparation(); refreshCrossfadeClock()
        }
    }
    var isCrossfading: Bool { outgoingPlayer != nil }
    func invalidateCrossfadePreparation() {
        crossfadeGeneration += 1; crossfadeTask?.cancel(); crossfadeTask = nil; preparedTransition = nil; preparedCandidate = nil
    }
    private func refreshCrossfadeClock() {
        guard crossfadeEnabled, player?.isPlaying == true, videoPlayer == nil else { crossfadeTimer?.invalidate(); crossfadeTimer = nil; return }
        guard crossfadeTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated { guard let self else { timer.invalidate(); return }; self.updateCrossfade() }
        }
        crossfadeTimer = timer; RunLoop.main.add(timer, forMode: .common)
        prepareCrossfade()
    }
    private func prepareCrossfade() {
        guard crossfadeEnabled, repeatMode != 2, outgoingPlayer == nil, let current, !current.isVideo, player?.isPlaying == true, crossfadeTask == nil, preparedCandidate == nil else { return }
        var proposal = playbackPlan
        guard let id = proposal.next(repeatAll: repeatMode == 1, shuffled: shuffle), preparedCandidate != id,
              let track = tracks.first(where: { $0.id == id }), !track.isVideo, let path = track.path else { return }
        preparedCandidate = id
        let generation = crossfadeGeneration, sourceID = current.id
        crossfadeTask = Task { [weak self] in
            let audio = await Task.detached(priority: .utility) { () -> PreparedAudioBox? in
                guard FileManager.default.isReadableFile(atPath: path), let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)), player.prepareToPlay() else { return nil }
                return PreparedAudioBox(player)
            }.value
            guard !Task.isCancelled, let self, self.crossfadeGeneration == generation, self.currentID == sourceID, self.crossfadeEnabled else { return }
            self.crossfadeTask = nil
            if let audio { self.preparedTransition = PreparedTransition(track: track, plan: proposal, audio: audio) }
        }
    }
    private func effectiveEnd(_ track: Track, player: AVAudioPlayer) -> Double { min(player.duration, track.stopTime ?? player.duration) }
    private func updateCrossfade() {
        guard let player, player.isPlaying else { return }
        if outgoingPlayer != nil {
            let p = min(1, max(0, (player.currentTime - fadeIncomingStart) / max(0.001, fadeDuration)))
            incomingGain = Float(sin(p * .pi / 2)); outgoingGain = Float(cos(p * .pi / 2))
            applyPlayerSettings(smooth: true)
            if p >= 1 { finishCrossfade() }
            return
        }
        prepareCrossfade()
        guard let candidate = preparedTransition, let current else { return }
        let next = candidate.audio.player
        let remaining = effectiveEnd(current, player: player) - player.currentTime
        let currentLength = effectiveEnd(current, player: player) - (current.startTime ?? 0)
        let nextLength = effectiveEnd(candidate.track, player: next) - (candidate.track.startTime ?? 0)
        let duration = min(crossfadeSeconds, currentLength / 2, nextLength / 2)
        guard duration > 0.05, remaining > 0.04, remaining <= duration + 0.025 else { return }
        next.currentTime = candidate.track.startTime ?? 0; next.volume = 0; next.delegate = self; next.isMeteringEnabled = true
        guard next.play() else { preparedTransition = nil; return }
        let oldTrack = current
        player.delegate = nil; outgoingPlayer = player; fadingTrack = oldTrack
        self.player = next; currentID = candidate.track.id; fadeIncomingStart = next.currentTime
        fadeDuration = min(duration, remaining); incomingGain = 0; outgoingGain = 1
        playbackPlan = candidate.plan
        applyPlayerSettings()
        if let i = tracks.firstIndex(where: { $0.id == candidate.track.id }) { tracks[i].plays += 1 }
        saveInBackground(); onPlaybackChange?(); onQueueChange?()
    }
    private func finishCrossfade() {
        outgoingPlayer?.stop(); outgoingPlayer = nil; fadingTrack = nil; incomingGain = 1; outgoingGain = 0; fadeDuration = 0
        applyPlayerSettings()
    }
    private func stopCrossfadeResources() {
        crossfadeTimer?.invalidate(); crossfadeTimer = nil; invalidateCrossfadePreparation(); finishCrossfade()
    }
}


// Existence checking is read-only. Offline volumes and denied access are not deletions.
enum MediaFileState { case present, missing, unavailable }
struct MediaAudit {
    var missing: [Track] = []
    var unavailable = 0
    static func state(_ path: String, volumes: [URL]? = nil) -> MediaFileState {
        let url=URL(fileURLWithPath:path).standardizedFileURL
        if url.path.hasPrefix("/Volumes/") {
            let mounted=volumes ?? FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:nil,options:[]) ?? []
            guard mounted.contains(where: { $0.path != "/" && (url.path == $0.path || url.path.hasPrefix($0.path+"/")) }) else { return .unavailable }
        }
        var info=stat()
        if stat(url.path,&info) == 0 { return (info.st_mode & S_IFMT) == S_IFREG ? .present : .unavailable }
        return errno == ENOENT || errno == ENOTDIR ? .missing : .unavailable
    }
    static func scan(_ tracks: [Track]) -> Self {
        let volumes=FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:nil,options:[]) ?? []
        var result=Self()
        for track in tracks { guard let path=track.path else { continue }; switch state(path,volumes:volumes) { case .missing: result.missing.append(track); case .unavailable: result.unavailable += 1; case .present: break } }
        return result
    }
}
@MainActor extension Library {
    @discardableResult func removeRecords(_ ids: Set<String>) -> Bool {
        guard !importingFiles else { onError?("Дождитесь завершения импорта файлов."); return false }
        let oldTracks=tracks, oldPlaylists=playlists
        let removed=ids.intersection(tracks.map(\.id)); guard !removed.isEmpty else { return true }
        tracks.removeAll { removed.contains($0.id) }
        for name in playlists.keys { playlists[name]?.removeAll { removed.contains($0) } }
        guard save() else { tracks=oldTracks; playlists=oldPlaylists; return false }
        finishCrossfade()
        if let currentID, removed.contains(currentID) { stopPlayback(); self.currentID=nil }
        queue.removeAll { removed.contains($0) }; playbackPlan.removeTracks(removed)
        onQueueChange?(); onPlaybackChange?(); onChange?(); systemMedia?.update()
        return true
    }
}


/// Decode only the sound track; retain small time-aligned RMS bins, never video frames or full PCM.
struct VideoMeterEnvelope {
    static let interval=0.05
    static func read(_ url: URL, publish: @escaping @Sendable ([Float]) async -> Void) async -> [Float] {
        let asset=AVURLAsset(url:url)
        guard let track=try? await asset.loadTracks(withMediaType:.audio).first,
            let reader=try? AVAssetReader(asset:asset) else { return [] }
        let output=AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false,AVLinearPCMIsBigEndianKey:false])
        output.alwaysCopiesSampleData=false
        guard reader.canAdd(output) else { return [] }; reader.add(output)
        guard reader.startReading() else { return [] }; defer { reader.cancelReading() }
        var levels: [Float]=[]; var lastPublished=Date.distantPast
        while !Task.isCancelled, let sample=output.copyNextSampleBuffer() {
            guard let block=CMSampleBufferGetDataBuffer(sample) else { continue }
            let length=CMBlockBufferGetDataLength(block)
            guard length > 0, length <= 4*1024*1024 else { continue }
            var bytes=Data(count:length)
            let status=bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:length,destination:$0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { continue }
            let rms: Float=bytes.withUnsafeBytes { raw in
                var squares: Double=0
                for i in 0..<(length/4) { let value=raw.loadUnaligned(fromByteOffset:i*4,as:Float.self); if value.isFinite { squares += Double(value)*Double(value) } }
                return Float(sqrt(squares/Double(length/4)))
            }
            let start=CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let duration=CMSampleBufferGetDuration(sample).seconds
            guard start.isFinite, start >= 0, start < 21600 else { continue }
            let first=Int(start/interval), last=min(432000,Int((start+(duration.isFinite ? max(0,duration) : 0))/interval))
            if levels.count <= last { levels.append(contentsOf:repeatElement(0,count:last+1-levels.count)) }
            for i in first...last { levels[i]=max(levels[i],rms) }
            if Date().timeIntervalSince(lastPublished)>0.25 { await publish(levels); lastPublished=Date() }
        }
        return Task.isCancelled ? [] : levels
    }
    static func strength(_ levels:[Float], at time:Double)->Double {
        guard time.isFinite, time >= 0, time < Double(levels.count)*interval else { return 0 }
        let index=Int(time/interval); guard levels.indices.contains(index), levels[index] > 0 else { return 0 }
        return min(1,max(0,(20*log10(Double(levels[index]))+55)/55))
    }
}
@MainActor extension Library {
    func startVideoMeter(_ url:URL) {
        videoMeterTask?.cancel(); videoMeterLevels=[]
        let generation=UUID(); videoMeterGeneration=generation
        videoMeterTask=Task.detached(priority:.utility) { [weak self] in
            let levels=await VideoMeterEnvelope.read(url) { partial in
                await MainActor.run { guard let self, self.videoMeterGeneration == generation else { return }; self.videoMeterLevels=partial }
            }
            await MainActor.run { guard let self, self.videoMeterGeneration == generation else { return }; self.videoMeterLevels=levels }
        }
    }
    var meterStrength:Double {
        guard playing else { return 0 }
        if videoPlayer != nil { return VideoMeterEnvelope.strength(videoMeterLevels,at:playbackTime) }
        player?.updateMeters(); let db=player?.averagePower(forChannel:0) ?? -100
        return db.isFinite ? min(1,max(0,(Double(db)+55)/55)) : 0
    }
}


@MainActor extension Library {
    /// Prepare IDs in a worker. Probe only until the first playable path; never open every movie to start.
    @discardableResult func playAllVideosShuffled() async -> Bool {
        let snapshot=tracks.filter { $0.isVideo }.map { ($0.id,$0.path) }
        guard !snapshot.isEmpty else { return false }
        let previousID=currentID, previousVideo=videoPlayer, previousAudio=player
        let prepared=await Task.detached(priority:.userInitiated) { () -> ([String],String?) in
            let order=snapshot.shuffled()
            let first=order.first { item in item.1.map { FileManager.default.isReadableFile(atPath:$0) } ?? false }
            return (order.map { $0.0 },first?.0)
        }.value
        guard currentID == previousID, videoPlayer === previousVideo, player === previousAudio else { return false }
        let lookup=Dictionary(uniqueKeysWithValues:tracks.filter { $0.isVideo }.map { ($0.id,$0) })
        guard let firstID=prepared.1, let first=lookup[firstID] else { onError?("Нет доступных видеоклипов для воспроизведения. Проверьте файлы медиатеки."); return false }
        let remaining=prepared.0.filter { $0 != firstID && lookup[$0] != nil }
        let ids=[firstID]+remaining
        let oldPlan=playbackPlan, oldQueue=queue, oldShuffle=shuffle
        // This explicit command starts a fresh video context, including replacing an old manual queue.
        var plan=PlaybackPlan(); plan.start(ids,at:firstID,title:"Из видеотеки · перемешано",shuffled:false)
        playbackPlan=plan; queue=ids; shuffle=true
        guard play(first) else { shuffle=oldShuffle; playbackPlan=oldPlan; queue=oldQueue; return false }
        return true
    }
}
