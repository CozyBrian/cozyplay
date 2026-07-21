import XCTest

final class WireProtocolTests: XCTestCase {

    // MARK: Round trips

    func testJSONControlFrameRoundTrip() throws {
        let hello = HelloMessage(hostID: "cozyplay-ABC", name: "Brian's MacBook", proto: 1)
        let reader = FrameReader()
        reader.append(try WireProtocol.frame(.hello, json: hello))

        let frame = try XCTUnwrap(try reader.next())
        XCTAssertEqual(frame.type, .hello)
        XCTAssertEqual(try WireProtocol.decodeJSON(HelloMessage.self, from: frame.payload), hello)
        XCTAssertNil(try reader.next())
    }

    func testPingPongRoundTrip() throws {
        let reader = FrameReader()
        reader.append(WireProtocol.pingFrame(t0: 123_456_789_012))
        reader.append(WireProtocol.pongFrame(t0: 1, t1: UInt64.max - 5, t2: UInt64.max - 3))

        let ping = try XCTUnwrap(try reader.next())
        XCTAssertEqual(ping.type, .ping)
        XCTAssertEqual(WireProtocol.decodePing(ping.payload), 123_456_789_012)

        let pong = try XCTUnwrap(try reader.next())
        XCTAssertEqual(pong.type, .pong)
        let decoded = try XCTUnwrap(WireProtocol.decodePong(pong.payload))
        XCTAssertEqual(decoded.t0, 1)
        XCTAssertEqual(decoded.t1, UInt64.max - 5)
        XCTAssertEqual(decoded.t2, UInt64.max - 3)
    }

    func testAudioChunkRoundTrip() throws {
        let frames = EngineConstants.chunkFrames
        var samples = Data(count: frames * EngineConstants.bytesPerFrame)
        for i in 0..<samples.count { samples[i] = UInt8(truncatingIfNeeded: i) }
        let chunk = AudioChunk(
            seq: 42, playAtHostNs: 9_876_543_210_123, frameCount: UInt16(frames), samples: samples
        )

        let reader = FrameReader()
        reader.append(WireProtocol.frame(.audio, payload: chunk.encodePayload()))
        let frame = try XCTUnwrap(try reader.next())
        XCTAssertEqual(frame.type, .audio)

        let decoded = try XCTUnwrap(AudioChunk.decode(payload: frame.payload))
        XCTAssertEqual(decoded.seq, 42)
        XCTAssertEqual(decoded.playAtHostNs, 9_876_543_210_123)
        XCTAssertEqual(decoded.frameCount, UInt16(frames))
        XCTAssertEqual(decoded.samples, samples)
    }

    func testAudioChunkRejectsLengthMismatch() {
        var payload = AudioChunk(
            seq: 1, playAtHostNs: 1, frameCount: 960, samples: Data(count: 960 * 4)
        ).encodePayload()
        payload.removeLast()
        XCTAssertNil(AudioChunk.decode(payload: payload))
    }

    func testEmptyPayloadFrame() throws {
        let reader = FrameReader()
        reader.append(WireProtocol.frame(.bye))
        let frame = try XCTUnwrap(try reader.next())
        XCTAssertEqual(frame.type, .bye)
        XCTAssertTrue(frame.payload.isEmpty)
    }

    // MARK: Stream slicing

    func testSplitReadsOneByteAtATime() throws {
        var stream = Data()
        stream.append(WireProtocol.pingFrame(t0: 7))
        stream.append(try WireProtocol.frame(.setVolume, json: SetVolumeMessage(percent: 80, muted: false)))
        stream.append(WireProtocol.pongFrame(t0: 1, t1: 2, t2: 3))

        let reader = FrameReader()
        var received: [WireProtocol.FrameType] = []
        for byte in stream {
            reader.append(Data([byte]))
            while let frame = try reader.next() {
                received.append(frame.type)
            }
        }
        XCTAssertEqual(received, [.ping, .setVolume, .pong])
    }

    func testCoalescedFramesInOneRead() throws {
        var stream = Data()
        for seq in 0..<5 {
            let chunk = AudioChunk(
                seq: UInt32(seq), playAtHostNs: UInt64(seq) * 20_000_000,
                frameCount: 960, samples: Data(count: 960 * EngineConstants.bytesPerFrame)
            )
            stream.append(WireProtocol.frame(.audio, payload: chunk.encodePayload()))
        }

        let reader = FrameReader()
        reader.append(stream)
        var seqs: [UInt32] = []
        while let frame = try reader.next() {
            seqs.append(try XCTUnwrap(AudioChunk.decode(payload: frame.payload)).seq)
        }
        XCTAssertEqual(seqs, [0, 1, 2, 3, 4])
    }

    func testUnknownFrameTypeIsSkipped() throws {
        var unknown = Data([WireProtocol.magic, 0x7F])
        unknown.appendLE(WireProtocol.version)
        unknown.appendLE(UInt32(3))
        unknown.append(contentsOf: [1, 2, 3])

        let reader = FrameReader()
        reader.append(unknown)
        reader.append(WireProtocol.pingFrame(t0: 9))

        let frame = try XCTUnwrap(try reader.next())
        XCTAssertEqual(frame.type, .ping)
        XCTAssertEqual(WireProtocol.decodePing(frame.payload), 9)
    }

    // MARK: Poisoned streams

    func testBadMagicThrows() {
        let reader = FrameReader()
        reader.append(Data([0x00, 0x03, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00]))
        XCTAssertThrowsError(try reader.next()) {
            XCTAssertEqual($0 as? WireProtocol.WireError, .badMagic)
        }
    }

    func testWrongVersionThrows() {
        var frame = Data([WireProtocol.magic, WireProtocol.FrameType.ping.rawValue])
        frame.appendLE(UInt16(99))
        frame.appendLE(UInt32(0))
        let reader = FrameReader()
        reader.append(frame)
        XCTAssertThrowsError(try reader.next()) {
            XCTAssertEqual($0 as? WireProtocol.WireError, .badVersion(99))
        }
    }

    func testOversizedPayloadThrows() {
        var frame = Data([WireProtocol.magic, WireProtocol.FrameType.audio.rawValue])
        frame.appendLE(WireProtocol.version)
        frame.appendLE(UInt32(WireProtocol.maxPayloadLength + 1))
        let reader = FrameReader()
        reader.append(frame)
        XCTAssertThrowsError(try reader.next()) {
            XCTAssertEqual($0 as? WireProtocol.WireError, .payloadTooLarge(WireProtocol.maxPayloadLength + 1))
        }
    }
}
