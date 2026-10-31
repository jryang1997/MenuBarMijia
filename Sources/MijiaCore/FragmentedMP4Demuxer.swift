import Foundation

/// Video codec carried by a fragmented MP4 live stream (#97).
public enum FMP4VideoCodec: String, Equatable, Sendable {
    case h264
    case hevc
}

/// Decoder configuration for one video track, read from the `moov` init segment.
public struct FMP4VideoTrack: Equatable, Sendable {
    public var trackID: UInt32
    public var codec: FMP4VideoCodec
    public var timescale: UInt32
    public var width: Int
    public var height: Int
    /// Body of the `avcC` / `hvcC` box (the decoder configuration record).
    public var configRecord: Data
    /// Length of every NAL-unit size prefix in a sample (1, 2 or 4).
    public var nalLengthSize: Int
    /// Parameter sets from the configuration record: SPS + PPS (H.264) or VPS + SPS + PPS (HEVC).
    public var parameterSets: [Data]
}

/// One coded video frame (AVCC/HVCC length-prefixed NAL units).
public struct FMP4Sample: Equatable, Sendable {
    public var trackID: UInt32
    public var data: Data
    public var decodeTime: UInt64
    public var duration: UInt32
    public var compositionOffset: Int32
    public var isKeyframe: Bool
}

public enum FMP4DemuxEvent: Equatable, Sendable {
    case videoTrack(FMP4VideoTrack)
    case sample(FMP4Sample)
}

public enum FMP4DemuxError: Error, Equatable {
    case malformedBox(String)
    case bufferOverflow
}

/// Incremental parser for the progressive fragmented MP4 that go2rtc serves on
/// `/api/stream.mp4` (`ftyp` + `moov`, then a `moof` + `mdat` pair per frame).
///
/// Bytes arrive in arbitrary network chunks; `append(_:)` returns every complete
/// event and keeps the partial tail for the next call. Pure Foundation so it builds
/// and tests on Linux; CoreMedia conversion lives in the app target.
public struct FragmentedMP4Demuxer: Sendable {
    private var buffer = Data()
    private var tracks: [UInt32: FMP4VideoTrack] = [:]
    private var trackDefaults: [UInt32: TrackDefaults] = [:]
    private var pendingMoof: Data?
    private let maxBufferedBytes: Int

    private struct TrackDefaults: Sendable {
        var duration: UInt32 = 0
        var size: UInt32 = 0
        var flags: UInt32 = 0
    }

    public init(maxBufferedBytes: Int = 16 * 1024 * 1024) {
        self.maxBufferedBytes = maxBufferedBytes
    }

    public var videoTracks: [FMP4VideoTrack] {
        tracks.values.sorted { $0.trackID < $1.trackID }
    }

    public mutating func append(_ chunk: Data) throws -> [FMP4DemuxEvent] {
        buffer.append(chunk)
        var events: [FMP4DemuxEvent] = []
        var cursor = buffer.startIndex

        while true {
            let available = buffer.endIndex - cursor
            guard available >= 8 else { break }
            let size32 = Self.readUInt32(buffer, cursor)
            let type = Self.fourCC(buffer, cursor + 4)
            var headerSize = 8
            var boxSize: Int
            if size32 == 1 {
                guard available >= 16 else { break }
                let large = Self.readUInt64(buffer, cursor + 8)
                guard large <= UInt64(Int.max) else { throw FMP4DemuxError.malformedBox(type) }
                boxSize = Int(large)
                headerSize = 16
            } else if size32 == 0 {
                // "Extends to end of file" never terminates on a live stream.
                throw FMP4DemuxError.malformedBox(type)
            } else {
                boxSize = Int(size32)
            }
            guard boxSize >= headerSize else { throw FMP4DemuxError.malformedBox(type) }
            if boxSize > maxBufferedBytes { throw FMP4DemuxError.bufferOverflow }
            guard available >= boxSize else { break }

            let box = buffer.subdata(in: cursor..<(cursor + boxSize))
            cursor += boxSize

            switch type {
            case "moov":
                try parseMoov(box, headerSize: headerSize, into: &events)
            case "moof":
                pendingMoof = box
            case "mdat":
                if let moof = pendingMoof {
                    pendingMoof = nil
                    try parseFragment(moof: moof, mdat: box, mdatHeaderSize: headerSize, into: &events)
                }
            default:
                break // ftyp, styp, sidx, free, ...
            }
        }

        if cursor > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<cursor)
            buffer = Data(buffer) // re-base indices at 0
        }
        if buffer.count > maxBufferedBytes {
            throw FMP4DemuxError.bufferOverflow
        }
        return events
    }

    // MARK: - Init segment

    private mutating func parseMoov(_ moov: Data, headerSize: Int, into events: inout [FMP4DemuxEvent]) throws {
        for child in Self.children(of: moov, from: headerSize) {
            switch child.type {
            case "trak":
                if let track = try Self.parseTrak(moov, range: child.payload) {
                    tracks[track.trackID] = track
                    events.append(.videoTrack(track))
                }
            case "mvex":
                for trex in Self.children(of: moov, in: child.payload) where trex.type == "trex" {
                    let p = trex.payload.lowerBound
                    guard trex.payload.count >= 24 else { continue }
                    let trackID = Self.readUInt32(moov, p + 4)
                    trackDefaults[trackID] = TrackDefaults(
                        duration: Self.readUInt32(moov, p + 12),
                        size: Self.readUInt32(moov, p + 16),
                        flags: Self.readUInt32(moov, p + 20)
                    )
                }
            default:
                break
            }
        }
    }

    private static func parseTrak(_ data: Data, range: Range<Int>) throws -> FMP4VideoTrack? {
        var trackID: UInt32?
        var timescale: UInt32 = 90_000
        var isVideo = false
        var entry: (codec: FMP4VideoCodec, width: Int, height: Int, config: Data)?

        for child in children(of: data, in: range) {
            switch child.type {
            case "tkhd":
                let p = child.payload.lowerBound
                guard child.payload.count >= 4 else { continue }
                let version = data[p]
                let idOffset = version == 1 ? 4 + 16 : 4 + 8
                if child.payload.count >= idOffset + 4 {
                    trackID = readUInt32(data, p + idOffset)
                }
            case "mdia":
                for m in children(of: data, in: child.payload) {
                    switch m.type {
                    case "mdhd":
                        let p = m.payload.lowerBound
                        guard m.payload.count >= 4 else { continue }
                        let version = data[p]
                        let tsOffset = version == 1 ? 4 + 16 : 4 + 8
                        if m.payload.count >= tsOffset + 4 {
                            timescale = readUInt32(data, p + tsOffset)
                        }
                    case "hdlr":
                        if m.payload.count >= 12 {
                            isVideo = fourCC(data, m.payload.lowerBound + 8) == "vide"
                        }
                    case "minf":
                        entry = findVisualSampleEntry(data, in: m.payload) ?? entry
                    default:
                        break
                    }
                }
            default:
                break
            }
        }

        guard isVideo, let trackID, let entry else { return nil }
        guard let parsed = parseConfigRecord(entry.config, codec: entry.codec) else {
            throw FMP4DemuxError.malformedBox(entry.codec == .h264 ? "avcC" : "hvcC")
        }
        return FMP4VideoTrack(
            trackID: trackID,
            codec: entry.codec,
            timescale: timescale == 0 ? 90_000 : timescale,
            width: entry.width,
            height: entry.height,
            configRecord: entry.config,
            nalLengthSize: parsed.nalLengthSize,
            parameterSets: parsed.parameterSets
        )
    }

    private static func findVisualSampleEntry(
        _ data: Data,
        in range: Range<Int>
    ) -> (codec: FMP4VideoCodec, width: Int, height: Int, config: Data)? {
        for stbl in children(of: data, in: range) where stbl.type == "stbl" {
            for stsd in children(of: data, in: stbl.payload) where stsd.type == "stsd" {
                // FullBox header (4) + entry_count (4), then sample entries.
                let entriesStart = stsd.payload.lowerBound + 8
                guard entriesStart <= stsd.payload.upperBound else { continue }
                for sampleEntry in children(of: data, in: entriesStart..<stsd.payload.upperBound) {
                    let codec: FMP4VideoCodec
                    switch sampleEntry.type {
                    case "avc1", "avc3": codec = .h264
                    case "hvc1", "hev1": codec = .hevc
                    default: continue
                    }
                    // SampleEntry (8) + VisualSampleEntry fields (70) precede child boxes.
                    let p = sampleEntry.payload.lowerBound
                    guard sampleEntry.payload.count >= 78 else { continue }
                    let width = Int(readUInt16(data, p + 24))
                    let height = Int(readUInt16(data, p + 26))
                    let configType = codec == .h264 ? "avcC" : "hvcC"
                    for box in children(of: data, in: (p + 78)..<sampleEntry.payload.upperBound) where box.type == configType {
                        return (codec, width, height, data.subdata(in: box.payload))
                    }
                }
            }
        }
        return nil
    }

    /// Parses an `avcC` / `hvcC` body into its NAL length size and parameter sets.
    public static func parseConfigRecord(
        _ record: Data,
        codec: FMP4VideoCodec
    ) -> (nalLengthSize: Int, parameterSets: [Data])? {
        let bytes = [UInt8](record)
        switch codec {
        case .h264:
            guard bytes.count >= 7 else { return nil }
            let lengthSize = Int(bytes[4] & 0x03) + 1
            var sets: [Data] = []
            var i = 5
            let spsCount = Int(bytes[i] & 0x1F)
            i += 1
            for _ in 0..<spsCount {
                guard i + 2 <= bytes.count else { return nil }
                let len = Int(bytes[i]) << 8 | Int(bytes[i + 1])
                i += 2
                guard i + len <= bytes.count else { return nil }
                sets.append(Data(bytes[i..<(i + len)]))
                i += len
            }
            guard i < bytes.count else { return nil }
            let ppsCount = Int(bytes[i])
            i += 1
            for _ in 0..<ppsCount {
                guard i + 2 <= bytes.count else { return nil }
                let len = Int(bytes[i]) << 8 | Int(bytes[i + 1])
                i += 2
                guard i + len <= bytes.count else { return nil }
                sets.append(Data(bytes[i..<(i + len)]))
                i += len
            }
            return (lengthSize, sets)
        case .hevc:
            guard bytes.count >= 23 else { return nil }
            let lengthSize = Int(bytes[21] & 0x03) + 1
            let arrayCount = Int(bytes[22])
            var i = 23
            var byType: [UInt8: [Data]] = [:]
            for _ in 0..<arrayCount {
                guard i + 3 <= bytes.count else { return nil }
                let nalType = bytes[i] & 0x3F
                let count = Int(bytes[i + 1]) << 8 | Int(bytes[i + 2])
                i += 3
                for _ in 0..<count {
                    guard i + 2 <= bytes.count else { return nil }
                    let len = Int(bytes[i]) << 8 | Int(bytes[i + 1])
                    i += 2
                    guard i + len <= bytes.count else { return nil }
                    byType[nalType, default: []].append(Data(bytes[i..<(i + len)]))
                    i += len
                }
            }
            // VideoToolbox wants VPS, SPS, PPS in that order.
            let sets = (byType[32] ?? []) + (byType[33] ?? []) + (byType[34] ?? [])
            return (lengthSize, sets)
        }
    }

    // MARK: - Fragments

    private func parseFragment(
        moof: Data,
        mdat: Data,
        mdatHeaderSize: Int,
        into events: inout [FMP4DemuxEvent]
    ) throws {
        for traf in Self.children(of: moof, from: 8) where traf.type == "traf" {
            var trackID: UInt32 = 0
            var defaults = TrackDefaults()
            var baseDecodeTime: UInt64 = 0
            var runs: [Range<Int>] = []

            for box in Self.children(of: moof, in: traf.payload) {
                let p = box.payload.lowerBound
                switch box.type {
                case "tfhd":
                    guard box.payload.count >= 8 else { throw FMP4DemuxError.malformedBox("tfhd") }
                    let flags = Self.readUInt32(moof, p) & 0x00FF_FFFF
                    trackID = Self.readUInt32(moof, p + 4)
                    defaults = trackDefaults[trackID] ?? TrackDefaults()
                    var o = p + 8
                    if flags & 0x01 != 0 { o += 8 } // base-data-offset (we assume moof-relative offsets)
                    if flags & 0x02 != 0 { o += 4 } // sample-description-index
                    if flags & 0x08 != 0 { defaults.duration = Self.readUInt32(moof, o); o += 4 }
                    if flags & 0x10 != 0 { defaults.size = Self.readUInt32(moof, o); o += 4 }
                    if flags & 0x20 != 0 { defaults.flags = Self.readUInt32(moof, o); o += 4 }
                case "tfdt":
                    guard box.payload.count >= 8 else { throw FMP4DemuxError.malformedBox("tfdt") }
                    baseDecodeTime = moof[p] == 1 && box.payload.count >= 12
                        ? Self.readUInt64(moof, p + 4)
                        : UInt64(Self.readUInt32(moof, p + 4))
                case "trun":
                    runs.append(box.payload)
                default:
                    break
                }
            }
            guard tracks[trackID] != nil else { continue }

            // Sample data offsets are relative to the moof start; the mdat payload follows it.
            let mdatPayloadOffset = moof.count + mdatHeaderSize
            var nextDataOffset = mdatPayloadOffset
            var decodeTime = baseDecodeTime

            for run in runs {
                let p = run.lowerBound
                guard run.count >= 8 else { throw FMP4DemuxError.malformedBox("trun") }
                let flags = Self.readUInt32(moof, p) & 0x00FF_FFFF
                let count = Int(Self.readUInt32(moof, p + 4))
                var o = p + 8
                var dataOffset = nextDataOffset
                if flags & 0x01 != 0 {
                    dataOffset = Int(Int32(bitPattern: Self.readUInt32(moof, o)))
                    o += 4
                }
                var firstFlags: UInt32?
                if flags & 0x04 != 0 {
                    firstFlags = Self.readUInt32(moof, o)
                    o += 4
                }
                let perSample = (flags & 0x100 != 0 ? 4 : 0) + (flags & 0x200 != 0 ? 4 : 0)
                    + (flags & 0x400 != 0 ? 4 : 0) + (flags & 0x800 != 0 ? 4 : 0)
                guard count >= 0, o + perSample * count <= run.upperBound else {
                    throw FMP4DemuxError.malformedBox("trun")
                }

                for index in 0..<count {
                    var duration = defaults.duration
                    var size = defaults.size
                    var sampleFlags = (index == 0 ? firstFlags : nil) ?? defaults.flags
                    var cto: Int32 = 0
                    if flags & 0x100 != 0 { duration = Self.readUInt32(moof, o); o += 4 }
                    if flags & 0x200 != 0 { size = Self.readUInt32(moof, o); o += 4 }
                    if flags & 0x400 != 0 { sampleFlags = Self.readUInt32(moof, o); o += 4 }
                    if flags & 0x800 != 0 { cto = Int32(bitPattern: Self.readUInt32(moof, o)); o += 4 }

                    let start = dataOffset - mdatPayloadOffset
                    let end = start + Int(size)
                    let payloadLength = mdat.count - mdatHeaderSize
                    guard start >= 0, end <= payloadLength else {
                        throw FMP4DemuxError.malformedBox("mdat")
                    }
                    let sampleData = mdat.subdata(in: (mdatHeaderSize + start)..<(mdatHeaderSize + end))
                    events.append(.sample(FMP4Sample(
                        trackID: trackID,
                        data: sampleData,
                        decodeTime: decodeTime,
                        duration: duration,
                        compositionOffset: cto,
                        isKeyframe: sampleFlags & 0x0001_0000 == 0
                    )))
                    decodeTime += UInt64(duration)
                    dataOffset = end + mdatPayloadOffset
                }
                nextDataOffset = dataOffset
            }
        }
    }

    // MARK: - Box helpers

    private struct BoxRef {
        let type: String
        let payload: Range<Int>
    }

    private static func children(of data: Data, from headerSize: Int) -> [BoxRef] {
        children(of: data, in: (data.startIndex + headerSize)..<data.endIndex)
    }

    private static func children(of data: Data, in range: Range<Int>) -> [BoxRef] {
        var result: [BoxRef] = []
        var cursor = range.lowerBound
        while cursor + 8 <= range.upperBound {
            let size32 = readUInt32(data, cursor)
            let type = fourCC(data, cursor + 4)
            var header = 8
            var size = Int(size32)
            if size32 == 1 {
                guard cursor + 16 <= range.upperBound else { break }
                let large = readUInt64(data, cursor + 8)
                guard large <= UInt64(range.upperBound - cursor) else { break }
                size = Int(large)
                header = 16
            } else if size32 == 0 {
                size = range.upperBound - cursor
            }
            guard size >= header, cursor + size <= range.upperBound else { break }
            result.append(BoxRef(type: type, payload: (cursor + header)..<(cursor + size)))
            cursor += size
        }
        return result
    }

    static func readUInt16(_ d: Data, _ i: Int) -> UInt16 {
        UInt16(d[i]) << 8 | UInt16(d[i + 1])
    }

    static func readUInt32(_ d: Data, _ i: Int) -> UInt32 {
        UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }

    static func readUInt64(_ d: Data, _ i: Int) -> UInt64 {
        UInt64(readUInt32(d, i)) << 32 | UInt64(readUInt32(d, i + 4))
    }

    static func fourCC(_ d: Data, _ i: Int) -> String {
        String(decoding: d[i..<(i + 4)], as: UTF8.self)
    }
}

// MARK: - NAL unit helpers

public enum VideoNALUnits {
    /// Splits a length-prefixed (AVCC/HVCC) sample into NAL units.
    public static func split(_ sample: Data, lengthSize: Int) -> [Data]? {
        guard (1...4).contains(lengthSize) else { return nil }
        let bytes = [UInt8](sample)
        var units: [Data] = []
        var i = 0
        while i < bytes.count {
            guard i + lengthSize <= bytes.count else { return nil }
            var len = 0
            for k in 0..<lengthSize { len = len << 8 | Int(bytes[i + k]) }
            i += lengthSize
            guard len > 0, i + len <= bytes.count else { return nil }
            units.append(Data(bytes[i..<(i + len)]))
            i += len
        }
        return units
    }

    /// Converts an Annex-B sample (start-code delimited) into 4-byte length-prefixed form.
    /// Returns nil when the sample does not start with a start code.
    public static func annexBToLengthPrefixed(_ sample: Data) -> Data? {
        let bytes = [UInt8](sample)
        guard bytes.count >= 4,
              (bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 1)
                || (bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 1) else {
            return nil
        }
        var starts: [(codeStart: Int, nalStart: Int)] = []
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                let codeStart = (i > 0 && bytes[i - 1] == 0) ? i - 1 : i
                starts.append((codeStart, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var out = Data()
        for (index, s) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].codeStart : bytes.count
            guard end > s.nalStart else { continue }
            let len = UInt32(end - s.nalStart)
            out.append(contentsOf: [UInt8(len >> 24), UInt8(len >> 16 & 0xFF), UInt8(len >> 8 & 0xFF), UInt8(len & 0xFF)])
            out.append(contentsOf: bytes[s.nalStart..<end])
        }
        return out
    }

    /// NAL unit type of the first header byte.
    public static func nalType(_ unit: Data, codec: FMP4VideoCodec) -> UInt8 {
        guard let first = unit.first else { return 0 }
        switch codec {
        case .h264: return first & 0x1F
        case .hevc: return (first >> 1) & 0x3F
        }
    }

    /// In-band parameter sets in decoder order, or nil if the sample carries an incomplete set.
    public static func parameterSets(in units: [Data], codec: FMP4VideoCodec) -> [Data]? {
        switch codec {
        case .h264:
            let sps = units.first { nalType($0, codec: .h264) == 7 }
            let pps = units.first { nalType($0, codec: .h264) == 8 }
            guard let sps, let pps else { return nil }
            return [sps, pps]
        case .hevc:
            let vps = units.first { nalType($0, codec: .hevc) == 32 }
            let sps = units.first { nalType($0, codec: .hevc) == 33 }
            let pps = units.first { nalType($0, codec: .hevc) == 34 }
            guard let vps, let sps, let pps else { return nil }
            return [vps, sps, pps]
        }
    }

    /// True when the sample holds an IDR / IRAP picture.
    public static func containsKeyframe(_ units: [Data], codec: FMP4VideoCodec) -> Bool {
        units.contains { unit in
            let type = nalType(unit, codec: codec)
            switch codec {
            case .h264: return type == 5
            case .hevc: return (16...23).contains(type)
            }
        }
    }
}
