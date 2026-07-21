import Foundation

/// Writes raw PCM bytes to a named pipe (FIFO) that snapserver reads as its stream
/// source. Opening a FIFO for writing blocks until a reader (snapserver) attaches,
/// so the open happens on a background queue.
final class PipeWriter {
    let path: String
    private let queue = DispatchQueue(label: "africa.inpathgroup.cozyplay.pipe")
    private var fd: Int32 = -1
    private var isOpening = false

    init(path: String) {
        self.path = path
    }

    /// Create the FIFO if it doesn't exist yet.
    func ensureFIFO() throws {
        if !FileManager.default.fileExists(atPath: path) {
            if mkfifo(path, 0o644) != 0 && errno != EEXIST {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
    }

    /// Open the write end (blocks until snapserver opens the read end). Non-fatal if
    /// it can't open yet — callers just start writing once `isOpen` becomes true.
    func openForWriting() {
        queue.async {
            guard self.fd < 0, !self.isOpening else { return }
            self.isOpening = true
            let opened = open(self.path, O_WRONLY)   // blocks until reader present
            self.fd = opened
            self.isOpening = false
            if opened < 0 {
                NSLog("cozyplay: pipe open failed (errno \(errno))")
            }
        }
    }

    var isOpen: Bool { fd >= 0 }

    /// Enqueue a chunk of interleaved S16LE PCM for writing.
    func write(_ data: Data) {
        queue.async {
            guard self.fd >= 0 else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                let base = raw.bindMemory(to: UInt8.self).baseAddress!
                while offset < data.count {
                    let n = Foundation.write(self.fd, base + offset, data.count - offset)
                    if n > 0 {
                        offset += n
                    } else {
                        // EPIPE (reader gone) or would-block; drop the rest of this chunk.
                        break
                    }
                }
            }
        }
    }

    func close() {
        queue.async {
            if self.fd >= 0 { Foundation.close(self.fd); self.fd = -1 }
        }
    }
}
