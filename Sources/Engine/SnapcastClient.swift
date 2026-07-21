import Foundation
import IOKit

/// Manages a bundled `snapclient` child process that connects to a snapserver and
/// plays the synced stream through Core Audio. Used both on companions and locally
/// on the master (so the master's own speakers stay in the synced group).
final class SnapcastClient {
    enum ClientError: Error, LocalizedError {
        case binaryMissing
        var errorDescription: String? {
            switch self {
            case .binaryMissing:
                return "snapclient isn't bundled yet. Run scripts/build-snapcast.sh."
            }
        }
    }

    let host: String
    let hostID: String
    let displayName: String
    private var process: Process?

    /// - Parameters:
    ///   - host: master address ("127.0.0.1" for the master's own local client).
    ///   - hostID: stable client id so this Mac keeps its identity/volume on reconnect.
    ///   - displayName: friendly name reported to the server.
    init(host: String, hostID: String = SnapcastClient.stableHostID(), displayName: String = Host.current().localizedName ?? "MacBook") {
        self.host = host
        self.hostID = hostID
        self.displayName = displayName
    }

    func start() throws {
        guard let binary = SnapcastBinaries.snapclient else { throw ClientError.binaryMissing }

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            "-h", host,
            "--player", "coreaudio",
            "--hostID", hostID,
            "--logsink", "stderr",
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        process = proc
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    /// A stable per-machine id derived from the hardware UUID when available.
    static func stableHostID() -> String {
        if let uuid = hardwareUUID() { return "cozyplay-\(uuid)" }
        return "cozyplay-\(Host.current().localizedName ?? UUID().uuidString)"
    }

    private static func hardwareUUID() -> String? {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }
        guard let cf = IORegistryEntryCreateCFProperty(
            platformExpert, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String else { return nil }
        return cf
    }
}
