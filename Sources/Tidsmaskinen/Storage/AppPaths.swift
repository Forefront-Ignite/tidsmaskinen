import Foundation

/// The app's data folder — `~/Library/Application Support/Tidsmaskinen` — home
/// of the database, the hook events log, the mic debug log and AX dumps.
/// `TIDSMASKINEN_DATA_DIR` points a dev build somewhere else so it can run
/// beside the installed app on a snapshot of the data without sharing (and
/// truncating) the live hook events log. `bin/dev-instance.sh` sets it; the
/// `tm-hook` binary deliberately ignores it and always writes the real log.
enum AppPaths {
    /// Explicit data folder for a throwaway dev instance (`bin/dev-instance.sh`).
    static let dataDirectoryOverride: String? = {
        let value = ProcessInfo.processInfo.environment["TIDSMASKINEN_DATA_DIR"] ?? ""
        return value.isEmpty ? nil : value
    }()

    /// A dev copy is recognised by its bundle id as well as by the override, so
    /// one opened from Finder without the variable still keeps its own data
    /// folder and keychain namespace (`KeychainStore.service`) instead of
    /// touching the installed app's database, hook log or tokens.
    static let isDevInstance: Bool =
        dataDirectoryOverride != nil || Bundle.main.bundleIdentifier == "se.forefront.tidsmaskinen.dev"

    static func supportDirectory() throws -> URL {
        let dir: URL
        if let override = dataDirectoryOverride {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dir = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
                .appendingPathComponent(isDevInstance ? "Tidsmaskinen Dev" : "Tidsmaskinen", isDirectory: true)
        }
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return dir
    }
}
