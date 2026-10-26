import Foundation

enum TestFiles {
    static let onDevice: Bool = {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }()

    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static var bundled: URL {
        Bundle(for: Marker.self).resourceURL!.appendingPathComponent("UITestFixtures")
    }

    static var fixtures: URL {
        onDevice ? bundled : repository.appendingPathComponent("api/tests/fixtures")
    }

    static var large: URL {
        onDevice ? bundled.appendingPathComponent("ProRAW48.DNG") : repository.appendingPathComponent("tmp/large/ProRAW48.DNG")
    }

    static func scratch(_ name: String) -> URL {
        onDevice ? FileManager.default.temporaryDirectory.appendingPathComponent(name) : repository.appendingPathComponent("tmp/\(name)")
    }

    /// The path the app opens for a fixture. On a device it is the copy that
    /// ios/scripts/device_ui_tests.sh put in the app's container.
    static func appPath(_ url: URL) -> String {
        guard onDevice else { return url.path }
        let relative = url.standardizedFileURL.path.dropFirst(bundled.standardizedFileURL.path.count)
        return "Library/UITestFixtures" + relative
    }

    private final class Marker {}
}
