import Foundation

/// Locates the bundled Snapcast helper executables.
///
/// The build script (scripts/build-snapcast.sh) places universal/arm64 binaries and
/// their dylibs in `cozyplay.app/Contents/Helpers`. During development, if they are
/// not bundled yet, we fall back to anything on the PATH / Homebrew location so the
/// app can still be exercised.
enum SnapcastBinaries {
    static var helpersDirectory: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
    }

    static var snapserver: URL? { resolve("snapserver") }
    static var snapclient: URL? { resolve("snapclient") }

    static var areInstalled: Bool { snapserver != nil && snapclient != nil }

    private static func resolve(_ name: String) -> URL? {
        let bundled = helpersDirectory.appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }

        // Dev fallbacks: Homebrew, then generic /usr/local.
        for candidate in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}
