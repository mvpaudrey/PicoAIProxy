//
//  MessageParserMiddleware.swift
//
//
//  Created by Ronald Mannak on 4/6/24.
//

import Foundation
import Hummingbird
import NIOHTTP1

/// Note: The Anthropic API is very picky. `max_tokens` is required (an option in OpenAI) and the
/// roles must alternate between `user` and `assistant`. It won't accept multiple `user` roles in a row
/// and extra inputs are not permitted (e.g. `user`)
struct MessageRouterMiddleware: HBAsyncMiddleware {
    
    func apply(to request: Hummingbird.HBRequest, next: any Hummingbird.HBResponder) async throws -> Hummingbird.HBResponse {
        
        // 1. Fetch body
        let request = try await request.collateBody().get()
        guard let buffer = request.body.buffer, let body = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes), let data = body.data(using: .utf8) else {
            request.logger.error("Unable to decode body in MessageRouterMiddleware")
            throw HBHTTPError(.badRequest)
        }
        
        // 2. Rewrite model and max_tokens from env vars, then route to the right provider
        var headers = request.headers
        var uri = request.uri.string

        let enforcedModel    = HBEnvironment().get("MODEL")
        let enforcedMaxTokens = HBEnvironment().get("MAX_TOKENS").flatMap(Int.init)

        // Parse body as a mutable dictionary so we can override fields
        var bodyDict = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]

        let modelName: String
        if let m = enforcedModel, !m.isEmpty {
            modelName = m
            bodyDict["model"] = m
        } else if let m = bodyDict["model"] as? String {
            modelName = m
        } else {
            modelName = ""
        }

        if let cap = enforcedMaxTokens {
            let requested = bodyDict["max_tokens"] as? Int ?? Int.max
            bodyDict["max_tokens"] = min(requested, cap)
        }

        if let model = LLMModel.fetch(model: modelName) {
            request.logger.info("Rerouting \(model.name) to \(model.provider.name)")
            headers.replaceOrAdd(name: "model", value: model.name)
            if !model.proxy().location.isEmpty {
                uri = model.proxy().location
            }
        }

        // Re-encode the (possibly modified) body
        let newData = (try? JSONSerialization.data(withJSONObject: bodyDict)) ?? data
        var newBuffer = ByteBuffer()
        newBuffer.writeBytes(newData)

        // 3. Update header and body
        let head = HTTPRequestHead(version: request.version, method: request.method, uri: uri, headers: headers)
        let convertedRequest = HBRequest(head: head, body: .byteBuffer(newBuffer), application: request.application, context: request.context)
        
        let response = try await next.respond(to: convertedRequest)
//        print("---")
//        switch response.body {
//        case .stream(let streamer):
//            let output = streamer.read(on: request.eventLoop)
//            output.whenSuccess { output in
//                print(output)
//            }
//        default:
//            break
//        }
//        print("---")
        return response
//        return try await next.respond(to: convertedRequest)
    }
}

