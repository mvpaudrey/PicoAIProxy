import AsyncHTTPClient
import Foundation
import Hummingbird
import JWTKit
import NIOFoundationCompat

/// Wraps Apple's DeviceCheck API to persistently track free-tier quota exhaustion
/// across app reinstalls using the device's 2-bit server-side storage.
///
/// Bit mapping:
///   bit0 = true  →  this device has exhausted its free tier quota
///   bit1         →  reserved for future use
///
/// Fails open on every network or parsing error so infra issues never block users.
struct DeviceCheckService {

    private let teamID:        String
    private let keyID:         String
    private let privateKeyPEM: String
    private let baseURL:       String

    /// Returns nil when any required env var is absent.
    init?() {
        let env = HBEnvironment()
        guard let key    = env.get("DEVICE_CHECK_PRIVATE_KEY"), !key.isEmpty,
              let keyID  = env.get("DEVICE_CHECK_KEY_ID"),      !keyID.isEmpty,
              let teamID = env.get("DEVICE_CHECK_TEAM_ID"),     !teamID.isEmpty
        else { return nil }

        self.teamID        = teamID
        self.keyID         = keyID
        // Railway stores multi-line env vars with literal \n — restore real newlines
        self.privateKeyPEM = key.replacingOccurrences(of: "\\n", with: "\n")

        let environment = env.get("ENVIRONMENT") ?? "Production"
        self.baseURL = (environment == "Sandbox" || environment == "Development")
            ? "https://api.development.devicecheck.apple.com/v1"
            : "https://api.devicecheck.apple.com/v1"
    }

    // MARK: - Public API

    /// Returns true when Apple's servers confirm this device has been marked as quota-exhausted.
    /// A 404 or empty body means the device has never had bits set → returns false (new device).
    func isQuotaExhausted(deviceToken: String, httpClient: HTTPClient) async -> Bool {
        guard let jwt      = try? makeJWT(),
              let bodyData = makeBody(deviceToken: deviceToken)
        else { return false }

        var req = HTTPClientRequest(url: "\(baseURL)/query_two_bits")
        req.method = .POST
        req.headers.add(name: "Authorization", value: "Bearer \(jwt)")
        req.headers.add(name: "Content-Type",  value: "application/json")
        req.body = .bytes(ByteBuffer(bytes: bodyData))

        do {
            let response = try await httpClient.execute(req, timeout: .seconds(5))
            guard response.status == .ok else { return false }

            let buffer = try await response.body.collect(upTo: 4_096)
            let data   = Data(buffer.readableBytesView)

            // Empty body = device has never had bits set = not exhausted
            guard !data.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bit0 = json["bit0"] as? Bool
            else { return false }

            return bit0
        } catch {
            return false
        }
    }

    /// Permanently marks the device as quota-exhausted (bit0 = true).
    /// Fire-and-forget: errors are silently discarded.
    func markQuotaExhausted(deviceToken: String, httpClient: HTTPClient) async {
        guard let jwt = try? makeJWT() else { return }

        var payload: [String: Any] = makePayload(deviceToken: deviceToken)
        payload["bit0"] = true
        payload["bit1"] = false
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var req = HTTPClientRequest(url: "\(baseURL)/update_two_bits")
        req.method = .POST
        req.headers.add(name: "Authorization", value: "Bearer \(jwt)")
        req.headers.add(name: "Content-Type",  value: "application/json")
        req.body = .bytes(ByteBuffer(bytes: bodyData))

        _ = try? await httpClient.execute(req, timeout: .seconds(5))
    }

    // MARK: - Private

    private struct Payload: JWTPayload {
        enum CodingKeys: String, CodingKey {
            case issuer   = "iss"
            case issuedAt = "iat"
        }
        var issuer:   IssuerClaim
        var issuedAt: IssuedAtClaim
        func verify(using signer: JWTSigner) throws {}
    }

    private func makeJWT() throws -> String {
        let key     = try ECDSAKey.private(pem: privateKeyPEM)
        let signers = JWTSigners()
        let kid     = JWKIdentifier(string: keyID)
        signers.use(.es256(key: key), kid: kid)
        return try signers.sign(
            Payload(issuer: IssuerClaim(value: teamID),
                    issuedAt: IssuedAtClaim(value: Date())),
            kid: kid
        )
    }

    private func makePayload(deviceToken: String) -> [String: Any] {
        [
            "device_token":   deviceToken,
            "transaction_id": UUID().uuidString,
            "timestamp":      Int(Date().timeIntervalSince1970 * 1000)
        ]
    }

    private func makeBody(deviceToken: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: makePayload(deviceToken: deviceToken))
    }
}
