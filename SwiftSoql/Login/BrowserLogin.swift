import AuthenticationServices
import CryptoKit
import Foundation
import Security

/// Logging in to Salesforce in the browser instead of through the Salesforce CLI.
///
/// Uses the OAuth web server flow with PKCE, so the app needs only the consumer key of a
/// Salesforce External Client App (SalesforceConsumerKey in Info.plist), not a secret. Refresh
/// tokens are kept in the Keychain; the list of logins (username, instance and login host) is
/// kept in the app's settings.
enum BrowserLogin {
    static let redirectURI = "swiftsoql://oauth/callback"
    private static let keychainService = "org.jimmitchell.SwiftSoql.browser-login"
    private static let loginsKey = "browserLogins"

    /// The External Client App's consumer key, if the app was built with one.
    static var consumerKey: String? {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SalesforceConsumerKey") as? String)?.trimmingCharacters(in: .whitespaces)
        return key?.isEmpty == false ? key : nil
    }

    struct SavedLogin: Codable, Equatable {
        var username: String
        var instanceURL: String
        var loginHost: String
    }

    static var savedLogins: [SavedLogin] {
        guard let data = AppDefaults.store.data(forKey: loginsKey) else { return [] }
        return (try? JSONDecoder().decode([SavedLogin].self, from: data)) ?? []
    }

    private static func save(_ logins: [SavedLogin]) {
        AppDefaults.store.set(try? JSONEncoder().encode(logins), forKey: loginsKey)
    }

    static func isSaved(_ username: String) -> Bool {
        savedLogins.contains { $0.username == username }
    }

    static func remove(_ username: String) {
        save(savedLogins.filter { $0.username != username })
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService, kSecAttrAccount: username] as CFDictionary)
    }

    // MARK: Logging in

    /// Opens Salesforce's login page for `host` (login.salesforce.com, test.salesforce.com or a
    /// My Domain), and saves the login once the user has approved access.
    static func logIn(host: String) async throws -> SavedLogin {
        guard let consumerKey else { throw BrowserLoginError("This copy of SwiftSoql wasn't built with a Salesforce consumer key.") }
        let host = normalizedHost(host)

        let verifier = randomURLSafeString(bytes: 48)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var authorize = URLComponents(url: try salesforceURL(host: host, path: "/services/oauth2/authorize"), resolvingAgainstBaseURL: false)!
        authorize.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: consumerKey),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "login"),
        ]
        let callback = try await authenticate(at: authorize.url!)
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
            let description = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "error_description" }?.value
            throw BrowserLoginError(description ?? "Salesforce didn't return an authorization code.")
        }
        let token = try await tokenRequest(host: host, form: [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": consumerKey,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ])
        guard let accessToken = token["access_token"]?.string, let refreshToken = token["refresh_token"]?.string,
              let instanceURL = token["instance_url"]?.string, let identityURL = token["id"]?.string.flatMap(URL.init(string:)) else {
            throw BrowserLoginError("Salesforce's response didn't include a refresh token. Check that the External Client App allows the refresh_token scope.")
        }
        // The access token only goes to Salesforce's own servers.
        guard isSalesforceURL(identityURL), let instance = URL(string: instanceURL), isSalesforceURL(instance) else {
            throw BrowserLoginError("Salesforce's response pointed outside Salesforce, so the login was stopped.")
        }
        let identity = try await getJSON(identityURL, accessToken: accessToken)
        guard let username = identity["username"]?.string else { throw BrowserLoginError("Salesforce didn't say which user logged in.") }
        try storeRefreshToken(refreshToken, for: username)
        let login = SavedLogin(username: username, instanceURL: instanceURL, loginHost: host)
        save(savedLogins.filter { $0.username != username } + [login])
        return login
    }

    /// A fresh session for a saved login, using its refresh token.
    static func session(for username: String) async throws -> OrgSession {
        guard let consumerKey, let login = savedLogins.first(where: { $0.username == username }) else {
            throw BrowserLoginError("There's no saved browser login for \(username).")
        }
        guard let refreshToken = refreshToken(for: username) else {
            throw BrowserLoginError("The saved login for \(username) is missing from the Keychain. Log in again.")
        }
        let token: JSONValue
        do {
            token = try await tokenRequest(host: login.loginHost, form: [
                "grant_type": "refresh_token",
                "client_id": consumerKey,
                "refresh_token": refreshToken,
            ])
        } catch let error as BrowserLoginError {
            throw BrowserLoginError("\(error.message) Remove the saved login and log in again.")
        }
        guard let accessToken = token["access_token"]?.string,
              let instanceURL = URL(string: token["instance_url"]?.string ?? login.instanceURL) else {
            throw BrowserLoginError("Salesforce didn't return an access token.")
        }
        guard isSalesforceURL(instanceURL) else {
            throw BrowserLoginError("Salesforce's response pointed outside Salesforce, so the login was stopped.")
        }
        // Use the newest API version the org supports.
        let versions = try await getJSON(instanceURL.appending(path: "services/data"), accessToken: accessToken)
        let apiVersion = versions.array?.last?["version"]?.string ?? "62.0"
        return OrgSession(username: username, alias: nil, instanceURL: instanceURL, apiVersion: apiVersion, accessToken: accessToken)
    }

    // MARK: Helpers

    /// Salesforce's domains, including its government and China clouds.
    private static let salesforceDomains = ["salesforce.com", "force.com", "cloudforce.com", "database.com",
                                            "salesforce.mil", "sfcrmproducts.cn", "sfcrmapps.cn"]

    /// A bare hostname (letters, digits, dots and hyphens only) on one of Salesforce's domains.
    static func isSalesforceHost(_ host: String) -> Bool {
        let host = host.lowercased()
        guard !host.isEmpty, host.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" }) else { return false }
        return salesforceDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// An https URL for a path on a Salesforce host, built from parts so the host can't spill into
    /// the path, and checked with the same parser that will send the request.
    static func salesforceURL(host: String, path: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        guard isSalesforceHost(host), let url = components.url, isSalesforceURL(url), url.host() == host else {
            throw BrowserLoginError("\(host) isn't a Salesforce login address. My Domains end in .my.salesforce.com.")
        }
        return url
    }

    /// An https URL on one of Salesforce's domains, which is safe to send an access token to.
    static func isSalesforceURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && isSalesforceHost(url.host() ?? "")
    }

    /// Accepts "mydomain.my.salesforce.com", "https://mydomain.my.salesforce.com/" and so on.
    static func normalizedHost(_ text: String) -> String {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: host), let h = url.host() { host = h }
        return host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func authenticate(at url: URL) async throws -> URL {
        let provider = PresentationAnchor()
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme("swiftsoql")) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: error ?? BrowserLoginError("The login didn't finish."))
                }
            }
            session.presentationContextProvider = provider
            session.prefersEphemeralWebBrowserSession = false
            session.start()
            // The session keeps its provider only weakly.
            objc_setAssociatedObject(session, &PresentationAnchor.key, provider, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        nonisolated(unsafe) static var key = 0
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow() }
        }
    }

    private static func tokenRequest(host: String, form: [String: String]) async throws -> JSONValue {
        var request = URLRequest(url: try salesforceURL(host: host, path: "/services/oauth2/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONValue.parse(data)) ?? .null
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BrowserLoginError(json["error_description"]?.string ?? json["error"]?.string ?? "Salesforce refused the login.")
        }
        return json
    }

    private static func getJSON(_ url: URL, accessToken: String) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONValue.parse(data)
    }

    private static func storeRefreshToken(_ token: String, for username: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService, kSecAttrAccount: username]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData] = Data(token.utf8)
        attributes[kSecAttrLabel] = "SwiftSoql login for \(username)"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw BrowserLoginError("Couldn't save the login in the Keychain (error \(status)).") }
    }

    private static func refreshToken(for username: String) -> String? {
        var result: AnyObject?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService, kSecAttrAccount: username,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func randomURLSafeString(bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64URL(data)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct BrowserLoginError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
