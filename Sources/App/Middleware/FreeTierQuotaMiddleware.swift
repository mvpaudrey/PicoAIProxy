import Foundation
import Hummingbird
import HummingbirdAuth

/// Enforces a lifetime request quota for free-tier (unauthenticated) users.
/// Paid users — those whose JWT resolved to a non-nil appAccountToken — are exempt.
/// The check is skipped entirely when UPSTASH_REDIS_REST_URL is not configured.
struct FreeTierQuotaMiddleware: HBAsyncMiddleware {

    let quotaService: UpstashQuotaService

    func apply(to request: HBRequest, next: HBResponder) async throws -> HBResponse {

        // Paid users bypass the quota entirely
        if let user = try? request.authRequire(User.self), user.appAccountToken != nil {
            return try await next.respond(to: request)
        }

        // No device ID → skip (fail open). Legitimate devices always send this header.
        guard let deviceID = request.headers.first(name: "X-Device-ID"), !deviceID.isEmpty else {
            request.logger.warning("FreeTierQuotaMiddleware: missing X-Device-ID, skipping quota check")
            return try await next.respond(to: request)
        }

        let allowed = await quotaService.checkAndIncrement(
            deviceID: deviceID,
            httpClient: request.application.httpClient
        )

        guard allowed else {
            request.logger.info("FreeTierQuotaMiddleware: device \(deviceID) exceeded free tier quota (\(quotaService.freeLimit))")
            throw HBHTTPError(.tooManyRequests, message: "Free tier quota exceeded. Subscribe to continue.")
        }

        return try await next.respond(to: request)
    }
}
