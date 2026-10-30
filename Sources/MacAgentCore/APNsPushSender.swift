import CryptoKit
import Foundation

// MARK: - Config

public struct APNsConfig: Sendable {
    public var keyID: String
    public var teamID: String
    public var bundleID: String
    /// PEM-encoded ES256 private key (content of the .p8 file from Apple Developer).
    public var keyPEM: String
    public var environment: APNsEnvironment

    public enum APNsEnvironment: String, Codable, Sendable {
        case sandbox
        case production

        var host: String {
            switch self {
            case .sandbox: "api.sandbox.push.apple.com"
            case .production: "api.push.apple.com"
            }
        }
    }

    public init(keyID: String, teamID: String, bundleID: String, keyPEM: String, environment: APNsEnvironment) {
        self.keyID = keyID
        self.teamID = teamID
        self.bundleID = bundleID
        self.keyPEM = keyPEM
        self.environment = environment
    }

    // MARK: - Load from Application Support

    public static func load(from directory: URL) throws -> APNsConfig {
        let configURL = directory.appendingPathComponent("apns-config.json")
        let configData = try Data(contentsOf: configURL)

        struct ConfigFile: Codable {
            var keyID: String
            var teamID: String
            var bundleID: String
            var environment: APNsEnvironment
            var keyFileName: String?
        }

        let config = try JSONDecoder().decode(ConfigFile.self, from: configData)
        let keyFileName = config.keyFileName ?? "AuthKey_\(config.keyID).p8"
        let keyURL = directory.appendingPathComponent(keyFileName)
        let keyPEM = try String(contentsOf: keyURL, encoding: .utf8)

        return APNsConfig(
            keyID: config.keyID,
            teamID: config.teamID,
            bundleID: config.bundleID,
            keyPEM: keyPEM,
            environment: config.environment
        )
    }
}

// MARK: - Sender

public final class APNsPushSender: @unchecked Sendable {
    private let config: APNsConfig
    private let urlSession: URLSession
    private let lock = NSLock()
    private var cachedJWT: String?
    private var jwtGeneratedAt: Date?

    // APNs allows JWTs up to 60 min; regenerate at 50 to stay safe.
    private static let jwtTTL: TimeInterval = 50 * 60

    public init(config: APNsConfig) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.httpMaximumConnectionsPerHost = 10
        self.urlSession = URLSession(configuration: sessionConfig)
    }

    /// Send a push notification. Returns `false` when the device token is invalid (caller should remove it).
    @discardableResult
    public func send(title: String, body: String, to deviceToken: String) async -> Bool {
        do {
            let jwt = try getOrGenerateJWT()
            let url = URL(string: "https://\(config.environment.host)/3/device/\(deviceToken)")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
            request.setValue(config.bundleID, forHTTPHeaderField: "apns-topic")
            request.setValue("alert", forHTTPHeaderField: "apns-push-type")
            request.setValue("10", forHTTPHeaderField: "apns-priority")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "aps": ["alert": ["title": title, "body": body], "sound": "default"]
            ])

            let (_, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 410 {
                    return false  // device token invalid
                }
            }
            return true
        } catch {
            return true  // network/config error, don't remove token
        }
    }

    // MARK: - JWT

    private func getOrGenerateJWT() throws -> String {
        let now = Date()
        return try lock.withLock {
            if let cached = cachedJWT, let at = jwtGeneratedAt,
               now.timeIntervalSince(at) < Self.jwtTTL {
                return cached
            }
            let jwt = try buildJWT(now: now)
            cachedJWT = jwt
            jwtGeneratedAt = now
            return jwt
        }
    }

    private func buildJWT(now: Date) throws -> String {
        let header = base64url(try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": config.keyID]))
        let claims = base64url(try JSONSerialization.data(withJSONObject: ["iss": config.teamID, "iat": Int(now.timeIntervalSince1970)]))
        let signingInput = Data("\(header).\(claims)".utf8)
        let key = try P256.Signing.PrivateKey(pemRepresentation: config.keyPEM)
        let sig = try key.signature(for: signingInput)
        // rawRepresentation is r‖s (64 bytes). APNs silently rejects DER-encoded signatures.
        return "\(header).\(claims).\(base64url(sig.rawRepresentation))"
    }

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}
