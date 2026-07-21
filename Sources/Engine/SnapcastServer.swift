import Foundation

/// Manages a bundled `snapserver` child process configured to read raw PCM from
/// a named pipe (FIFO) and stream it to Snapcast clients on the LAN.
final class SnapcastServer {
    enum ServerError: Error, LocalizedError {
        case binaryMissing
        var errorDescription: String? {
            switch self {
            case .binaryMissing:
                return "snapserver isn't bundled yet. Run scripts/build-snapcast.sh."
            }
        }
    }

    /// Snapcast stream format written to the FIFO — integer PCM only (float is not
    /// supported by the pipe source), so the capture path must deliver S16LE.
    static let sampleRate = 48_000
    static let bitDepth = 16
    static let channels = 2

    let fifoPath: String
    private let streamName: String
    private let codec: String
    private var process: Process?

    /// - Parameters:
    ///   - fifoPath: absolute path to the FIFO snapserver will read from.
    ///   - streamName: Snapcast stream name shown to clients.
    ///   - codec: "flac" (default, ~26ms) or "pcm" (no codec latency).
    init(fifoPath: String, streamName: String = "cozyplay", codec: String = "flac") {
        self.fifoPath = fifoPath
        self.streamName = streamName
        self.codec = codec
    }

    /// The `source =` line for snapserver's config / -s argument.
    var sourceURI: String {
        let fmt = "\(Self.sampleRate):\(Self.bitDepth):\(Self.channels)"
        return "pipe://\(fifoPath)?name=\(streamName)&sampleformat=\(fmt)&codec=\(codec)"
    }

    func start() throws {
        guard let binary = SnapcastBinaries.snapserver else { throw ServerError.binaryMissing }

        let proc = Process()
        proc.executableURL = binary
        // -s <source> defines the stream inline; --logsink keeps output on stderr.
        proc.arguments = ["-s", sourceURI, "--logsink", "stderr"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        process = proc
    }

    func stop() {
        process?.terminate()
        process = nil
    }
}
