import AsyncHTTPClient
import Foundation
import Hummingbird
import NIOFoundationCompat

struct UpstashQuotaService {

    let restURL: String
    let restToken: String
    let freeLimit: Int

    /// Returns nil when UPSTASH_REDIS_REST_URL / UPSTASH_REDIS_REST_TOKEN are not set.
    /// In that case FreeTierQuotaMiddleware skips the check entirely.
    init?() {
        let env = HBEnvironment()
        guard let url   = env.get("UPSTASH_REDIS_REST_URL"),   !url.isEmpty,
              let token = env.get("UPSTASH_REDIS_REST_TOKEN"), !token.isEmpty
        else { return nil }
        self.restURL    = url.hasSuffix("/") ? String(url.dropLast()) : url
        self.restToken  = token
        self.freeLimit  = Int(env.get("FREE_TIER_TOTAL_LIMIT") ?? "") ?? 10
    }

    /// Atomically increments the device counter in Upstash and returns whether
    /// the request is within the free-tier limit.
    /// Fails open (returns true) when Upstash is unreachable so a network hiccup
    /// never blocks legitimate users.
    func checkAndIncrement(deviceID: String, httpClient: HTTPClient) async -> Bool {
        let key = "xplainme_quota_\(deviceID)"
        var req = HTTPClientRequest(url: "\(restURL)/incr/\(key)")
        req.method = .POST
        req.headers.add(name: "Authorization", value: "Bearer \(restToken)")

        do {
            let response = try await httpClient.execute(req, timeout: .seconds(3))
            let buffer   = try await response.body.collect(upTo: 1_024)
            let data     = Data(buffer.readableBytesView)
            guard let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let count = json["result"] as? Int
            else { return true }
            return count <= freeLimit
        } catch {
            return true
        }
    }
}
