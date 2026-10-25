import SwiftUI

/// What kind of org a window is connected to, from its Organization record. Production orgs are
/// guarded: their windows start read-only.
nonisolated enum OrgKind: String, Sendable {
    case production
    case developerEdition
    case sandbox
    case scratch
    case trial
    /// The Organization record couldn't be read, so the org is guarded as if it were production.
    case unknown

    /// Reads `SELECT IsSandbox, OrganizationType, TrialExpirationDate FROM Organization`.
    init(organization: JSONObject) {
        let hasTrialEnd = organization["TrialExpirationDate"]?.string != nil
        if organization["IsSandbox"]?.bool == true {
            // Scratch orgs are sandboxes that expire.
            self = hasTrialEnd ? .scratch : .sandbox
        } else if organization["OrganizationType"]?.string == "Developer Edition" {
            self = .developerEdition
        } else {
            self = hasTrialEnd ? .trial : .production
        }
    }

    static let query = "SELECT IsSandbox, OrganizationType, TrialExpirationDate FROM Organization"

    var title: String {
        switch self {
        case .production: "Production"
        case .developerEdition: "Developer Edition"
        case .sandbox: "Sandbox"
        case .scratch: "Scratch Org"
        case .trial: "Trial"
        case .unknown: "Unknown Org Type"
        }
    }

    var color: Color {
        switch self {
        case .production, .unknown: .red
        case .developerEdition: .blue
        case .sandbox: .green
        case .scratch, .trial: .gray
        }
    }

    /// Whether windows connected to this kind of org start read-only. Developer Edition orgs are
    /// guarded too when Settings says so.
    func isGuarded(lockDeveloperEdition: Bool) -> Bool {
        switch self {
        case .production, .unknown: true
        case .developerEdition: lockDeveloperEdition
        case .sandbox, .scratch, .trial: false
        }
    }
}
