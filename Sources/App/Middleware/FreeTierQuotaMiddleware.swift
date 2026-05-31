import Foundation
import Hummingbird
import HummingbirdAuth

/// Enforces a lifetime request quota for free-tier users.
///
/// Strategy:
///   1. Paid users (valid JWT with non-nil appAccountToken) are exempt.
///   2. Upstash INCR tracks the per-device count (keyed by X-Device-ID UUID).
///   3. DeviceCheck (when configured) adds a persistent gate that survives reinstalls:
///      - On the first request with a new UUID (count == 1), we check DeviceCheck bit0.
///        If bit0 == true, the device previously exhausted its quota and reinstalled → reject.
///      - When the counter reaches the limit, we fire-and-forget a DeviceCheck bit0 = true
///        so future reinstalls are caught.
///   4. Everything fails open — infra errors never block legitimate users.
struct FreeTierQuotaMiddleware: HBAsyncMiddleware {

    let quotaService:       UpstashQuotaService
    let deviceCheckService: DeviceCheckService?

    func apply(to request: HBRequest, next: HBResponder) async throws -> HBResponse {

        // Paid users bypass the quota
        if let user = try? request.authRequire(User.self), user.appAccountToken != nil {
            return try await next.respond(to: request)
        }

        guard let deviceID = request.headers.first(name: "X-Device-ID"), !deviceID.isEmpty else {
            request.logger.warning("FreeTierQuotaMiddleware: missing X-Device-ID, skipping quota check")
            return try await next.respond(to: request)
        }

        let httpClient  = request.application.httpClient
        let deviceToken = request.headers.first(name: "X-Device-Token")

        // Increment counter; fail open if Upstash is unreachable
        guard let count = await quotaService.increment(deviceID: deviceID, httpClient: httpClient) else {
            return try await next.respond(to: request)
        }

        // count == 1 means this is the first request with this UUID.
        // It could be a genuine first use OR a reinstall after exhausting the quota.
        // DeviceCheck bit0 tells us which — if set, this device already used its free tier.
        if count == 1,
           let service = deviceCheckService,
           let token   = deviceToken,
           await service.isQuotaExhausted(deviceToken: token, httpClient: httpClient) {
            request.logger.info("FreeTierQuotaMiddleware: device \(deviceID) reinstalled after exhausting quota (DeviceCheck)")
            throw HBHTTPError(.tooManyRequests, message: "Free tier quota exceeded. Subscribe to continue.")
        }

        // Over the limit
        if count > quotaService.freeLimit {
            request.logger.info("FreeTierQuotaMiddleware: device \(deviceID) over limit (\(count)/\(quotaService.freeLimit))")
            throw HBHTTPError(.tooManyRequests, message: "Free tier quota exceeded. Subscribe to continue.")
        }

        // Exactly at the limit on this request: permanently mark the device in DeviceCheck
        if count == quotaService.freeLimit,
           let service = deviceCheckService,
           let token   = deviceToken {
            Task {
                await service.markQuotaExhausted(deviceToken: token, httpClient: httpClient)
            }
            request.logger.info("FreeTierQuotaMiddleware: device \(deviceID) reached quota — marked in DeviceCheck")
        }

        return try await next.respond(to: request)
    }
}
