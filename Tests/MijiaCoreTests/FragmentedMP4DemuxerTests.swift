import Foundation
import Testing
@testable import MijiaCore

/// Builds the same box layout go2rtc's `pkg/iso` muxer writes for `/api/stream.mp4` (#97).
private enum FMP4Fixture {
    static func box(_ type: String, _ body: Data) -> Data {
        var d = Data()
        d.append(u32(UInt32(body.count + 8)))
        d.append(contentsOf: Array(type.utf8))
        d.append(body)
        return d
    }

    static func u16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
    static func u32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
    static func u64(_ v: UInt64) -> Data { u32(UInt32(v >> 32)) + u32(UInt32(v & 0xFFFF_FFFF)) }

    static let sps = Data([0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x02, 0x80, 0xBF, 0xE5])
    static let pps = Data([0x68, 0xCE, 0x3C, 0x80])

    static var avcC: Data {
        var d = Data([0x01, 0x42, 0xC0, 0x1E, 0xFF, 0xE1])
        d.append(u16(UInt16(sps.count))); d.append(sps)
        d.append(0x01)
        d.append(u16(UInt16(pps.count))); d.append(pps)
        return d
    }

    static func initSegment(trackID: UInt32 = 1, timescale: UInt32 = 90_000) -> Data {
        let ftyp = box("ftyp", Data("iso5".utf8) + u32(512) + Data("iso5iso6mp41".utf8))
        let mvhd = box("mvhd", Data(count: 100))
        // tkhd v0: version/flags(4) creation(4) modification(4) track_ID(4) ...
        let tkhd = box("tkhd", Data(count: 12) + u32(trackID) + Data(count: 64))
        // mdhd v0: version/flags(4) creation(4) modification(4) timescale(4) duration(4) lang(4)
        let mdhd = box("mdhd", Data(count: 12) + u32(timescale) + Data(count: 8))
        let hdlr = box("hdlr", Data(count: 8) + Data("vide".utf8) + Data(count: 12) + Data("VideoHandler\0".utf8))
        var visual = Data(count: 24)       // SampleEntry(8) + pre_defined/reserved(16)
        visual.append(u16(640)); visual.append(u16(360))
        visual.append(Data(count: 50))     // resolution, reserved, frame_count, compressor, depth, pre_defined
        let avc1 = box("avc1", visual + box("avcC", avcC))
        let stsd = box("stsd", Data(count: 4) + u32(1) + avc1)
        let stbl = box("stbl", stsd)
        let minf = box("minf", box("vmhd", Data(count: 12)) + stbl)
        let mdia = box("mdia", mdhd + hdlr + minf)
        let trak = box("trak", tkhd + mdia)
        var trexBody = Data(count: 4)
        for field in [trackID, 1, 0, 0, 0] { trexBody.append(u32(field)) }
        let trex = box("trex", trexBody)
        let mvex = box("mvex", trex)
        return ftyp + box("moov", mvhd + trak + mvex)
    }

    /// One `moof` + `mdat` per frame, exactly like go2rtc's `WriteMovieFragment` with cts == 0.
    static func fragment(seq: UInt32, trackID: UInt32 = 1, dts: UInt64, duration: UInt32, sample: Data, keyframe: Bool) -> Data {
        let flags: UInt32 = keyframe ? 0x0200_0000 : 0x0101_0000
        let mfhd = box("mfhd", Data(count: 4) + u32(seq))
        var tfhdBody = Data()
        for field in [0x0002_0038, trackID, duration, UInt32(sample.count), flags] { tfhdBody.append(u32(field)) }
        let tfhd = box("tfhd", tfhdBody)
        let tfdt = box("tfdt", Data([0x01, 0, 0, 0]) + u64(dts))
        // moof header(8) + mfhd(16) + traf header(8) + tfhd(28) + tfdt(20) + trun(20) + mdat header(8)
        let dataOffset: UInt32 = 108
        let trun = box("trun", u32(0x0000_0001) + u32(1) + u32(dataOffset))
        let moof = box("moof", mfhd + box("traf", tfhd + tfdt + trun))
        return moof + box("mdat", sample)
    }

    static func lengthPrefixed(_ units: [Data]) -> Data {
        units.reduce(into: Data()) { out, unit in
            out.append(u32(UInt32(unit.count)))
            out.append(unit)
        }
    }
}

@Suite("Fragmented MP4 demuxer (#97)")
struct FragmentedMP4DemuxerTests {
    @Test("Parses go2rtc's init segment and per-frame fragments, even when bytes arrive one at a time")
    func parsesInitAndFragmentsAcrossChunkBoundaries() throws {
        let idr = FMP4Fixture.lengthPrefixed([FMP4Fixture.sps, FMP4Fixture.pps, Data([0x65, 0x88, 0x84, 0x00])])
        let pFrame = FMP4Fixture.lengthPrefixed([Data([0x41, 0x9A, 0x02])])
        var stream = FMP4Fixture.initSegment()
        stream.append(FMP4Fixture.fragment(seq: 1, dts: 0, duration: 3600, sample: idr, keyframe: true))
        stream.append(FMP4Fixture.fragment(seq: 2, dts: 3600, duration: 3600, sample: pFrame, keyframe: false))

        var demuxer = FragmentedMP4Demuxer()
        var events: [FMP4DemuxEvent] = []
        for byte in stream {
            events += try demuxer.append(Data([byte]))
        }

        #expect(events.count == 3)
        guard case .videoTrack(let track) = events[0] else {
            Issue.record("expected a video track first")
            return
        }
        #expect(track.trackID == 1)
        #expect(track.codec == .h264)
        #expect(track.timescale == 90_000)
        #expect(track.width == 640 && track.height == 360)
        #expect(track.nalLengthSize == 4)
        #expect(track.parameterSets == [FMP4Fixture.sps, FMP4Fixture.pps])

        guard case .sample(let first) = events[1], case .sample(let second) = events[2] else {
            Issue.record("expected two samples")
            return
        }
        #expect(first.data == idr)
        #expect(first.isKeyframe)
        #expect(first.decodeTime == 0 && first.duration == 3600)
        #expect(second.data == pFrame)
        #expect(!second.isKeyframe)
        #expect(second.decodeTime == 3600)
    }

    @Test("Ignores fragments for tracks that were never announced")
    func ignoresUnknownTracks() throws {
        var demuxer = FragmentedMP4Demuxer()
        _ = try demuxer.append(FMP4Fixture.initSegment(trackID: 1))
        let events = try demuxer.append(
            FMP4Fixture.fragment(seq: 1, trackID: 2, dts: 0, duration: 1024, sample: Data([0, 0, 0, 1, 0xAA]), keyframe: true)
        )
        #expect(events.isEmpty)
    }

    @Test("Splits AVCC samples, extracts in-band parameter sets, and detects IDR frames")
    func nalUnitHelpers() throws {
        let idrSlice = Data([0x65, 0x88, 0x84])
        let sample = FMP4Fixture.lengthPrefixed([FMP4Fixture.sps, FMP4Fixture.pps, idrSlice])
        let units = try #require(VideoNALUnits.split(sample, lengthSize: 4))
        #expect(units == [FMP4Fixture.sps, FMP4Fixture.pps, idrSlice])
        #expect(VideoNALUnits.parameterSets(in: units, codec: .h264) == [FMP4Fixture.sps, FMP4Fixture.pps])
        #expect(VideoNALUnits.containsKeyframe(units, codec: .h264))
        #expect(!VideoNALUnits.containsKeyframe([Data([0x41, 0x9A])], codec: .h264))
        #expect(VideoNALUnits.split(Data([0, 0, 0, 9, 0x41]), lengthSize: 4) == nil)
    }

    @Test("Converts Annex-B samples to 4-byte length prefixes")
    func annexBConversion() throws {
        let annexB = Data([0, 0, 0, 1, 0x67, 0x42, 0, 0, 1, 0x68, 0xCE, 0, 0, 0, 1, 0x65, 0x88])
        let converted = try #require(VideoNALUnits.annexBToLengthPrefixed(annexB))
        let units = try #require(VideoNALUnits.split(converted, lengthSize: 4))
        #expect(units == [Data([0x67, 0x42]), Data([0x68, 0xCE]), Data([0x65, 0x88])])
        #expect(VideoNALUnits.annexBToLengthPrefixed(Data([0, 0, 0, 4, 0x65, 1, 2, 3])) == nil)
    }

    @Test("Orders HEVC parameter sets VPS, SPS, PPS regardless of hvcC array order")
    func hevcConfigRecordOrdering() throws {
        let vps = Data([0x40, 0x01, 0x0C])
        let sps = Data([0x42, 0x01, 0x01])
        let pps = Data([0x44, 0x01, 0xC0])
        var record = Data(count: 21)
        record.append(0x03)          // lengthSizeMinusOne = 3
        record.append(3)             // numOfArrays
        for (type, unit) in [(UInt8(34), pps), (33, sps), (32, vps)] {
            record.append(type)
            record.append(contentsOf: [0, 1])
            record.append(contentsOf: [0, UInt8(unit.count)])
            record.append(unit)
        }
        let parsed = try #require(FragmentedMP4Demuxer.parseConfigRecord(record, codec: .hevc))
        #expect(parsed.nalLengthSize == 4)
        #expect(parsed.parameterSets == [vps, sps, pps])
    }
}

@Suite("go2rtc config comparison (#97)")
struct Go2RTCConfigTests {
    @Test("Streams go2rtc appends to its config do not count as an app config change")
    func baseConfigIgnoresAppendedStreams() {
        let written = """
        api:
          listen: 127.0.0.1:1984
        ffmpeg:
          bin: /opt/homebrew/bin/ffmpeg
        """
        let rewrittenByGo2RTC = written + """

        streams:
          cam_raw_1:
            - xiaomi://127.0.0.1:5000?x=1
        """
        #expect(XiaomiCameraBridge.baseConfig(rewrittenByGo2RTC) == XiaomiCameraBridge.baseConfig(written))
        #expect(XiaomiCameraBridge.baseConfig(written.replacingOccurrences(of: "1984", with: "1985"))
            != XiaomiCameraBridge.baseConfig(written))
    }
}

@Suite("CS2 command channel gate (#97)")
struct CS2CommandChannelGateTests {
    private func drw(channel: UInt8, seq: UInt16) -> [UInt8] {
        [0xF1, 0xD0, 0x00, 0x10, 0xD1, channel, UInt8(seq >> 8), UInt8(seq & 0xFF), 0, 0, 0, 4, 1, 2, 3, 4]
    }

    private func drop(_ gate: inout CS2CommandChannelGate, _ packet: [UInt8], _ count: Int) -> Bool {
        gate.shouldDrop(packet, count: count)
    }

    @Test("Passes the first command messages and their retransmits, then drops the overflow; video is untouched")
    func gatesOnlyOverflowingCommandMessages() {
        var gate = CS2CommandChannelGate()
        for seq in 0..<UInt16(CS2CommandChannelGate.passthroughLimit) {
            #expect(!drop(&gate, drw(channel: 0, seq: seq), 16))
        }
        #expect(!drop(&gate, drw(channel: 0, seq: 0), 16)) // retransmit of a forwarded message
        #expect(drop(&gate, drw(channel: 0, seq: 100), 16))
        #expect(!drop(&gate, drw(channel: 2, seq: 100), 16))
        #expect(!drop(&gate, [0xF1, 0xE0, 0, 0], 4)) // ping
        gate.reset()
        #expect(!drop(&gate, drw(channel: 0, seq: 100), 16))
    }
}
