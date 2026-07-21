import Foundation

/// cozyplay's wire protocol: one TCP connection per client carrying control,
/// clock-sync, and audio frames.
///
/// Frame layout (little-endian):
/// ```
///  0  UInt8   magic   = 0xC7
///  1  UInt8   type            (FrameType)
///  2  UInt16  version = 1
///  4  UInt32  payloadLength
///  8  payload…
/// ```
/// Control payloads are JSON (tiny, infrequent, debuggable); audio and
/// ping/pong are fixed binary layouts (timestamp precision, zero parse cost
/// at 50 frames/s).
enum WireProtocol {
    static let magic: UInt8 = 0xC7
    static let version: UInt16 = 1
    static let headerSize = 8
    /// Sanity bound; the largest real frame is an audio chunk (~3.9 KB).
    static let maxPayloadLength = 1 << 20

    enum FrameType: UInt8 {
        case hello = 0x01        // C→H  JSON HelloMessage
        case welcome = 0x02      // H→C  JSON WelcomeMessage
        case ping = 0x03         // C→H  binary: t0
        case pong = 0x04         // H→C  binary: t0, t1, t2
        case audio = 0x05        // H→C  binary: AudioChunk
        case setVolume = 0x07    // H→C  JSON SetVolumeMessage
        case setName = 0x08      // H→C  JSON SetNameMessage
        case setLatency = 0x09   // H→C  JSON SetLatencyMessage
        case setBuffer = 0x0A    // H→C  JSON SetBufferMessage
        case bye = 0x0B          // both empty
    }

    enum WireError: Error, Equatable {
        case badMagic
        case badVersion(UInt16)
        case payloadTooLarge(Int)
    }

    // MARK: Frame encoding

    static func frame(_ type: FrameType, payload: Data = Data()) -> Data {
        var data = Data(capacity: headerSize + payload.count)
        data.append(magic)
        data.append(type.rawValue)
        data.appendLE(version)
        data.appendLE(UInt32(payload.count))
        data.append(payload)
        return data
    }

    static func frame<T: Encodable>(_ type: FrameType, json message: T) throws -> Data {
        frame(type, payload: try JSONEncoder().encode(message))
    }

    static func decodeJSON<T: Decodable>(_ kind: T.Type, from payload: Data) throws -> T {
        try JSONDecoder().decode(kind, from: payload)
    }

    // MARK: Clock-sync payloads (binary)

    static func pingFrame(t0: UInt64) -> Data {
        var payload = Data(capacity: 8)
        payload.appendLE(t0)
        return frame(.ping, payload: payload)
    }

    static func decodePing(_ payload: Data) -> UInt64? {
        guard payload.count == 8 else { return nil }
        return payload.readLE64(at: 0)
    }

    static func pongFrame(t0: UInt64, t1: UInt64, t2: UInt64) -> Data {
        var payload = Data(capacity: 24)
        payload.appendLE(t0)
        payload.appendLE(t1)
        payload.appendLE(t2)
        return frame(.pong, payload: payload)
    }

    static func decodePong(_ payload: Data) -> (t0: UInt64, t1: UInt64, t2: UInt64)? {
        guard payload.count == 24 else { return nil }
        return (payload.readLE64(at: 0), payload.readLE64(at: 8), payload.readLE64(at: 16))
    }
}

// MARK: - Control messages

struct HelloMessage: Codable, Equatable {
    var hostID: String
    var name: String
    var proto: Int
}

struct WelcomeMessage: Codable, Equatable {
    var bufferMs: Int
    var sampleRate: Int
    var channels: Int
    var volumePercent: Int
    var muted: Bool
    var latencyMs: Int
}

struct SetVolumeMessage: Codable, Equatable {
    var percent: Int
    var muted: Bool
}

struct SetNameMessage: Codable, Equatable {
    var name: String
}

struct SetLatencyMessage: Codable, Equatable {
    var latencyMs: Int
}

struct SetBufferMessage: Codable, Equatable {
    var bufferMs: Int
}

// MARK: - Audio chunk

/// Payload of an `.audio` frame.
/// ```
///  0  UInt32  seq            (monotonic, diagnostics only)
///  4  UInt64  playAtHostNs   (host uptime ns when frame 0 must hit the DAC)
/// 12  UInt16  frameCount
/// 14  UInt16  reserved
/// 16  [Int16] interleaved S16LE samples
/// ```
struct AudioChunk {
    static let payloadHeaderSize = 16

    var seq: UInt32
    var playAtHostNs: UInt64
    var frameCount: UInt16
    /// Interleaved S16LE stereo sample bytes (`frameCount × bytesPerFrame`).
    var samples: Data

    func encodePayload() -> Data {
        var data = Data(capacity: Self.payloadHeaderSize + samples.count)
        data.appendLE(seq)
        data.appendLE(playAtHostNs)
        data.appendLE(frameCount)
        data.appendLE(UInt16(0))
        data.append(samples)
        return data
    }

    static func decode(payload: Data) -> AudioChunk? {
        guard payload.count >= payloadHeaderSize else { return nil }
        let frameCount = payload.readLE16(at: 12)
        let sampleBytes = Int(frameCount) * EngineConstants.bytesPerFrame
        guard payload.count == payloadHeaderSize + sampleBytes else { return nil }
        return AudioChunk(
            seq: payload.readLE32(at: 0),
            playAtHostNs: payload.readLE64(at: 4),
            frameCount: frameCount,
            samples: payload.subdata(in: payload.startIndex + payloadHeaderSize ..< payload.endIndex)
        )
    }
}

// MARK: - Frame reader

/// Stateful accumulator that slices complete frames out of a TCP byte stream,
/// handling partial and coalesced reads. Unknown frame types are skipped
/// (forward compatibility); a bad magic byte or version poisons the stream
/// and should tear the connection down.
final class FrameReader {
    private var buffer = Data()

    func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete frame, or nil when more bytes are needed.
    func next() throws -> (type: WireProtocol.FrameType, payload: Data)? {
        while true {
            guard buffer.count >= WireProtocol.headerSize else { return nil }
            let base = buffer.startIndex
            guard buffer[base] == WireProtocol.magic else { throw WireProtocol.WireError.badMagic }
            let version = buffer.readLE16(at: 2)
            guard version == WireProtocol.version else { throw WireProtocol.WireError.badVersion(version) }
            let payloadLength = Int(buffer.readLE32(at: 4))
            guard payloadLength <= WireProtocol.maxPayloadLength else {
                throw WireProtocol.WireError.payloadTooLarge(payloadLength)
            }
            let frameSize = WireProtocol.headerSize + payloadLength
            guard buffer.count >= frameSize else { return nil }

            let typeRaw = buffer[base + 1]
            let payload = buffer.subdata(in: base + WireProtocol.headerSize ..< base + frameSize)
            buffer.removeFirst(frameSize)

            guard let type = WireProtocol.FrameType(rawValue: typeRaw) else { continue }
            return (type, payload)
        }
    }
}

// MARK: - Little-endian Data helpers

extension Data {
    mutating func appendLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    /// Reads relative to `startIndex` (safe on slices).
    func readLE16(at offset: Int) -> UInt16 {
        UInt16(littleEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) })
    }

    func readLE32(at offset: Int) -> UInt32 {
        UInt32(littleEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
    }

    func readLE64(at offset: Int) -> UInt64 {
        UInt64(littleEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) })
    }
}
