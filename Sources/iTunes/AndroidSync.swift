import AppKit
import AVFoundation
import AudioToolbox
import CryptoKit
#if SWIFT_PACKAGE
import MTPSupport
#endif

// The MTP session has one owner; no operation, including cancellation, touches it concurrently.
final class SyncControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func check() throws { if cancelled { throw CocoaError(.userCancelled) } }
}
struct SyncFailure: LocalizedError { let message: String; var errorDescription: String? { message } }
struct SyncIdentity: Codable, Equatable {
    var title: String, artist: String, album: String, albumArtist: String
    var disc: Int, number: Int, duration: Double
    static func normalize(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive,.diacriticInsensitive],locale: Locale(identifier:"en_US_POSIX")).split(whereSeparator: { $0.isWhitespace }).joined(separator:" ")
    }
    var albumKey: String { Self.normalize(albumArtist) + "\u{1f}" + Self.normalize(album) }
    var key: String { Self.normalize(title) + "\u{1f}" + Self.normalize(artist) + "\u{1f}" + String(disc) + ":" + String(number) }
    func matches(_ other: Self) -> Bool { Self.normalize(title) == Self.normalize(other.title) && Self.normalize(artist) == Self.normalize(other.artist) && (number == 0 || other.number == 0 || number == other.number) && (disc == 0 || other.disc == 0 || disc == other.disc) && abs(duration-other.duration) <= 3 }
    init(_ track: Track) {
        title = track.title; artist = track.artist; album = track.album; albumArtist = track.albumDisplayArtist
        disc = max(1,track.discNumber ?? 1); number = track.number; duration = track.duration
    }
}
struct SyncRemote {
    let id: UInt32, parent: UInt32, name: String, size: UInt64, modified: Int64
    var identity: SyncIdentity?
    var folder = false
    var compatible = true
}
struct SyncLocal { let track: Track; let identity: SyncIdentity; let fingerprint: String }
struct SyncDecision { let key: String; let local: [SyncLocal]; let old: [SyncRemote]; let replace: Bool }
struct SyncReceipt: Codable { let signature: String; let remote: [UInt32]; let sizes: [UInt64] }
struct SyncCachedSong: Codable {
    let parent: UInt32, name: String, size: UInt64, modified: Int64, identity: SyncIdentity
    var compatible = true
    func matches(_ e: PTEntry, parent: UInt32) -> Bool { modified > 0 && self.parent == parent && name == e.name && size == e.size && modified == e.modifiedSeconds }
}
struct SyncJournal: Codable {
    var albums: [String:SyncReceipt] = [:]
    var inventory: [String:SyncCachedSong] = [:]
}

// Pure planner: formats and byte sizes are deliberately absent from song equivalence.
enum SyncPlanner {
    static let audioExtensions: Set<String> = ["mp3","m4a","aac","flac","ogg","opus","wav","wave","aif","aiff","aifc","alac","wma"]
    static func signature(_ songs: [SyncLocal]) -> String {
        digest(Data(songs.map { $0.identity.key + "|" + $0.fingerprint }.sorted().joined(separator:"\n").utf8))
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func plan(_ local: [SyncLocal], _ remote: [SyncRemote], journal: SyncJournal) throws -> [SyncDecision] {
        let albums = Dictionary(grouping:local,by: { $0.identity.albumKey })
        let onPhone = Dictionary(grouping:remote.filter { $0.identity != nil },by: { $0.identity!.albumKey })
        return try albums.keys.sorted().map { key in
            let songs = albums[key]!.sorted { $0.identity.disc == $1.identity.disc ? $0.identity.number < $1.identity.number : $0.identity.disc < $1.identity.disc }
            guard Set(songs.map { $0.identity.key }).count == songs.count else { throw SyncFailure(message:"В альбоме «\(songs[0].identity.album)» повторяются композиции. Уточните номера дисков и дорожек перед синхронизацией.") }
            let old = onPhone[key] ?? []
            var remaining = old
            for song in songs { if let i = remaining.firstIndex(where: { $0.identity!.matches(song.identity) }) { remaining.remove(at:i) } else { return SyncDecision(key:key,local:songs,old:old,replace:true) } }
            let changedSource = journal.albums[key].map { $0.signature != signature(songs) } ?? false
            return SyncDecision(key:key,local:songs,old:old,replace:!remaining.isEmpty || changedSource || old.contains { !$0.compatible })
        }
    }
    static func component(_ s: String) -> String {
        let cleaned = s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || "/\\:".unicodeScalars.contains($0) ? "_" : String($0) }.joined().trimmingCharacters(in:.whitespacesAndNewlines)
        var value=""; for character in cleaned { let candidate=value+String(character); if candidate.utf8.count > 180 { break }; value=candidate }; return value.isEmpty || value == "." || value == ".." ? "Без названия" : value
    }
}

protocol SyncStore: AnyObject {
    func list(_ parent: UInt32) throws -> [SyncRemote]
    func folder(_ name: String, _ parent: UInt32) throws -> UInt32
    func upload(_ file: URL, _ parent: UInt32, _ progress: @escaping (Double)->Void) throws
    func rename(_ entry: SyncRemote, _ name: String) throws
    func move(_ entry: SyncRemote, _ parent: UInt32) throws
    func delete(_ entry: SyncRemote) throws
    func cleanup(_ folder: UInt32)
}
extension SyncStore {
    func cleanup(_ folder: UInt32) { for e in (try? list(folder)) ?? [] { try? delete(e) } }
}
final class MTPSyncStore: SyncStore {
    let session: PTSession, storage: UInt32, control: SyncControl
    init(_ session: PTSession, _ storage: UInt32, _ control: SyncControl) { self.session=session; self.storage=storage; self.control=control }
    func cleanup(_ folder: UInt32) {
        // Cancellation stops user work, but must not prevent cleanup of our own unpublished files.
        let cleanup=MTPSyncStore(session,storage,SyncControl())
        for e in (try? cleanup.list(folder)) ?? [] { try? cleanup.delete(e) }
    }
    func native(_ entry: SyncRemote) -> PTEntry {
        let e=PTEntry(); e.identifier=entry.id; e.name=entry.name; e.size=entry.size; e.modifiedSeconds=entry.modified; e.folder=entry.folder; return e
    }
    func list(_ parent: UInt32) throws -> [SyncRemote] {
        try control.check()
        return try session.contents(ofStorage:storage,parent:parent).map { SyncRemote(id:$0.identifier,parent:parent,name:$0.name,size:$0.size,modified:$0.modifiedSeconds,identity:nil,folder:$0.folder) }
    }
    func folder(_ name: String, _ parent: UInt32) throws -> UInt32 { try control.check(); return try session.ensureFolder(name,storage:storage,parent:parent).uint32Value }
    func upload(_ file: URL, _ parent: UInt32, _ progress: @escaping (Double)->Void) throws {
        try control.check(); try session.uploadFile(file,storage:storage,parent:parent) { [control] sent,total in progress(total > 0 ? Double(sent)/Double(total) : 0); return !control.cancelled }
    }
    func rename(_ entry: SyncRemote, _ name: String) throws { try control.check(); try session.renameEntry(native(entry),storage:storage,parent:entry.parent,name:name) }
    func move(_ entry: SyncRemote, _ parent: UInt32) throws { try control.check(); try session.move(native(entry),storage:storage,parent:entry.parent,destination:parent) }
    func delete(_ entry: SyncRemote) throws { try control.check(); try session.delete(native(entry),storage:storage,parent:entry.parent) }
}

// Publish the complete verified replacement before deleting any old audio. Unknown files are never deleted.
enum SyncTransaction {
    static func publish(store: SyncStore, music: UInt32, artist: String, album: String, files: [URL], old: [SyncRemote], progress: @escaping (Int,Double)->Void) throws -> [SyncRemote] {
        let token = UUID().uuidString
        let staging = try store.folder(".iTunes-incoming-"+token,music)
        var published = false
        do {
            for (i,file) in files.enumerated() { try store.upload(file,staging) { progress(i,$0) } }
            let staged = try store.list(staging)
            guard staged.count == files.count, files.allSatisfy({ file in staged.contains { $0.name == file.lastPathComponent && $0.size == (try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize).map(UInt64.init) } }) else { throw SyncFailure(message:"Проверка новой копии альбома не пройдена. Старый альбом сохранён.") }
            let destination = try store.folder(SyncPlanner.component(artist),music)
            let names = Set(try store.list(destination).map(\.name))
            let base = SyncPlanner.component(album)
            // Existing folders may contain covers, playlists or another album: never rename/delete them wholesale.
            var name=base; var suffix=1
            while names.contains(name) { name = base + " (iTunes \(suffix))"; suffix += 1 }
            try store.rename(SyncRemote(id:staging,parent:music,name:".iTunes-incoming-"+token,size:0,modified:0,identity:nil,folder:true),name)
            try store.move(SyncRemote(id:staging,parent:music,name:name,size:0,modified:0,identity:nil,folder:true),destination)
            published = true
            // A disconnect during this phase leaves the full new album plus any undeleted old tracks.
            for entry in old { try store.delete(entry) }
            return try store.list(staging)
        } catch {
            // Preserve old audio. Best-effort cleanup only of files just created by this transaction.
            if !published { store.cleanup(staging) }
            throw error
        }
    }
}

struct SyncReport { var unchanged=0; var updated=0; var copied=0; var converted=0 }
final class AndroidSyncEngine: @unchecked Sendable {
    let control: SyncControl
    init(control: SyncControl) { self.control=control }
    func run(tracks: [Track], progress: @escaping @Sendable (String,Double)->Void) async throws -> SyncReport {
        guard tracks.contains(where: { !$0.isVideo }) else { throw SyncFailure(message:"В медиатеке нет аудиокомпозиций для синхронизации.") }
        let session=PTSession(); defer { session.disconnect() }
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else { throw SyncFailure(message:"Синхронизация Android в этой сборке требует macOS 27 или новее (библиотеки PixelTransfer).") }
        progress("Подключение к Android…",0)
        try session.connect()
        let storages=try session.storages()
        guard let storage=storages.first(where: { $0.writable }) else { throw SyncFailure(message:"На телефоне нет доступного для записи хранилища.") }
        let store=MTPSyncStore(session,storage.identifier,control)
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("iTunes-sync-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temp) }
        let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("iTunes Prototype/AndroidSync")
        try FileManager.default.createDirectory(at:support,withIntermediateDirectories:true)
        // Serial number scopes the source-change journal to this physical device, not its friendly name.
        let serial=session.deviceIdentifier
        let journalURL=support.appendingPathComponent(SyncPlanner.digest(Data((serial+":"+String(storage.identifier)).utf8))+".json")
        var journal = !serial.isEmpty ? (try? JSONDecoder().decode(SyncJournal.self,from:Data(contentsOf:journalURL))) ?? SyncJournal() : SyncJournal()
        func save() throws { if !serial.isEmpty { try JSONEncoder().encode(journal).write(to:journalURL,options:.atomic) } }
        let root: UInt32 = UInt32.max
        let roots=try session.contents(ofStorage:storage.identifier,parent:root)
        let musicEntry=roots.first { $0.name == "Music" }
        if let musicEntry, !musicEntry.folder { throw SyncFailure(message:"Music на телефоне является файлом, а не папкой.") }
        var remote: [SyncRemote] = []
        if let musicEntry {
            var stack=[musicEntry.identifier]; var visited=Set<UInt32>()
            while let parent=stack.popLast() {
                try control.check()
                guard visited.insert(parent).inserted else { throw SyncFailure(message:"Обнаружен повтор папки в хранилище телефона.") }
                let entries=try session.contents(ofStorage:storage.identifier,parent:parent)
                guard Set(entries.map(\.name)).count == entries.count else { throw SyncFailure(message:"На телефоне есть совпадающие имена в одной папке. Синхронизация остановлена.") }
                for e in entries {
                    if e.folder {
                        // Interrupted MTP sends can leave partial audio with otherwise valid tags/duration.
                        // Never adopt it as a completed album; the next run prepares a fresh version.
                        if e.name.hasPrefix(".iTunes-incoming-") { continue }
                        stack.append(e.identifier); continue
                    }
                    guard SyncPlanner.audioExtensions.contains(URL(fileURLWithPath:e.name).pathExtension.lowercased()) else { continue }
                    progress("\(session.deviceName): проверка «\(e.name)»",0)
                    if let cached=journal.inventory[String(e.identifier)], cached.matches(e,parent:parent) {
                        remote.append(SyncRemote(id:e.identifier,parent:parent,name:e.name,size:e.size,modified:e.modifiedSeconds,identity:cached.identity,compatible:cached.compatible)); continue
                    }
                    let dir=temp.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
                    let fd=open(dir.path,O_RDONLY|O_DIRECTORY|O_CLOEXEC); guard fd >= 0 else { throw SyncFailure(message:"Не удалось подготовить временную папку.") }
                    do { try session.downloadFile(e.identifier,storage:storage.identifier,size:e.size,directoryFD:fd,name:e.name) { [control] _,_ in !control.cancelled }; close(fd) } catch { close(fd); throw error }
                    let url=dir.appendingPathComponent(e.name)
                    let identity=try await Self.readIdentity(url)
                    let ext=url.pathExtension.lowercased()
                    let compatible = !["aif","aiff","aifc","alac","wma"].contains(ext) && (ext != "m4a" || (try? AVAudioFile(forReading:url).fileFormat.settings[AVFormatIDKey] as? UInt32) == kAudioFormatMPEG4AAC)
                    try FileManager.default.removeItem(at:dir)
                    journal.inventory[String(e.identifier)]=SyncCachedSong(parent:parent,name:e.name,size:e.size,modified:e.modifiedSeconds,identity:identity,compatible:compatible)
                    remote.append(SyncRemote(id:e.identifier,parent:parent,name:e.name,size:e.size,modified:e.modifiedSeconds,identity:identity,compatible:compatible))
                }
            }
        }
        journal.inventory=journal.inventory.filter { key,_ in remote.contains { String($0.id) == key } }; try save()
        let audio=tracks.filter { !$0.isVideo }
        var local: [SyncLocal] = []
        for (i,t) in audio.enumerated() {
            try control.check(); progress("Проверка медиатеки: \(i+1) из \(audio.count)",0)
            guard let path=t.path, FileManager.default.isReadableFile(atPath:path), t.duration.isFinite, t.duration > 0 else { throw SyncFailure(message:"Исходник «\(t.title)» недоступен. Синхронизация остановлена до изменения телефона.") }
            let url=URL(fileURLWithPath:path)
            guard SyncPlanner.audioExtensions.contains(url.pathExtension.lowercased()) else { throw SyncFailure(message:"Неизвестный аудиоформат: \(url.lastPathComponent)") }
            let handle=try FileHandle(forReadingFrom:url); defer { try? handle.close() }
            var hash=SHA256()
            while let block=try handle.read(upToCount:1024*1024), !block.isEmpty { try control.check(); hash.update(data:block) }
            let fingerprint=hash.finalize().map { String(format:"%02x",$0) }.joined()
            local.append(SyncLocal(track:t,identity:SyncIdentity(t),fingerprint:fingerprint))
        }
        let plan=try SyncPlanner.plan(local,remote,journal:journal)
        var report=SyncReport()
        // Inventory and local validation complete before the first phone write.
        let music=try store.folder("Music",root)
        for (albumIndex,decision) in plan.enumerated() {
            try control.check()
            if !decision.replace { report.unchanged += 1; journal.albums[decision.key]=SyncReceipt(signature:SyncPlanner.signature(decision.local),remote:decision.old.map(\.id),sizes:decision.old.map(\.size)); try save(); continue }
            let first=decision.local[0].identity
            let exportFolder=temp.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:exportFolder,withIntermediateDirectories:true)
            var prepared: [URL] = []
            for (i,song) in decision.local.enumerated() {
                try control.check(); progress("Подготовка «\(first.album)»: \(i+1) из \(decision.local.count)",Double(albumIndex)/Double(max(1,plan.count)))
                let source=URL(fileURLWithPath:song.track.path!)
                let ext=source.pathExtension.lowercased()
                let embedded=try? await Self.readIdentity(source)
                let direct = ["mp3","aac","flac","ogg","opus","m4a"].contains(ext) && embedded.map { $0.albumKey == song.identity.albumKey && $0.matches(song.identity) } == true && (ext != "m4a" || (try? AVAudioFile(forReading:source).fileFormat.settings[AVFormatIDKey] as? UInt32) == kAudioFormatMPEG4AAC)
                let output=exportFolder.appendingPathComponent(String(format:"%02d-%03d ",song.identity.disc,i+1)+SyncPlanner.component(song.identity.title)).appendingPathExtension(direct ? ext : "m4a")
                if direct { try FileManager.default.copyItem(at:source,to:output) }
                else { try await convert(song.track,to:output); report.converted += 1 }
                let check=try await Self.readIdentity(output)
                guard check.albumKey == song.identity.albumKey && check.matches(song.identity) else { throw SyncFailure(message:"Теги подготовленной копии «\(song.identity.title)» не прошли проверку. Альбом на телефоне сохранён.") }
                prepared.append(output)
            }
            let bytes=try prepared.reduce(UInt64(0)) { $0 + UInt64(try $1.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) }
            guard let free=try session.storages().first(where: { $0.identifier == storage.identifier })?.freeBytes, free >= bytes else { throw SyncFailure(message:"Недостаточно места для новой копии «\(first.album)». Старый альбом сохранён.") }
            progress("Копирование «\(first.album)»…",Double(albumIndex)/Double(max(1,plan.count)))
            let uploaded=try SyncTransaction.publish(store:store,music:music,artist:first.albumArtist,album:first.album,files:prepared,old:decision.old) { i,fraction in
                progress("«\(first.album)»: \(i+1) из \(prepared.count)",(Double(albumIndex)+(Double(i)+fraction)/Double(prepared.count))/Double(max(1,plan.count)))
            }
            report.updated += 1; report.copied += prepared.count
            journal.albums[decision.key]=SyncReceipt(signature:SyncPlanner.signature(decision.local),remote:uploaded.map(\.id),sizes:uploaded.map(\.size)); try save()
            try FileManager.default.removeItem(at:exportFolder)
        }
        progress("Готово: \(report.copied) файлов, обновлено альбомов: \(report.updated), уже есть: \(report.unchanged).",1)
        return report
    }
    static func readIdentity(_ url: URL) async throws -> SyncIdentity {
        guard let data=await ImportedMetadata.read(url), let title=Track.nonempty(data.fields[.title]), let artist=Track.nonempty(data.fields[.artist]), let album=Track.nonempty(data.fields[.album]) else { throw SyncFailure(message:"Не удалось определить композицию «\(url.lastPathComponent)» на телефоне. Заполните название, исполнителя и альбом в тегах. Телефон не изменён.") }
        let duration=(try? await AVURLAsset(url:url).load(.duration).seconds) ?? 0
        guard duration.isFinite, duration > 0 else { throw SyncFailure(message:"Не удалось прочитать длительность «\(url.lastPathComponent)». Синхронизация остановлена.") }
        var track=Track(id:"phone",title:title,artist:artist,album:album,genre:"—",duration:duration,number:Int(data.fields[.number] ?? "") ?? 0)
        track.albumArtist=data.fields[.albumArtist]; track.discNumber=Int(data.fields[.discNumber] ?? ""); track.isCompilation=data.fields[.isCompilation] == "1"
        var identity=SyncIdentity(track); identity.disc=Int(data.fields[.discNumber] ?? "") ?? 0; return identity
    }
    func convert(_ track: Track, to output: URL) async throws {
        // AVAssetExportSession cannot reliably decode AIFF on all macOS versions.
        // Stream through Core Audio into a bounded PCM/WAV intermediate first; originals stay untouched.
        let normalized=output.deletingLastPathComponent().appendingPathComponent(".pcm-"+UUID().uuidString+".wav")
        defer { try? FileManager.default.removeItem(at:normalized) }
        let source=try AVAudioFile(forReading:URL(fileURLWithPath:track.path!))
        guard source.processingFormat.channelCount <= 2 else { throw SyncFailure(message:"«\(track.title)»: для AAC-копии поддерживается моно или стерео.") }
        do {
            let writer=try AVAudioFile(forWriting:normalized,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:source.processingFormat.sampleRate,AVNumberOfChannelsKey:source.processingFormat.channelCount,AVLinearPCMBitDepthKey:16,AVLinearPCMIsBigEndianKey:false,AVLinearPCMIsFloatKey:false])
            guard let buffer=AVAudioPCMBuffer(pcmFormat:source.processingFormat,frameCapacity:32768) else { throw SyncFailure(message:"Не удалось подготовить звуковой буфер.") }
            while source.framePosition < source.length { try control.check(); try source.read(into:buffer); if buffer.frameLength == 0 { break }; try writer.write(from:buffer) }
        }
        let asset=AVURLAsset(url:normalized)
        guard let exporter=AVAssetExportSession(asset:asset,presetName:AVAssetExportPresetAppleM4A) else { throw SyncFailure(message:"Не удалось подготовить AAC-копию «\(track.title)».") }
        exporter.outputURL=output; exporter.outputFileType = .m4a
        var items: [AVMetadataItem] = []
        for (identifier,value) in [(AVMetadataIdentifier.commonIdentifierTitle,track.title),(.commonIdentifierArtist,track.artist),(.commonIdentifierAlbumName,track.album),(.iTunesMetadataAlbumArtist,track.albumDisplayArtist)] {
            let item=AVMutableMetadataItem(); item.identifier=identifier; item.value=value as NSString; items.append(item)
        }
        for (identifier,n) in [(AVMetadataIdentifier.iTunesMetadataTrackNumber,track.number),(.iTunesMetadataDiscNumber,track.discNumber ?? 1)] {
            let item=AVMutableMetadataItem(); item.identifier=identifier; item.value=Data([0,0,UInt8(clamping:n >> 8),UInt8(clamping:n & 255),0,0,0,0]) as NSData; item.dataType=kCMMetadataBaseDataType_RawData as String; items.append(item)
        }
        if let artwork=track.artworkData { let item=AVMutableMetadataItem(); item.identifier = .commonIdentifierArtwork; item.value=artwork as NSData; items.append(item) }
        exporter.metadata=items
        let monitor=Task { [control] in while !Task.isCancelled { if control.cancelled { exporter.cancelExport(); return }; try? await Task.sleep(nanoseconds:100_000_000) } }
        defer { monitor.cancel() }
        await exporter.export()
        try control.check()
        guard exporter.status == .completed else { throw exporter.error ?? SyncFailure(message:"Не удалось преобразовать «\(track.title)» в AAC. Старый альбом сохранён.") }
    }
}

@MainActor final class AndroidSyncSurface: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect:NSRect) { gradient(bounds,0xF3F3F3,0xE6E6E6) }
}
@MainActor final class AndroidSyncWindow: NSWindowController, NSWindowDelegate {
    let library: Library
    let status=NSTextField(wrappingLabelWithString:"Подключите телефон по USB и выберите «Передача файлов». Закройте PixelTransfer, чтобы освободить подключение.")
    let bar=NSProgressIndicator()
    var start: EditorButton!, cancel: EditorButton!
    var control: SyncControl?
    var running=false
    var task: Task<Void,Never>?
    var onClose: (() -> Void)?
    init(library: Library) {
        self.library=library
        let body=AndroidSyncSurface(frame:NSRect(x:0,y:0,width:520,height:230))
        let panel=NSPanel(contentRect:body.bounds,styleMask:[.titled,.closable],backing:.buffered,defer:false)
        super.init(window:panel); panel.appearance=NSAppearance(named:.aqua); panel.isReleasedWhenClosed=false; panel.delegate=self
        let title=NSTextField(labelWithString:"Музыка на Android"); title.font=font(17,bold:true); title.frame=NSRect(x:24,y:20,width:470,height:26); body.addSubview(title)
        status.font=font(12); status.frame=NSRect(x:24,y:60,width:472,height:72); body.addSubview(status)
        bar.isIndeterminate=false; bar.minValue=0; bar.maxValue=1; bar.frame=NSRect(x:24,y:145,width:472,height:14); body.addSubview(bar)
        start=EditorButton("Синхронизировать",label:"Синхронизировать музыку с Android") { [weak self] in self?.sync() }; start.aqua=true; start.frame=NSRect(x:310,y:183,width:186,height:25); body.addSubview(start)
        cancel=EditorButton("Отмена",label:"Отменить синхронизацию") { [weak self] in self?.control?.cancel() }; cancel.frame=NSRect(x:210,y:183,width:90,height:25); cancel.isEnabled=false; body.addSubview(cancel)
        ClassicWindowChrome.install(on:panel,body:body,title:"Синхронизация Android"); panel.center()
    }
    required init?(coder:NSCoder) { fatalError() }
    func sync() {
        guard !running else { return }; running=true; start.isEnabled=false; cancel.isEnabled=true
        let control=SyncControl(); self.control=control; let tracks=library.tracks
        let receiver: @Sendable (String,Double)->Void = { [weak self] message,fraction in Task { @MainActor [weak self] in self?.status.stringValue=message; self?.bar.doubleValue=fraction } }
        task=Task { [weak self] in
            do {
                let result=try await Task.detached { try await AndroidSyncEngine(control:control).run(tracks:tracks,progress:receiver) }.value
                self?.status.stringValue="Готово. Добавлено файлов: \(result.copied). Обновлено альбомов: \(result.updated). Уже есть: \(result.unchanged). AAC-копий: \(result.converted)."
                self?.bar.doubleValue=1
            } catch {
                self?.status.toolTip=error.localizedDescription
                self?.status.stringValue=control.cancelled ? "Синхронизация отменена. Завершённые альбомы сохранены; при повторе будут проверены заново." : error.localizedDescription
            }
            self?.running=false; self?.start.isEnabled=true; self?.cancel.isEnabled=false; self?.control=nil
        }
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool { if running { control?.cancel(); status.stringValue="Остановка передачи…"; return false }; return true }
    func windowWillClose(_ notification:Notification) { onClose?() }
}

final class MemorySyncStore: SyncStore {
    var entries: [UInt32:SyncRemote] = [:]
    var next: UInt32=10
    var uploadFailure: Int?, uploads=0, moveFailure=false, deleteFailure=false
    var events: [String] = []
    func list(_ parent: UInt32) throws -> [SyncRemote] { entries.values.filter { $0.parent == parent } }
    func folder(_ name: String,_ parent: UInt32) throws -> UInt32 {
        if let e=try list(parent).first(where: { $0.name == name }) { guard e.folder else { throw SyncFailure(message:"Folder conflict") }; return e.id }
        next += 1; entries[next]=SyncRemote(id:next,parent:parent,name:name,size:0,modified:0,identity:nil,folder:true); return next
    }
    func upload(_ file: URL,_ parent: UInt32,_ progress: @escaping (Double)->Void) throws {
        uploads += 1; if uploads == uploadFailure { throw SyncFailure(message:"Cable disconnected") }
        next += 1; entries[next]=SyncRemote(id:next,parent:parent,name:file.lastPathComponent,size:UInt64(try file.resourceValues(forKeys:[.fileSizeKey]).fileSize!),modified:0,identity:nil); events.append("upload"); progress(1)
    }
    func rename(_ entry:SyncRemote,_ name:String) throws { let old=entries[entry.id]!; entries[entry.id]=SyncRemote(id:old.id,parent:old.parent,name:name,size:old.size,modified:old.modified,identity:old.identity,folder:old.folder); events.append("rename") }
    func move(_ entry:SyncRemote,_ parent:UInt32) throws {
        if moveFailure { throw SyncFailure(message:"Move failed") }
        let old=entries[entry.id]!; entries[entry.id]=SyncRemote(id:old.id,parent:parent,name:old.name,size:old.size,modified:old.modified,identity:old.identity,folder:old.folder); events.append("publish")
    }
    func delete(_ entry:SyncRemote) throws { if deleteFailure { throw SyncFailure(message:"Delete failed") }; entries.removeValue(forKey:entry.id); events.append("delete") }
}
@MainActor func testAndroidSync(track fixture: Track,root: URL) async throws {
    var a=fixture; a.title="First"; a.album="CONFESSIONS II"; a.artist="Madonna"; a.albumArtist="Madonna"; a.number=1
    var b=a; b.id="second"; b.title="Second"; b.number=2
    let songs=[a,b].map { SyncLocal(track:$0,identity:SyncIdentity($0),fingerprint:"aiff-source-"+$0.id) }
    var remote=songs.enumerated().map { i,s in SyncRemote(id:UInt32(i+1),parent:50,name:"\(i+1).mp3",size:123,modified:1,identity:s.identity) }
    let adopted=try SyncPlanner.plan(songs,remote,journal:SyncJournal()); precondition(adopted.allSatisfy { !$0.replace })
    var unnumbered=remote; unnumbered[0].identity!.number=0; unnumbered[0].identity!.disc=0
    let withoutNumbers=try SyncPlanner.plan(songs,unnumbered,journal:SyncJournal()); precondition(!withoutNumbers[0].replace)
    let entry=PTEntry(); entry.identifier=1; entry.name="1.mp3"; entry.size=123; entry.modifiedSeconds=4
    let cache=SyncCachedSong(parent:50,name:entry.name,size:123,modified:4,identity:songs[0].identity)
    precondition(cache.matches(entry,parent:50)); entry.size=124; precondition(!cache.matches(entry,parent:50))
    entry.size=123; entry.modifiedSeconds=5; precondition(!cache.matches(entry,parent:50))
    var unsupported=remote; unsupported[0].compatible=false
    let unsupportedPlan=try SyncPlanner.plan(songs,unsupported,journal:SyncJournal()); precondition(unsupportedPlan[0].replace)
    let missing=try SyncPlanner.plan(songs,[remote[0]],journal:SyncJournal()); precondition(missing[0].replace && missing[0].old.count == 1)
    let extra=try SyncPlanner.plan([songs[0]],remote,journal:SyncJournal()); precondition(extra[0].replace)
    remote[0].identity!.duration += 10
    let durationChange=try SyncPlanner.plan(songs,remote,journal:SyncJournal()); precondition(durationChange[0].replace)
    remote[0].identity=songs[0].identity
    var journal=SyncJournal(); journal.albums[songs[0].identity.albumKey]=SyncReceipt(signature:"older-source",remote:[1,2],sizes:[123,123])
    let sourceChange=try SyncPlanner.plan(songs,remote,journal:journal); precondition(sourceChange[0].replace)
    precondition(SyncPlanner.component("../A:B/C") == ".._A_B_C")
    let file=root.appendingPathComponent("sync-test.mp3"); try Data([1,2,3]).write(to:file)
    for mode in 0...3 {
        let store=MemorySyncStore(); store.entries[1]=remote[0]
        if mode == 1 { store.uploadFailure=1 }; if mode == 2 { store.moveFailure=true }; if mode == 3 { store.deleteFailure=true }
        do {
            let result=try SyncTransaction.publish(store:store,music:100,artist:"Madonna",album:"CONFESSIONS II",files:[file],old:[remote[0]]) { _,_ in }
            precondition(mode == 0 && result.count == 1 && store.entries[1] == nil)
        } catch { precondition(mode != 0 && store.entries[1] != nil) }
        if let deletion=store.events.firstIndex(of:"delete"), mode == 0 { precondition(store.events.firstIndex(of:"publish")! < deletion) }
        if mode == 1 || mode == 2 { precondition(!store.events.contains("publish") && store.entries[1] != nil) }
        if mode == 3 { precondition(store.events.contains("publish")) }
    }
    let input=try AVAudioFile(forReading:URL(fileURLWithPath:fixture.path!))
    let buffer=AVAudioPCMBuffer(pcmFormat:input.processingFormat,frameCapacity:AVAudioFrameCount(input.length))!
    try input.read(into:buffer)
    let aiff=root.appendingPathComponent("Android AIFF source.aiff")
    do {
    let writer=try AVAudioFile(forWriting:aiff,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:input.fileFormat.sampleRate,AVNumberOfChannelsKey:input.fileFormat.channelCount,AVLinearPCMBitDepthKey:16,AVLinearPCMIsBigEndianKey:true,AVLinearPCMIsFloatKey:false])
    try writer.write(from:buffer)
    }
    var conversion=a; conversion.path=aiff.path
    let output=root.appendingPathComponent("android-copy.m4a")
    try await AndroidSyncEngine(control:SyncControl()).convert(conversion,to:output)
    let identity=try await AndroidSyncEngine.readIdentity(output)
    precondition(identity.albumKey == songs[0].identity.albumKey && identity.matches(songs[0].identity))
    let format=try AVAudioFile(forReading:output).fileFormat.settings[AVFormatIDKey] as? UInt32; precondition(format == kAudioFormatMPEG4AAC)
    let control=SyncControl(); control.cancel(); do { try control.check(); preconditionFailure() } catch {}
    print("PASS: Android cross-format album adoption, added/removed/changed tracks, source fingerprint, staged publish before delete, USB/upload/move/delete failures, cancellation and actual AIFF-to-AAC conversion with tags")
}
