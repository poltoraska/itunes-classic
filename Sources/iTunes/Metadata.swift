import AppKit
import AVFoundation

enum MetadataField: String, CaseIterable {
    case title, artist, album, albumArtist, composer, grouping, genre, year
    case number, trackTotal, discNumber, discTotal, bpm, comments, lyrics, isCompilation
    case sortTitle, sortArtist, sortAlbum, sortAlbumArtist, sortComposer
    case volumeAdjustment, startTime, stopTime, skipShuffle
    var label: String {
        switch self {
        case .title: return "Название"
        case .artist: return "Исполнитель трека"
        case .album: return "Альбом"
        case .albumArtist: return "Исполнитель альбома"
        case .composer: return "Композитор"
        case .grouping: return "Группировка"
        case .genre: return "Жанр"
        case .year: return "Год"
        case .number: return "Дорожка"
        case .trackTotal: return "Всего дорожек"
        case .discNumber: return "Номер диска"
        case .discTotal: return "Всего дисков"
        case .bpm: return "Ударов в минуту"
        case .comments: return "Комментарии"
        case .lyrics: return "Текст песни"
        case .isCompilation: return "Альбом является сборником"
        case .sortTitle: return "Название для сортировки"
        case .sortArtist: return "Исполнитель для сортировки"
        case .sortAlbum: return "Альбом для сортировки"
        case .sortAlbumArtist: return "Исполнитель альбома для сортировки"
        case .sortComposer: return "Композитор для сортировки"
        case .volumeAdjustment: return "Коррекция громкости, %"
        case .startTime: return "Начало, мин:сек"
        case .stopTime: return "Конец, мин:сек"
        case .skipShuffle: return "Пропускать при перемешивании"
        }
    }
}
enum ArtworkEdit { case unchanged, replace(Data), remove }
struct MetadataPatch {
    var fields: [MetadataField: String] = [:]
    var artwork: ArtworkEdit = .unchanged
    var resetPlays = false
}
struct MetadataError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
extension Track {
    func value(_ key: MetadataField) -> String {
        func number(_ value: Int?) -> String { value.map(String.init) ?? "" }
        switch key {
        case .title: return title
        case .artist: return artist
        case .album: return album
        case .albumArtist: return albumArtist ?? inferredAlbumArtist ?? ""
        case .composer: return composer ?? ""
        case .grouping: return grouping ?? ""
        case .genre: return genre == "—" ? "" : genre
        case .year: return number(year)
        case .number: return self.number > 0 ? String(self.number) : ""
        case .trackTotal: return number(trackTotal)
        case .discNumber: return number(discNumber)
        case .discTotal: return number(discTotal)
        case .bpm: return number(bpm)
        case .comments: return comments ?? ""
        case .lyrics: return lyrics ?? ""
        case .isCompilation: return isCompilation == true ? "1" : "0"
        case .sortTitle: return sortTitle ?? ""
        case .sortArtist: return sortArtist ?? ""
        case .sortAlbum: return sortAlbum ?? ""
        case .sortAlbumArtist: return sortAlbumArtist ?? ""
        case .sortComposer: return sortComposer ?? ""
        case .volumeAdjustment: return volumeAdjustment.map { String(Int($0)) } ?? "0"
        case .startTime: return startTime.map(timeString) ?? ""
        case .stopTime: return stopTime.map(timeString) ?? ""
        case .skipShuffle: return skipShuffle == true ? "1" : "0"
        }
    }
    mutating func setValue(_ raw: String, for key: MetadataField) throws {
        let value = [.lyrics, .comments].contains(key) ? raw : raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let optional = value.isEmpty ? nil : value
        func integer() throws -> Int? {
            if value.isEmpty { return nil }
            guard let n = Int(value), (0...9999).contains(n) else { throw MetadataError(message: "«\(key.label)»: введите целое число от 0 до 9999.") }
            return n
        }
        func seconds() throws -> Double? {
            if value.isEmpty { return nil }
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2, let last = Double(parts.last ?? ""), last >= 0 else { throw MetadataError(message: "«\(key.label)»: укажите время в формате мин:сек.") }
            if parts.count == 2 {
                guard let minutes = Double(parts[0]), minutes >= 0, last < 60 else { throw MetadataError(message: "Некорректное время: \(value)") }
                return minutes * 60 + last
            }
            return last
        }
        switch key {
        case .title, .artist, .album:
            guard !value.isEmpty else { throw MetadataError(message: "Поле «\(key.label)» не может быть пустым.") }
            if key == .title { title = value }; if key == .artist { artist = value }; if key == .album { album = value }
        case .albumArtist: albumArtist = optional
        case .composer: composer = optional
        case .grouping: grouping = optional
        case .genre: genre = optional ?? "—"
        case .year: year = try integer()
        case .number: number = try integer() ?? 0
        case .trackTotal: trackTotal = try integer()
        case .discNumber: discNumber = try integer()
        case .discTotal: discTotal = try integer()
        case .bpm: bpm = try integer()
        case .comments: comments = optional
        case .lyrics: lyrics = optional
        case .isCompilation: isCompilation = value == "1"
        case .sortTitle: sortTitle = optional
        case .sortArtist: sortArtist = optional
        case .sortAlbum: sortAlbum = optional
        case .sortAlbumArtist: sortAlbumArtist = optional
        case .sortComposer: sortComposer = optional
        case .volumeAdjustment:
            guard let amount = Double(value), amount.isFinite, (-100...100).contains(amount) else { throw MetadataError(message: "Коррекция громкости должна быть от −100 до 100 %.") }
            volumeAdjustment = amount
        case .startTime: startTime = try seconds()
        case .stopTime: stopTime = try seconds()
        case .skipShuffle: skipShuffle = value == "1"
        }
    }
    func validatePlaybackRange() throws {
        let start = startTime ?? 0; let stop = stopTime ?? duration
        guard start >= 0, start < duration, stop > start, stop <= duration + 0.05 else { throw MetadataError(message: "«\(title)»: начало должно быть раньше конца и находиться внутри композиции (\(timeString(duration))).") }
        if let total = trackTotal, total > 0, number > total { throw MetadataError(message: "«\(title)»: номер дорожки больше общего количества.") }
        if let disc = discNumber, let total = discTotal, total > 0, disc > total { throw MetadataError(message: "Номер диска больше общего количества дисков.") }
    }
}

@MainActor extension Library {
    /// Persist the candidate first. A failed atomic write leaves the in-memory library unchanged.
    func metadataCandidate(_ patch: MetadataPatch, to ids: Set<String>) throws -> [Track] {
        guard !importingFiles else { throw MetadataError(message:"Дождитесь завершения импорта файлов.") }
        guard !ids.isEmpty, ids.isSubset(of: Set(tracks.map(\.id))) else { throw MetadataError(message: "Выбранные композиции больше не доступны.") }
        var candidate = tracks
        for i in candidate.indices where ids.contains(candidate[i].id) {
            for (key, value) in patch.fields {
                try candidate[i].setValue(value, for: key)
                candidate[i].metadataOverrides = (candidate[i].metadataOverrides ?? []).union([key.rawValue])
            }
            switch patch.artwork {
            case .unchanged: break
            case .replace(let data):
                guard NSImage(data: data) != nil else { throw MetadataError(message: "Не удалось прочитать изображение обложки.") }
                candidate[i].artwork = data; candidate[i].artworkPath = nil
                candidate[i].metadataOverrides = (candidate[i].metadataOverrides ?? []).union(["artwork"])
            case .remove:
                candidate[i].artwork = nil; candidate[i].artworkPath = nil
                candidate[i].metadataOverrides = (candidate[i].metadataOverrides ?? []).union(["artwork"])
            }
            if patch.resetPlays { candidate[i].plays = 0 }
            try candidate[i].validatePlaybackRange()
        }
        Self.reconcileAlbumArtists(&candidate)
        return candidate
    }
    func apply(_ patch: MetadataPatch, to ids: Set<String>) throws {
        let candidate=try metadataCandidate(patch,to:ids)
        let transaction=try ManagedEdit(old:tracks,candidate:candidate,ids:ids,patch:patch,root:mediaRoot)
        try commitManaged(transaction)
    }
    func applyPlayerSettings(smooth: Bool = false) {
        func adjusted(_ track: Track?) -> Float { min(1, max(0, volume * Float(1 + (track?.volumeAdjustment ?? 0) / 100))) }
        player?.setVolume(adjusted(current) * incomingGain, fadeDuration: smooth ? 1 / 30 : 0)
        outgoingPlayer?.setVolume(adjusted(fadingTrack) * outgoingGain, fadeDuration: smooth ? 1 / 30 : 0)
        videoPlayer?.volume = adjusted(current)
    }
    func enforcePlaybackRange() {
        guard playing, let stop = current?.stopTime, playbackTime >= stop else { return }
        player?.stop(); videoPlayer?.pause(); advanceAfterFinish()
    }
}

/// AVFoundation exposes ID3 and iTunes tags in separate metadata formats, outside commonMetadata.
struct ImportedMetadata {
    var isExplicit: Bool?
    var fields: [MetadataField: String] = [:]
    static func read(_ url: URL) async -> ImportedMetadata? {
        if let native = NativeTags.read(url) { return native }
        let asset = AVURLAsset(url: url)
        let watchdog = Task {
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            asset.cancelLoading()
        }
        defer { watchdog.cancel() }
        let diagnostic = CommandLine.arguments.contains("--inspect-metadata")
        func trace(_ value: String) { if diagnostic { print(value); fflush(stdout) } }
        trace("readability " + String(FileManager.default.isReadableFile(atPath: url.path)))
        trace("metadata")
        guard let allItems = try? await asset.load(.metadata) else { return nil }
        var result = ImportedMetadata()
        for items in [allItems] {
            for item in items {
                trace("item " + (item.identifier?.rawValue ?? "unknown"))
                let id = item.identifier; let key = (item.key as? String)?.lowercased() ?? ""
                var field: MetadataField?
                switch id {
                case .iTunesMetadataAlbumArtist, .id3MetadataBand: field = .albumArtist
                case .iTunesMetadataUserGenre, .id3MetadataContentType: field = .genre
                case .iTunesMetadataComposer, .id3MetadataComposer, .quickTimeMetadataComposer, .quickTimeUserDataComposer: field = .composer
                case .iTunesMetadataGrouping: field = .grouping
                case .iTunesMetadataReleaseDate, .id3MetadataYear, .id3MetadataRecordingTime, .quickTimeMetadataYear: field = .year
                case .iTunesMetadataBeatsPerMin, .id3MetadataBeatsPerMinute: field = .bpm
                case .iTunesMetadataUserComment, .id3MetadataComments, .quickTimeMetadataComment: field = .comments
                case .iTunesMetadataLyrics, .id3MetadataUnsynchronizedLyric: field = .lyrics
                case .id3MetadataTitleSortOrder: field = .sortTitle
                case .id3MetadataPerformerSortOrder: field = .sortArtist
                case .id3MetadataAlbumSortOrder: field = .sortAlbum
                default: break
                }
                if field == nil {
                    let keys: [String: MetadataField] = ["albumartist": .albumArtist, "album_artist": .albumArtist, "tpe2": .albumArtist, "aart": .albumArtist, "genre": .genre, "©gen": .genre, "tcon": .genre, "composer": .composer, "grouping": .grouping, "tit1": .grouping, "©grp": .grouping, "date": .year, "year": .year, "sonm": .sortTitle, "soar": .sortArtist, "soal": .sortAlbum, "soaa": .sortAlbumArtist, "soco": .sortComposer, "tso2": .sortAlbumArtist, "tsoc": .sortComposer]
                    field = keys[key]
                }
                if let field, let raw = try? await item.load(.stringValue), let text = Track.nonempty(raw) {
                    if field == .genre { result.fields[field] = genre(text) }
                    else if field == .year { result.fields[field] = String(text.prefix(4)) }
                    else { result.fields[field] = text }
                }
                if id == .iTunesMetadataPredefinedGenre {
                    var index: Int?
                    if let data = try? await item.load(.dataValue), data.count >= 2 { index = Int(data[0]) * 256 + Int(data[1]) - 1 }
                    else if let n = try? await item.load(.numberValue) { index = n.intValue - 1 }
                    if result.fields[.genre] == nil, let index, genres.indices.contains(index) { result.fields[.genre] = genres[index] }
                }
                if id == .iTunesMetadataDiscCompilation || ["tcmp", "cpil", "compilation"].contains(key) {
                    if let n = try? await item.load(.numberValue) { result.fields[.isCompilation] = n.boolValue ? "1" : "0" }
                    else if let t = try? await item.load(.stringValue) { result.fields[.isCompilation] = ["1", "true", "yes"].contains(t.lowercased()) ? "1" : "0" }
                }
                let isTrack = id == .iTunesMetadataTrackNumber || id == .id3MetadataTrackNumber || ["trck", "trkn", "track", "tracknumber"].contains(key)
                let isDisc = id == .iTunesMetadataDiscNumber || id == .id3MetadataPartOfASet || ["tpos", "disk", "disc", "discnumber"].contains(key)
                if isTrack || isDisc {
                    let first: MetadataField = isTrack ? .number : .discNumber
                    let total: MetadataField = isTrack ? .trackTotal : .discTotal
                    if let t = try? await item.load(.stringValue), Int(t.split(separator: "/").first ?? "") != nil {
                        let parts = t.split(separator: "/")
                        result.fields[first] = String(parts[0]); if parts.count > 1 { result.fields[total] = String(parts[1]) }
                    } else if let data = try? await item.load(.dataValue), data.count >= 6 {
                        result.fields[first] = String(Int(data[2]) * 256 + Int(data[3]))
                        result.fields[total] = String(Int(data[4]) * 256 + Int(data[5]))
                    }
                }
            }
        }
        return result
    }
    static let genres = "Blues|Classic Rock|Country|Dance|Disco|Funk|Grunge|Hip-Hop|Jazz|Metal|New Age|Oldies|Other|Pop|R&B|Rap|Reggae|Rock|Techno|Industrial|Alternative|Ska|Death Metal|Pranks|Soundtrack|Euro-Techno|Ambient|Trip-Hop|Vocal|Jazz+Funk|Fusion|Trance|Classical|Instrumental|Acid|House|Game|Sound Clip|Gospel|Noise|AlternRock|Bass|Soul|Punk|Space|Meditative|Instrumental Pop|Instrumental Rock|Ethnic|Gothic|Darkwave|Techno-Industrial|Electronic|Pop-Folk|Eurodance|Dream|Southern Rock|Comedy|Cult|Gangsta|Top 40|Christian Rap|Pop/Funk|Jungle|Native American|Cabaret|New Wave|Psychedelic|Rave|Showtunes|Trailer|Lo-Fi|Tribal|Acid Punk|Acid Jazz|Polka|Retro|Musical|Rock & Roll|Hard Rock".components(separatedBy: "|")
    static func genre(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(value), genres.indices.contains(n) { return genres[n] }
        if value.hasPrefix("("), let end = value.firstIndex(of: ")"), let n = Int(value[value.index(after: value.startIndex)..<end]), genres.indices.contains(n) {
            let tail = String(value[value.index(after: end)...]).trimmingCharacters(in: .whitespaces)
            return tail.isEmpty ? genres[n] : tail
        }
        return value
    }
}


struct ManagedMedia {
    static func safe(_ name: String) -> String { SyncPlanner.component(name) }
    static func destination(_ track: Track, root: URL, excluding: Set<String> = []) -> URL {
        let ext=URL(fileURLWithPath:track.path ?? "audio.mp3").pathExtension.lowercased()
        let folder=root.appendingPathComponent(track.isVideo ? "Видео" : "Музыка").appendingPathComponent(safe(track.albumDisplayArtist)).appendingPathComponent(safe(track.album))
        let prefix=track.number > 0 ? String(format:"%02d-%02d ",track.discNumber ?? 1,track.number) : ""
        let base=folder.appendingPathComponent(prefix+safe(track.title)).appendingPathExtension(ext)
        var result=base; var i=1
        while FileManager.default.fileExists(atPath:result.path) && !excluding.contains(result.path) { result=folder.appendingPathComponent(prefix+safe(track.title)+" (\(track.id.prefix(8))-\(i))").appendingPathExtension(ext); i += 1 }
        return result
    }
    static func copyImport(_ track: Track, root: URL) throws -> Track {
        guard let path=track.path else { throw MetadataError(message:"Нет исходного файла.") }
        let source=URL(fileURLWithPath:path), output=destination(track,root:root)
        try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:source,to:output)
        var result=track; result.path=output.path; result.managedSourcePath=path; result.managedCopy=true
        return result
    }
    static func properties(_ track: Track, fields: Set<MetadataField>) -> [String:String] {
        var values=["TITLE":track.title,"ARTIST":track.artist,"ALBUM":track.album,"ALBUMARTIST":track.albumDisplayArtist]
        let names: [MetadataField:String]=[.genre:"GENRE",.year:"DATE",.composer:"COMPOSER",.grouping:"GROUPING",.comments:"COMMENT",.lyrics:"LYRICS",.bpm:"BPM",.sortTitle:"TITLESORT",.sortArtist:"ARTISTSORT",.sortAlbum:"ALBUMSORT",.sortAlbumArtist:"ALBUMARTISTSORT",.sortComposer:"COMPOSERSORT",.isCompilation:"COMPILATION"]
        for field in fields { if let name=names[field] { values[name]=track.value(field) } }
        if fields.contains(.number) || fields.contains(.trackTotal) { values["TRACKNUMBER"]=String(track.number)+(track.trackTotal.map { "/\($0)" } ?? "") }
        if fields.contains(.discNumber) || fields.contains(.discTotal) { values["DISCNUMBER"]=String(track.discNumber ?? 1)+(track.discTotal.map { "/\($0)" } ?? "") }
        return values
    }
}
final class ManagedEdit: @unchecked Sendable {
    struct FileChange { let old: URL; let staged: URL; let destination: URL; let backup: URL }
    var tracks: [Track]
    private let work: URL
    private var changes: [FileChange] = []
    private var published: [FileChange] = []
    init(old: [Track], candidate: [Track], ids: Set<String>, patch: MetadataPatch, root: URL) throws {
        tracks=candidate; work=root.appendingPathComponent(".edit-"+UUID().uuidString)
        let tagFields: Set<MetadataField> = [.title,.artist,.album,.albumArtist,.genre,.year,.composer,.grouping,.comments,.lyrics,.bpm,.sortTitle,.sortArtist,.sortAlbum,.sortAlbumArtist,.sortComposer,.isCompilation,.number,.trackTotal,.discNumber,.discTotal]
        var writeTags = !tagFields.isDisjoint(with:patch.fields.keys)
        switch patch.artwork { case .unchanged: break; case .remove,.replace: writeTags=true }
        let selected=candidate.filter { writeTags && ids.contains($0.id) && $0.managedCopy == true }
        guard !selected.isEmpty else { return }
        try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
        do {
            for track in selected {
                guard let prior=old.first(where: { $0.id == track.id }), let path=prior.path,
                    URL(fileURLWithPath:path).resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path+"/") else { throw MetadataError(message:"Файл находится вне управляемой медиатеки.") }
                let original=URL(fileURLWithPath:path)
                let staged=work.appendingPathComponent(track.id).appendingPathExtension(original.pathExtension)
                try FileManager.default.copyItem(at:original,to:staged)
                let art: Data?
                switch patch.artwork { case .unchanged: art=nil; case .remove: art=Data(); case .replace(let data): art=data }
                try ITManagedTags.write(staged,values:ManagedMedia.properties(track,fields:Set(patch.fields.keys)),artwork:art)
                let destination=ManagedMedia.destination(track,root:root,excluding:[path])
                let backup=work.appendingPathComponent("backup-"+track.id).appendingPathExtension(original.pathExtension)
                changes.append(FileChange(old:original,staged:staged,destination:destination,backup:backup))
                if let index=tracks.firstIndex(where: { $0.id == track.id }) { tracks[index].path=destination.path }
            }
        } catch { try? FileManager.default.removeItem(at:work); throw error }
    }
    func publish() throws {
        do {
            for change in changes {
                try FileManager.default.createDirectory(at:change.destination.deletingLastPathComponent(),withIntermediateDirectories:true)
                if change.destination == change.old { try FileManager.default.moveItem(at:change.old,to:change.backup) }
                do { try FileManager.default.moveItem(at:change.staged,to:change.destination); published.append(change) }
                catch { if FileManager.default.fileExists(atPath:change.backup.path) { try? FileManager.default.moveItem(at:change.backup,to:change.old) }; throw error }
            }
        } catch { rollback(); throw error }
    }
    func rollback() {
        for change in published.reversed() {
            if FileManager.default.fileExists(atPath:change.destination.path) { try? FileManager.default.removeItem(at:change.destination) }
            if FileManager.default.fileExists(atPath:change.backup.path) { try? FileManager.default.moveItem(at:change.backup,to:change.old) }
        }
        published=[]
        if !changes.contains(where:{ FileManager.default.fileExists(atPath:$0.backup.path) }) { try? FileManager.default.removeItem(at:work) }
    }
    func finish() {
        for change in published where change.old != change.destination { try? FileManager.default.removeItem(at:change.old) }
        try? FileManager.default.removeItem(at:work)
        let root=work.deletingLastPathComponent()
        for change in published {
            var directory=change.old.deletingLastPathComponent()
            while directory.path != root.path && directory.path.hasPrefix(root.path+"/") {
                guard let children=try? FileManager.default.contentsOfDirectory(atPath:directory.path), children.isEmpty else { break }
                do { try FileManager.default.removeItem(at:directory) } catch { break }
                directory=directory.deletingLastPathComponent()
            }
        }
    }
}
@MainActor extension Library {
    func applyAsync(_ patch: MetadataPatch, to ids: Set<String>) async throws {
        let snapshot=tracks, revision=contentRevision, root=mediaRoot
        let candidate=try metadataCandidate(patch,to:ids)
        let transaction=try await Task.detached { try ManagedEdit(old:snapshot,candidate:candidate,ids:ids,patch:patch,root:root) }.value
        guard revision == contentRevision else { transaction.rollback(); throw MetadataError(message:"Медиатека изменилась. Откройте редактор заново и повторите сохранение.") }
        try commitManaged(transaction)
    }
    func commitManaged(_ transaction: ManagedEdit) throws {
        do { try transaction.publish(); let normalized=try persist(transaction.tracks); tracks=normalized; transaction.finish() }
        catch { transaction.rollback(); throw error }
        Covers.invalidate(); applyPlayerSettings(); onChange?()
    }
}
