import Foundation

/// Bounded tag-only reads: never decode audio or ask a media service to discover formats.
/// AIFF/WAV chunks and MP4 atoms are traversed by offset, so large audio payloads are skipped.
struct NativeTags {
    private static let limit = 16 * 1024 * 1024
    static func read(_ url: URL) -> ImportedMetadata? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let length = try? file.seekToEnd(), length >= 4, let head = bytes(file, at: 0, count: Int(min(length, 12))) else { return nil }
        let magic = String(bytes: head.prefix(4), encoding: .isoLatin1) ?? ""
        if head.prefix(3) == [73, 68, 51] {
            guard let header = bytes(file, at: 0, count: 10) else { return nil }
            let size = syncsafe(header, 6)
            guard size <= limit, let tag = bytes(file, at: 0, count: min(size + 10, Int(length))) else { return nil }
            return id3(tag)
        }
        if magic == "FORM" || magic == "RIFF" {
            var offset: UInt64 = 12
            while offset + 8 <= length {
                guard let chunk = bytes(file, at: offset, count: 8) else { break }
                let name = String(bytes: chunk.prefix(4), encoding: .ascii) ?? ""
                let count = magic == "FORM" ? be(chunk, 4, 4) : le(chunk, 4, 4)
                guard count >= 0, UInt64(count) <= length - offset - 8 else { break }
                if ["ID3 ", "id3 ", "ID32"].contains(name), count <= limit, let tag = bytes(file, at: offset + 8, count: count) { return id3(tag) }
                offset += 8 + UInt64(count + count % 2)
            }
            return ImportedMetadata()
        }
        if magic == "fLaC" { return flac(file, length: length) }
        if head.count >= 8, String(bytes: head[4..<8], encoding: .ascii) == "ftyp" { return mp4(file, length: length) }
        if url.pathExtension.lowercased() == "mp3" {
            guard length >= 128, let tag = bytes(file, at: length - 128, count: 128), tag.prefix(3) == [84, 65, 71] else { return ImportedMetadata() }
            var result = ImportedMetadata()
            for (key, start, count) in [(MetadataField.title, 3, 30), (.artist, 33, 30), (.album, 63, 30), (.year, 93, 4)] {
                if let t = clean(String(bytes: tag[start..<(start + count)], encoding: .isoLatin1)) { result.fields[key] = t }
            }
            if ImportedMetadata.genres.indices.contains(Int(tag[127])) { result.fields[.genre] = ImportedMetadata.genres[Int(tag[127])] }
            return result
        }
        return nil
    }
    private static func bytes(_ file: FileHandle, at offset: UInt64, count: Int) -> [UInt8]? {
        guard count >= 0, count <= limit else { return nil }
        do { try file.seek(toOffset: offset); guard let data = try file.read(upToCount: count), data.count == count else { return nil }; return Array(data) }
        catch { return nil }
    }
    private static func be(_ data: [UInt8], _ at: Int, _ count: Int) -> Int {
        guard at >= 0, at + count <= data.count, count <= 8 else { return 0 }
        return data[at..<(at + count)].reduce(0) { ($0 << 8) | Int($1) }
    }
    private static func le(_ data: [UInt8], _ at: Int, _ count: Int) -> Int {
        guard at >= 0, at + count <= data.count else { return 0 }
        return data[at..<(at + count)].reversed().reduce(0) { ($0 << 8) | Int($1) }
    }
    private static func syncsafe(_ data: [UInt8], _ at: Int) -> Int {
        guard at + 4 <= data.count else { return 0 }; return data[at..<(at + 4)].reduce(0) { ($0 << 7) | Int($1 & 0x7f) }
    }
    private static func clean(_ value: String?) -> String? {
        value.flatMap { Track.nonempty($0.trimmingCharacters(in: .controlCharacters)) }
    }
    private static func deunsync(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []; var i = 0
        while i < bytes.count { result.append(bytes[i]); if bytes[i] == 255, i + 1 < bytes.count, bytes[i + 1] == 0 { i += 1 }; i += 1 }
        return result
    }
    private static func id3(_ tag: [UInt8]) -> ImportedMetadata {
        var result = ImportedMetadata()
        guard tag.count >= 10, tag.prefix(3) == [73, 68, 51], [2, 3, 4].contains(tag[3]) else { return result }
        let version = tag[3]; let unsync = tag[5] & 0x80 != 0
        var body = Array(tag.dropFirst(10)); if unsync && version < 4 { body = deunsync(body) }
        var offset = 0
        if tag[5] & 0x40 != 0, version >= 3, body.count >= 4 {
            offset = version == 4 ? syncsafe(body, 0) : be(body, 0, 4) + 4
        }
        let alias = ["TT2": "TIT2", "TP1": "TPE1", "TP2": "TPE2", "TAL": "TALB", "TCO": "TCON", "TYE": "TYER", "TCM": "TCOM", "TT1": "TIT1", "TRK": "TRCK", "TPA": "TPOS", "TBP": "TBPM", "COM": "COMM", "ULT": "USLT"]
        let map: [String: MetadataField] = ["TIT2": .title, "TPE1": .artist, "TALB": .album, "TPE2": .albumArtist, "TCON": .genre, "TYER": .year, "TDRC": .year, "TCOM": .composer, "TIT1": .grouping, "TBPM": .bpm, "COMM": .comments, "USLT": .lyrics, "TSOT": .sortTitle, "TSOP": .sortArtist, "TSOA": .sortAlbum, "TSO2": .sortAlbumArtist, "TSOC": .sortComposer, "TCMP": .isCompilation]
        let headerSize = version == 2 ? 6 : 10
        while offset >= 0, offset + headerSize <= body.count {
            let idSize = version == 2 ? 3 : 4
            guard let raw = String(bytes: body[offset..<(offset + idSize)], encoding: .ascii), raw.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else { break }
            let id = alias[raw] ?? raw
            let size = version == 2 ? be(body, offset + 3, 3) : version == 4 ? syncsafe(body, offset + 4) : be(body, offset + 4, 4)
            guard size > 0, size <= body.count - offset - headerSize else { break }
            let flags = version == 2 ? 0 : body[offset + 9]
            let compressed = version == 3 ? flags & 0xC0 != 0 : version == 4 && flags & 0x0C != 0
            var frame = Array(body[(offset + headerSize)..<(offset + headerSize + size)])
            offset += headerSize + size
            if compressed { continue }
            if version == 4 && (unsync || flags & 0x02 != 0) { frame = deunsync(frame) }
            if version == 4 && flags & 0x01 != 0 && frame.count >= 4 { frame = Array(frame.dropFirst(4)) }
            guard let encoding = frame.first else { continue }
            var textBytes = Array(frame.dropFirst())
            if id == "COMM" || id == "USLT" {
                guard textBytes.count >= 3 else { continue }; textBytes = Array(textBytes.dropFirst(3))
                let width = encoding == 1 || encoding == 2 ? 2 : 1
                var end = 0
                while end + width <= textBytes.count {
                    if textBytes[end..<(end + width)].allSatisfy({ $0 == 0 }) { end += width; break }; end += width
                }
                textBytes = Array(textBytes.dropFirst(min(end, textBytes.count)))
            }
            let text: String?
            switch encoding {
            case 0: text = String(bytes: textBytes, encoding: .isoLatin1)
            case 1: text = String(data: Data(textBytes), encoding: .utf16)
            case 2: text = String(data: Data(textBytes), encoding: .utf16BigEndian)
            default: text = String(bytes: textBytes, encoding: .utf8)
            }
            guard let value = clean(text) else { continue }
            if id == "TRCK" || id == "TPOS" { pair(value, first: id == "TRCK" ? .number : .discNumber, total: id == "TRCK" ? .trackTotal : .discTotal, into: &result) }
            else if let field = map[id] { result.fields[field] = field == .genre ? ImportedMetadata.genre(value) : field == .year ? String(value.prefix(4)) : value }
        }
        return result
    }
    private static func pair(_ value: String, first: MetadataField, total: MetadataField, into result: inout ImportedMetadata) {
        let parts = value.split(separator: "/"); if let p = parts.first, Int(p) != nil { result.fields[first] = String(p) }
        if parts.count > 1, Int(parts[1]) != nil { result.fields[total] = String(parts[1]) }
    }
    private static func flac(_ file: FileHandle, length: UInt64) -> ImportedMetadata {
        var result = ImportedMetadata(); var offset: UInt64 = 4
        while offset + 4 <= length {
            guard let h = bytes(file, at: offset, count: 4) else { break }
            let count = be(h, 1, 3); let last = h[0] & 128 != 0
            guard UInt64(count) <= length - offset - 4 else { break }
            if h[0] & 127 == 4, let data = bytes(file, at: offset + 4, count: count), data.count >= 8 {
                var p = 4 + le(data, 0, 4); guard p + 4 <= data.count else { break }
                let entries = le(data, p, 4); p += 4
                for _ in 0..<min(entries, 10000) {
                    guard p + 4 <= data.count else { break }; let n = le(data, p, 4); p += 4
                    guard n <= data.count - p else { break }
                    let comment = String(bytes: data[p..<(p + n)], encoding: .utf8) ?? ""; p += n
                    let parts = comment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false); guard parts.count == 2 else { continue }
                    let key = parts[0].uppercased(); let value = String(parts[1])
                    let map: [String: MetadataField] = ["TITLE": .title, "ARTIST": .artist, "ALBUM": .album, "ALBUMARTIST": .albumArtist, "ALBUM_ARTIST": .albumArtist, "GENRE": .genre, "DATE": .year, "COMPOSER": .composer, "GROUPING": .grouping, "TRACKNUMBER": .number, "TRACKTOTAL": .trackTotal, "DISCNUMBER": .discNumber, "DISCTOTAL": .discTotal, "BPM": .bpm, "COMMENT": .comments, "LYRICS": .lyrics]
                    if let field = map[key] { result.fields[field] = field == .year ? String(value.prefix(4)) : value }
                }
                break
            }
            offset += 4 + UInt64(count); if last { break }
        }
        return result
    }
    private static func mp4(_ file: FileHandle, length: UInt64) -> ImportedMetadata {
        var result = ImportedMetadata()
        func scan(_ start: UInt64, _ end: UInt64, _ depth: Int, inList: Bool = false) {
            guard depth < 8 else { return }; var offset = start; var iterations = 0
            while offset + 8 <= end && iterations < 10000 {
                iterations += 1
                guard let h = bytes(file, at: offset, count: 8) else { break }
                var size = UInt64(be(h, 0, 4)); var header: UInt64 = 8
                let type = String(bytes: h[4..<8], encoding: .isoLatin1) ?? ""
                if size == 1 { guard let large = bytes(file, at: offset + 8, count: 8), large[0] < 128 else { break }; size = UInt64(be(large, 0, 8)); header = 16 }
                if size == 0 { size = end - offset }
                guard size >= header, size <= end - offset else { break }
                let payload = offset + header; let next = offset + size
                if ["moov", "udta", "meta", "ilst"].contains(type) { scan(payload + (type == "meta" ? 4 : 0), next, depth + 1, inList: type == "ilst") }
                else if inList {
                    var p = payload
                    while p + 16 <= next {
                        guard let d = bytes(file, at: p, count: 16) else { break }
                        let n = UInt64(be(d, 0, 4)); guard n >= 16, n <= next - p else { break }
                        if String(bytes: d[4..<8], encoding: .ascii) == "data", n - 16 <= UInt64(limit), let value = bytes(file, at: p + 16, count: Int(n - 16)) {
                            let map: [String: MetadataField] = ["©nam": .title, "©ART": .artist, "aART": .albumArtist, "©alb": .album, "©gen": .genre, "©day": .year, "©wrt": .composer, "©grp": .grouping, "©cmt": .comments, "©lyr": .lyrics, "sonm": .sortTitle, "soar": .sortArtist, "soal": .sortAlbum, "soaa": .sortAlbumArtist, "soco": .sortComposer]
                            if let field = map[type], let t = clean(String(bytes: value, encoding: .utf8)) { result.fields[field] = field == .year ? String(t.prefix(4)) : t }
                            else if type == "gnre", value.count >= 2 { let i = be(value, 0, 2) - 1; if ImportedMetadata.genres.indices.contains(i) { result.fields[.genre] = ImportedMetadata.genres[i] } }
                            else if (type == "trkn" || type == "disk"), value.count >= 6 { result.fields[type == "trkn" ? .number : .discNumber] = String(be(value, 2, 2)); result.fields[type == "trkn" ? .trackTotal : .discTotal] = String(be(value, 4, 2)) }
                            else if type == "tmpo", value.count >= 2 { result.fields[.bpm] = String(be(value, 0, 2)) }
                            else if type == "rtng", let first = value.first { result.isExplicit = first == 1 || first == 4 }
                            else if type == "cpil", let first = value.first { result.fields[.isCompilation] = first == 0 ? "0" : "1" }
                        }
                        p += n
                    }
                }
                offset = next
            }
        }
        scan(0, length, 0); return result
    }
}
