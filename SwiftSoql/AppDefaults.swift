import Foundation

/// Where the app keeps its settings.
///
/// Launched with `-Testing YES` (as the unit and UI tests do), the app uses a separate store that
/// starts out empty each launch, so tests neither see nor change the user's settings, recent
/// queries or tabs. Launch arguments still override either store's values.
nonisolated enum AppDefaults {
    static let testingSuiteName = "org.jimmitchell.SwiftSoql.Testing"

    static let isTesting = UserDefaults.standard.bool(forKey: "Testing")

    static let store: UserDefaults = {
        guard isTesting, let testing = UserDefaults(suiteName: testingSuiteName) else { return .standard }
        testing.removePersistentDomain(forName: testingSuiteName)
        return testing
    }()
}
