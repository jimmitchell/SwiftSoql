import Foundation
import Testing
@testable import SwiftSoql

struct OrgKindTests {
    private func kind(_ json: String) throws -> OrgKind {
        OrgKind(organization: try #require(try JSONValue.parse(Data(json.utf8)).object))
    }

    @Test func classifiesOrganizations() throws {
        #expect(try kind(#"{"IsSandbox": false, "OrganizationType": "Enterprise Edition", "TrialExpirationDate": null}"#) == .production)
        #expect(try kind(#"{"IsSandbox": false, "OrganizationType": "Developer Edition", "TrialExpirationDate": null}"#) == .developerEdition)
        #expect(try kind(#"{"IsSandbox": true, "OrganizationType": "Enterprise Edition", "TrialExpirationDate": null}"#) == .sandbox)
        #expect(try kind(#"{"IsSandbox": true, "OrganizationType": "Developer Edition", "TrialExpirationDate": "2026-11-01T00:00:00.000+0000"}"#) == .scratch)
        #expect(try kind(#"{"IsSandbox": false, "OrganizationType": "Enterprise Edition", "TrialExpirationDate": "2026-11-01T00:00:00.000+0000"}"#) == .trial)
    }

    @Test func guardsProductionAndUnknownOrgs() {
        #expect(OrgKind.production.isGuarded(lockDeveloperEdition: false))
        #expect(OrgKind.unknown.isGuarded(lockDeveloperEdition: false), "An org whose type can't be read is treated as production")
        #expect(!OrgKind.developerEdition.isGuarded(lockDeveloperEdition: false))
        #expect(OrgKind.developerEdition.isGuarded(lockDeveloperEdition: true))
        #expect(![OrgKind.sandbox, .scratch, .trial].contains { $0.isGuarded(lockDeveloperEdition: true) })
    }
}
