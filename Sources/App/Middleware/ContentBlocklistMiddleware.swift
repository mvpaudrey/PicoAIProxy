import Foundation
import Hummingbird

/// Screens the first user message against a blocklist of age-inappropriate terms
/// before the request reaches the LLM. On a match, returns a 200 [[OOS]] response
/// in the format the iOS client already expects, without incurring an API call.
struct ContentBlocklistMiddleware: HBAsyncMiddleware {

    private static let blockedTerms: [String] = [
        // Explicit sexual content
        "pornographie", "pornography", "porn", "acte sexuel explicite", "explicit sex act",
        // Graphic violence
        "gore", "mutilation", "comment torturer", "how to torture",
        "comment tuer quelqu'un", "how to kill someone",
        // Drug preparation
        "synthèse de drogue", "fabriquer de la drogue", "how to make meth",
        "comment faire de l'héroïne", "cook drugs", "drug synthesis",
        // Self-harm
        "comment me suicider", "méthode de suicide", "how to kill myself",
        "self-harm method", "comment me blesser", "how to cut myself",
    ]

    private static func isBlocked(_ question: String) -> Bool {
        let q = question.lowercased()
        return blockedTerms.contains { q.contains($0) }
    }

    func apply(to request: HBRequest, next: HBResponder) async throws -> HBResponse {
        let req = try await request.collateBody().get()

        // Extract the first user message content; fail open if unparseable
        guard
            let buffer = req.body.buffer,
            let body = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes),
            let data = body.data(using: .utf8),
            let bodyDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let messages = bodyDict["messages"] as? [[String: Any]],
            let firstContent = messages.first?["content"] as? String
        else {
            return try await next.respond(to: req)
        }

        guard Self.isBlocked(firstContent) else {
            return try await next.respond(to: req)
        }

        req.logger.info("ContentBlocklistMiddleware: blocked question — returning [[OOS]]")

        // Response format matches ClaudeService.swift: json["content"][0]["text"]
        let responseBody: [String: Any] = [
            "content": [["text": "[[OOS]] Ce sujet n'est pas disponible dans XPlainMe. Pose-moi une question sur un concept scientifique, historique ou culturel !"]]
        ]
        let responseData = try JSONSerialization.data(withJSONObject: responseBody)
        var responseBuffer = ByteBufferAllocator().buffer(capacity: responseData.count)
        responseBuffer.writeBytes(responseData)
        return HBResponse(
            status: .ok,
            headers: ["content-type": "application/json"],
            body: .byteBuffer(responseBuffer)
        )
    }
}
