import AsyncHTTPClient
import Hummingbird
import Foundation
import JWTKit
import HummingbirdAuth
import FluentKit
import FluentSQLiteDriver
import HummingbirdFluent

public protocol AppArguments {
    var location: String { get }
    var target: String { get }
}

extension HBApplication {
    /// configure your application
    /// add middleware
    /// setup the encoder/decoder
    /// add your routes
    func configure(_ args: AppArguments) async throws {
            
        // 1. Set up JSON encoder and decoder
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        (self.encoder as! JSONEncoder).dateEncodingStrategy = .iso8601
        self.httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.eventLoopGroup))
        
        // 2. Add logging middleware
        let logLevel = HBEnvironment().get("logLevel") ?? "info"
        self.logger.logLevel = .init(rawValue: logLevel) ?? .info
        self.logger.info("Logger level is set to \(self.logger.logLevel)")
        self.middleware.add(HBLogRequestsMiddleware(.info))
        self.middleware.add(HBLogRequestsMiddleware(.debug))
        self.middleware.add(HBLogRequestsMiddleware(.error))

        // 3. Set up database
        self.addFluent()
//        if let inMemory = HBEnvironment().get("inMemoryDatabase"), inMemory == "1" {
            self.fluent.databases.use(.sqlite(.memory), as: .sqlite)
//        } else {
//            self.fluent.databases.use(.sqlite(.file("db.sqlite")), as: .sqlite)
//        }
        
        // 4. Add migrations
        self.fluent.migrations.add(UserMigration())
        self.fluent.migrations.add(UserRequestMigration())
        try await self.fluent.migrate()
        
        // 5. Fetch JWT private key from environment and set up JWT Signers.
        //    Optional: anonymous (free) users work without it; premium /appstore auth requires it.
        let jwtAuthenticator = JWTAuthenticator()
        let jwtLocalSignerKid = JWKIdentifier("_aiproxy_local_")
        if let jwtKey = HBEnvironment().get("JWTPrivateKey"), !jwtKey.isEmpty {
            jwtAuthenticator.useSigner(.hs256(key: jwtKey), kid: jwtLocalSignerKid)
            self.logger.info("JWT signing enabled — premium authentication available")
        } else {
            self.logger.warning("JWTPrivateKey not set — anonymous access only, premium /appstore auth disabled")
        }

        // 6. Add AppStoreController routes to verify client's purchase and send JWT token to client
        let appStoreController = AppStoreController(jwtSigners: jwtAuthenticator.jwtSigners, kid: jwtLocalSignerKid)
        appStoreController.addRoutes(to: self.router.group("appstore"))
        
        // 7. Add JWT authenticator. Will return unauthorized error if no or invalid JWT token was received
        self.middleware.add(jwtAuthenticator)
        
        // 8. Add rate limiter
        self.middleware.add(RateLimiterMiddleware())

        // 8b. Enforce lifetime free-tier quota via Upstash (no-op when env vars are absent)
        if let quotaService = UpstashQuotaService() {
            self.middleware.add(FreeTierQuotaMiddleware(quotaService: quotaService))
            self.logger.info("Free-tier quota middleware enabled (limit: \(quotaService.freeLimit))")
        } else {
            self.logger.warning("UPSTASH_REDIS_REST_URL/TOKEN not set — free-tier quota middleware disabled")
        }

        // 9. Route message to right provider
        self.middleware.add(MessageRouterMiddleware())
        
        // 10. Add OpenAI API key middleware. This middleware will add the OpenAI org and API key in the header of the request
        self.middleware.add(APIKeyMiddleware())
        
        // 11. Add Proxy middleware. If you don't need any authentication, you can remove steps 3 through 6 above
        self.middleware.add(
            HBProxyServerMiddleware(
                httpClient: httpClient //,
//                proxy: .init(location: args.location, target: args.target) // Note: This is ignored
            )
        )
    }
}

extension HBApplication {
    var httpClient: HTTPClient {
        get { self.extensions.get(\.httpClient) }
        set { self.extensions.set(\.httpClient, value: newValue) { httpClient in
            try httpClient.syncShutdown()
        }}
    }
}
