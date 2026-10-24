import Foundation

/// An org that the Salesforce CLI (`sf`) has credentials for.
nonisolated struct SFOrg: Sendable, Identifiable, Hashable {
    let username: String
    let alias: String?
    let instanceURL: String
    let connectedStatus: String
    let kind: String
    let isDefault: Bool

    var id: String { username }
    var isConnected: Bool { connectedStatus == "Connected" || connectedStatus == "Active" }
}

nonisolated struct SFCLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs the Salesforce CLI to list authorized orgs and get sessions for them.
nonisolated enum SFCLI {
    static func listOrgs() async throws -> [SFOrg] {
        let result = try await run(["org", "list", "--json"])
        let groups: [(key: String, kind: String)] = [
            ("nonScratchOrgs", "Org"), ("sandboxes", "Sandbox"), ("scratchOrgs", "Scratch"), ("other", "Other"),
        ]
        var seen = Set<String>()
        var orgs: [SFOrg] = []
        for group in groups {
            for item in result[group.key]?.array ?? [] {
                guard let username = item["username"]?.string, seen.insert(username).inserted else { continue }
                let isDevHub = item["isDevHub"]?.bool ?? false
                orgs.append(SFOrg(
                    username: username,
                    alias: item["alias"]?.string,
                    instanceURL: item["instanceUrl"]?.string ?? "",
                    connectedStatus: item["connectedStatus"]?.string ?? item["status"]?.string ?? "",
                    kind: isDevHub && group.kind == "Org" ? "Dev Hub" : group.kind,
                    isDefault: item["isDefaultUsername"]?.bool ?? false
                ))
            }
        }
        return orgs
    }

    /// Gets a current session for an org. The CLI refreshes the access token if it has expired.
    static func session(for username: String) async throws -> OrgSession {
        let display = try await run(["org", "display", "--target-org", username, "--json"])
        guard let urlString = display["instanceUrl"]?.string, let instanceURL = URL(string: urlString) else {
            throw SFCLIError(message: "The Salesforce CLI didn't return an instance URL for \(username).")
        }

        // Newer CLI versions redact the token in `org display` and provide it through `org auth show-access-token`.
        var token = display["accessToken"]?.string ?? ""
        if token.isEmpty || token.hasPrefix("[REDACTED") {
            let auth = try await run(["org", "auth", "show-access-token", "--target-org", username, "--json"])
            token = auth["accessToken"]?.string ?? ""
        }
        guard !token.isEmpty, !token.hasPrefix("[REDACTED") else {
            throw SFCLIError(message: "The Salesforce CLI didn't return an access token for \(username).")
        }

        return OrgSession(
            username: display["username"]?.string ?? username,
            alias: display["alias"]?.string,
            instanceURL: instanceURL,
            apiVersion: display["apiVersion"]?.string ?? "62.0",
            accessToken: token
        )
    }

    /// Runs `sf` with the given arguments and returns the `result` from its JSON output.
    @concurrent
    static func run(_ arguments: [String]) async throws -> JSONValue {
        let environment = await ShellEnvironment.shared.environment()
        guard let executable = findExecutable("sf", path: environment["PATH"] ?? "") else {
            throw SFCLIError(message: "Couldn't find the Salesforce CLI (sf). Install it with `brew install sf` or from developer.salesforce.com/tools/salesforcecli.")
        }
        let output = try await runProcess(executable, arguments: arguments, environment: environment)
        guard let json = try? JSONValue.parse(output.stdout) else {
            let detail = String(decoding: output.stderr.isEmpty ? output.stdout : output.stderr, as: UTF8.self)
            throw SFCLIError(message: "`sf \(arguments.joined(separator: " "))` failed: \(detail.prefix(500))")
        }
        if (json["status"]?.int ?? 0) != 0 || output.exitCode != 0 {
            let message = json["message"]?.string ?? "`sf \(arguments.prefix(2).joined(separator: " "))` exited with status \(output.exitCode)."
            throw SFCLIError(message: message)
        }
        return json["result"] ?? .null
    }

    static func findExecutable(_ name: String, path: String) -> String? {
        path.split(separator: ":")
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct ProcessOutput: Sendable {
        var stdout: Data
        var stderr: Data
        var exitCode: Int32
    }

    static func runProcess(_ executable: String, arguments: [String], environment: [String: String]) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // Drain stderr concurrently so a chatty process can't fill the pipe and block.
                var errData = Data()
                let errReader = DispatchWorkItem { errData = stderr.fileHandleForReading.readDataToEndOfFile() }
                DispatchQueue.global(qos: .userInitiated).async(execute: errReader)
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                errReader.wait()
                process.waitUntilExit()
                continuation.resume(returning: ProcessOutput(stdout: outData, stderr: errData, exitCode: process.terminationStatus))
            }
        }
    }
}

/// The environment from the user's login shell.
///
/// Apps launched from Finder get a minimal PATH, but `sf` and the `node` it runs on are
/// usually installed somewhere like /opt/homebrew/bin or ~/.nvm, set up by shell startup files.
actor ShellEnvironment {
    static let shared = ShellEnvironment()

    private var cached: [String: String]?

    func environment() async -> [String: String] {
        if let cached { return cached }
        var env = ProcessInfo.processInfo.environment
        if let path = await Self.loginShellPath() {
            env["PATH"] = path
        } else {
            let fallback = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.npm-global/bin", "\(NSHomeDirectory())/.volta/bin"]
            env["PATH"] = (fallback + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        }
        env["SF_AUTOUPDATE_DISABLE"] = "true"
        env["NO_COLOR"] = "1"
        cached = env
        return env
    }

    private static func loginShellPath() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__SWIFTSOQL_PATH__"
        // An interactive login shell reads the same startup files as Terminal does.
        let command = "printf '\(marker)%s\(marker)' \"$PATH\""
        guard let output = try? await withTimeout(seconds: 10, {
            try await SFCLI.runProcess(shell, arguments: ["-l", "-i", "-c", command], environment: ProcessInfo.processInfo.environment)
        }) else { return nil }
        let text = String(decoding: output.stdout, as: UTF8.self)
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        return parts[1]
    }
}

private nonisolated func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable @concurrent () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CancellationError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}
