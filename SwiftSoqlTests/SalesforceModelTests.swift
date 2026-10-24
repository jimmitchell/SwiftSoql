import Foundation
import Testing
@testable import SwiftSoql

struct JSONValueTests {
    @Test func keepsKeyOrderAndNumberText() throws {
        let json = try JSONValue.parse(Data(#"{"b":1.50,"a":[true,null,"x"],"c":{"z":-2e3}}"#.utf8))
        #expect(json.object?.keys == ["b", "a", "c"])
        #expect(json["b"] == .number("1.50"))
        #expect(json.serialized == #"{"b":1.50,"a":[true,null,"x"],"c":{"z":-2e3}}"#)
    }

    @Test func escapesRoundTrip() throws {
        let text = "Line 1\nSays \"hi\"\tand \\ backslash é 🙂 \u{01}"
        let parsed = try JSONValue.parse(Data(JSONValue.string(text).serialized.utf8))
        #expect(parsed == .string(text))
        #expect(try JSONValue.parse(Data(#""🙂""#.utf8)) == .string("🙂"))
    }

    @Test func rejectsBadJSON() {
        #expect(throws: JSONParseError.self) { try JSONValue.parse(Data("{\"a\":}".utf8)) }
        #expect(throws: JSONParseError.self) { try JSONValue.parse(Data("[1] x".utf8)) }
    }
}

struct DescribeModelsTests {
    private func describe() throws -> SObjectDescribe {
        let json = #"""
        {"name":"Thing__c","fields":[
          {"name":"Id","type":"id","updateable":false,"nillable":false,"custom":false,"referenceTo":[],"inlineHelpText":null},
          {"name":"Flag__c","type":"boolean","updateable":true,"custom":true,"referenceTo":[]},
          {"name":"Amount__c","type":"currency","updateable":true,"nillable":true,"custom":true},
          {"name":"Stage__c","type":"picklist","updateable":true,"nillable":true,"custom":true,
           "picklistValues":[{"value":"Open","label":"Open","active":true},{"value":"Old","label":"Old","active":false}]}
        ],"childRelationships":[{"childSObject":"Note","field":"ParentId","relationshipName":"Notes","cascadeDelete":false}]}
        """#
        return SObjectDescribe(json: try #require(try JSONValue.parse(Data(json.utf8)).object))
    }

    @Test func dropsEmptyPropertiesButReadsTheSame() throws {
        let d = try describe()
        let id = try #require(d.field(exactly: "Id"))
        #expect(!id.json.keys.contains("updateable") && !id.json.keys.contains("referenceTo") && !id.json.keys.contains("inlineHelpText"))
        #expect(!id.updateable && !id.nillable && id.referenceTo.isEmpty)
        #expect(d.updateableFields == ["Flag__c", "Amount__c", "Stage__c"])
        #expect(d.childRelationships.first?.relationshipName == "Notes")
    }

    @Test func picklistValuesKeepInactiveFlags() throws {
        let stage = try #require(try describe().field(exactly: "Stage__c"))
        #expect(stage.picklistValues.map(\.active) == [true, false])
    }

    @Test func fieldLookups() throws {
        let d = try describe()
        #expect(d.field(exactly: "flag__c") == nil)
        #expect(d.field(named: "flag__c")?.name == "Flag__c")
    }

    @Test func textToFieldValues() throws {
        let d = try describe()
        let flag = try #require(d.field(exactly: "Flag__c"))
        let amount = try #require(d.field(exactly: "Amount__c"))
        let stage = try #require(d.field(exactly: "Stage__c"))
        #expect(try flag.value(fromText: "Yes") == .bool(true))
        #expect(try flag.value(fromText: "") == .bool(false))
        #expect(throws: InvalidFieldValue.self) { try flag.value(fromText: "maybe") }
        #expect(try amount.value(fromText: " 42.50 ") == .number("42.50"))
        #expect(try amount.value(fromText: "") == .null)
        #expect(throws: InvalidFieldValue.self) { try amount.value(fromText: "1,000") }
        #expect(try stage.value(fromText: "Open") == .string("Open"))
        #expect(try stage.value(fromText: "") == .null)
    }
}

struct SalesforceDatesTests {
    @Test func roundTrips() throws {
        let dateTime = try #require(SalesforceDates.parse("2020-05-30T15:41:41.000+0000", includesTime: true))
        #expect(SalesforceDates.format(dateTime, includesTime: true) == "2020-05-30T15:41:41.000Z")
        let day = try #require(SalesforceDates.parse("2001-02-03", includesTime: false))
        #expect(SalesforceDates.format(day, includesTime: false) == "2001-02-03")
    }
}

struct SOAPTests {
    private func root(_ xml: String) throws -> XMLElement {
        try SOAP.root(of: Data(xml.utf8), status: 200)
    }

    @Test func readsAnonymousApexResults() throws {
        let xml = """
        <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns="http://soap.sforce.com/2006/08/apex" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <soapenv:Header><DebuggingInfo><debugLog>68.0 APEX_CODE,DEBUG\nUSER_DEBUG|hi</debugLog></DebuggingInfo></soapenv:Header>
        <soapenv:Body><executeAnonymousResponse><result><column>1</column><compileProblem xsi:nil="true"/><compiled>true</compiled>
        <exceptionMessage>System.MathException: Divide by 0</exceptionMessage><exceptionStackTrace>AnonymousBlock: line 6, column 1</exceptionStackTrace>
        <line>6</line><success>false</success></result></executeAnonymousResponse></soapenv:Body></soapenv:Envelope>
        """
        let run = try AnonymousApex.execution(from: try root(xml), code: "x")
        #expect(run.compiled && !run.success && run.line == 6 && run.column == 1)
        #expect(run.compileProblem == nil && run.resultText == "System.MathException: Divide by 0")
        #expect(run.debugLog.contains("USER_DEBUG|hi"))
    }

    @Test func throwsFaults() {
        let xml = """
        <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"><soapenv:Body><soapenv:Fault>
        <faultcode>sf:INVALID_SESSION_ID</faultcode><faultstring>Invalid Session ID found</faultstring></soapenv:Fault></soapenv:Body></soapenv:Envelope>
        """
        #expect {
            try root(xml)
        } throws: { error in
            (error as? SalesforceError)?.isInvalidSession == true
        }
    }

    @Test func readsUndeleteResults() throws {
        let xml = """
        <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns="urn:partner.soap.sforce.com"><soapenv:Body><undeleteResponse>
        <result><id>001A</id><success>true</success></result>
        <result><errors><message>Entity is not in the recycle bin</message><statusCode>UNDELETE_FAILED</statusCode></errors><id xsi:nil="true" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"/><success>false</success></result>
        </undeleteResponse></soapenv:Body></soapenv:Envelope>
        """
        let results = SOAP.undeleteResults(from: try root(xml))
        #expect(results.map(\.success) == [true, false])
        #expect(results[1].message == "UNDELETE_FAILED: Entity is not in the recycle bin")
    }

    @Test func escapesRequests() {
        let request = AnonymousApex.request(code: "if (a < b && c > d) { s = '\"'; }\r\n", sessionID: "token", logLevels: [:])
        #expect(request.contains("if (a &lt; b &amp;&amp; c &gt; d) { s = '&quot;'; }&#13;\n"))
        #expect(request.contains("<category>Apex_code</category><level>Debug</level>"))
    }
}

struct QueryPlanTests {
    @Test func readsPlans() throws {
        let json = try JSONValue.parse(Data(#"{"plans":[{"cardinality":4,"fields":["IsActive"],"leadingOperationType":"Index","notes":[{"description":"Not considering filter for optimization because unindexed","fields":["IsDeleted"],"tableEnumOrId":"User"}],"relativeCost":1.3333333333333333,"sobjectCardinality":12,"sobjectType":"User"}]}"#.utf8))
        let plan = QueryPlan(id: 0, json: try #require(json["plans"]?.array?.first))
        #expect(plan.leadingOperationType == "Index" && plan.cardinality == 4 && plan.sobjectCardinality == 12)
        #expect(abs(plan.relativeCost - 1.3333) < 0.001)
        #expect(plan.fields == ["IsActive"])
        #expect(plan.notes == ["Not considering filter for optimization because unindexed (IsDeleted)"])
    }
}

struct BrowserLoginTests {
    @Test func onlySalesforceServersGetTokens() throws {
        for good in ["https://login.salesforce.com/id/00D/005", "https://acme.my.salesforce.com", "https://acme--dev.sandbox.my.salesforce.com",
                     "https://acme.lightning.force.com", "https://test.salesforce.com", "https://acme.my.salesforce.mil"] {
            #expect(BrowserLogin.isSalesforceURL(try #require(URL(string: good))), "\(good)")
        }
        for bad in ["http://login.salesforce.com", "https://evil.com", "https://salesforce.com.evil.com", "https://evilsalesforce.com",
                    "https://login.salesforce.com@evil.com", "file:///etc/passwd"] {
            #expect(!BrowserLogin.isSalesforceURL(try #require(URL(string: bad))), "\(bad)")
        }
        #expect(BrowserLogin.normalizedHost(" https://Acme.My.Salesforce.com/ ") == "acme.my.salesforce.com")
        for host in ["evil.com/x.salesforce.com", "evil.com?x.salesforce.com", "evil.com#.salesforce.com", "user@evil.com.salesforce.com:1@x",
                     "evil.com\\.salesforce.com", "evil.com%2F.salesforce.com", "evil.com .salesforce.com", ""] {
            #expect(!BrowserLogin.isSalesforceHost(host), "\(host)")
            #expect(throws: BrowserLoginError.self) { try BrowserLogin.salesforceURL(host: host, path: "/services/oauth2/token") }
        }
        #expect(try BrowserLogin.salesforceURL(host: "acme.my.salesforce.com", path: "/services/oauth2/token").absoluteString == "https://acme.my.salesforce.com/services/oauth2/token")
    }
}

@Suite(.serialized)
struct BrowserLoginKeyTests {
    private func clear() {
        for key in [BrowserLogin.keysSetting, BrowserLogin.legacyKeySetting, "browserLoginKeyByHost"] {
            AppDefaults.store.removeObject(forKey: key)
        }
    }

    @Test func aSingleSavedKeyBecomesTheFirstInTheList() {
        clear()
        defer { clear() }
        #expect(BrowserLogin.consumerKeys.isEmpty, "The shipped app has no built-in key")
        AppDefaults.store.set("  3MVGold \n", forKey: BrowserLogin.legacyKeySetting)
        #expect(BrowserLogin.consumerKeys.map(\.key) == ["3MVGold"])
        #expect(AppDefaults.store.string(forKey: BrowserLogin.legacyKeySetting) == nil)
        #expect(BrowserLogin.consumerKeys.map(\.label) == ["My org"], "Moved once, then read from the list")
    }

    @Test func keysAreTrimmedAndEmptyOnesDropped() {
        clear()
        defer { clear() }
        BrowserLogin.consumerKeys = [.init(label: "Acme Prod", key: " 3MVGa "), .init(label: "Blank", key: "  "), .init(label: "Acme UAT", key: "3MVGb")]
        #expect(BrowserLogin.consumerKeys.map(\.label) == ["Acme Prod", "Acme UAT"])
        #expect(BrowserLogin.consumerKeys.first?.key == "3MVGa")
        #expect(BrowserLogin.lastKey(for: "acme.my.salesforce.com") == nil, "No suggestion before a login")
    }

    @Test func readsLoginsSavedBeforeKeysWereRemembered() throws {
        let old = #"[{"username":"a@b.c","instanceURL":"https://x.my.salesforce.com","loginHost":"login.salesforce.com"}]"#
        let logins = try JSONDecoder().decode([BrowserLogin.SavedLogin].self, from: Data(old.utf8))
        #expect(logins.first?.username == "a@b.c" && logins.first?.consumerKey == nil)
    }
}
