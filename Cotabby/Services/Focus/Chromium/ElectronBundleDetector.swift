import Foundation

/// File overview:
/// Answers "is this app built on Electron?" by looking for `Electron Framework.framework` inside
/// the app bundle — the framework every Electron app ships (Claude, Slack, Discord, VS Code,
/// Obsidian…). Bundle ids cannot answer this: they are chosen freely by each vendor.
///
/// It is a service (not a pure rule) because it touches the file system. The answer for a bundle
/// path never changes while the app is installed, so it is cached per path: the focus poll can ask
/// on every tick for the cost of a dictionary lookup. Owned by `ChromiumAccessibilityEnabler`.
@MainActor
final class ElectronBundleDetector {
    private let fileExists: (String) -> Bool
    private var cache: [String: Bool] = [:]

    /// `fileExists` is injectable so tests can describe bundles without creating real apps.
    init(fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.fileExists = fileExists
    }

    nonisolated deinit {}

    func isElectron(bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let key = bundleURL.standardizedFileURL.path
        if let cached = cache[key] { return cached }
        let frameworkPath = bundleURL
            .appendingPathComponent("Contents/Frameworks/Electron Framework.framework", isDirectory: true)
            .path
        let result = fileExists(frameworkPath)
        cache[key] = result
        return result
    }
}
