import AsyncHTTPClient
import Foundation
import Hummingbird
import NIOFoundationCompat

struct UpstashQuotaService {

    let restURL:    String
    let restToken:  String
    let freeLimit:  Int

    /// Returns nil when UPSTASH_REDIS_REST_URL / UPSTASH_REDIS_REST_TOKEN are not set.
    init?() {
        let env = HBEnvironment()
        guard let url   = env.get("UPSTASH_REDIS_REST_URL"),   !url.isEmpty,
              let token = env.get("UPSTASH_REDIS_REST_TOKEN"), !token.isEmpty
        else { return nil }
        self.restURL   = url.hasSuffix("/") ? String(url.dropLast()) : url
        self.restToken = token
        self.freeLimit = Int(env.get("FREE_TIER_TOTAL_LIMIT") ?? "") ?? 10
    }

    /// Atomically increments the device counter and returns the new count.
    /// Returns nil on error — caller should fail open.
    func increment(deviceID: String, httpClient: HTTPClient) async -> Int? {
        var req = HTTPClientRequest(url: "\(restURL)/incr/xplainme_quota_\(deviceID)")
        req.method = .POST
        req.headers.add(name: "Authorization", value: "Bearer \(restToken)")

        do {
            let response = try await httpClient.execute(req, timeout: .seconds(3))
            let buffer   = try await response.body.collect(upTo: 1_024)
            let data     = Data(buffer.readableBytesView)
            guard let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let count = json["result"] as? Int
            else { return nil }
            return count
        } catch {
            return nil
        }
    }
}
