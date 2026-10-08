import Testing
import Foundation
@testable import resimuretici

@Suite struct ApiModelsTests {
    @Test func snakeCaseDecoding() throws {
        let json = #"{"prompt":"cat","negative_prompt":"dog","seed":42,"translate":false}"#
        let dto = try JSONDecoder().decode(GenerateRequestDTO.self, from: Data(json.utf8))
        #expect(dto.prompt == "cat")
        #expect(dto.negativePrompt == "dog")
        #expect(dto.seed == 42)
        #expect(dto.translate == false)
    }

    @Test func defaultsApplied() throws {
        let json = #"{"prompt":"a cat"}"#
        let dto = try JSONDecoder().decode(GenerateRequestDTO.self, from: Data(json.utf8))
        let (request, translate) = try dto.validated()
        #expect(request.steps == 25)
        #expect(request.guidance == 7.5)
        #expect(request.negativePrompt == "")
        #expect(translate == true)
    }

    @Test func nullSeedBecomesRandomButDoesNotThrow() throws {
        let json = #"{"prompt":"a cat","seed":null}"#
        let dto = try JSONDecoder().decode(GenerateRequestDTO.self, from: Data(json.utf8))
        _ = try dto.validated()
    }

    @Test func emptyAndWhitespacePromptThrows() throws {
        for body in [#"{"prompt":""}"#, #"{"prompt":"   \n  "}"#] {
            let dto = try JSONDecoder().decode(GenerateRequestDTO.self, from: Data(body.utf8))
            #expect(throws: RequestValidationError.self) { try dto.validated() }
        }
    }

    @Test func promptOver500CharsThrows() throws {
        let long = String(repeating: "a", count: 501)
        let body = "{\"prompt\":\"\(long)\"}"
        let dto = try JSONDecoder().decode(GenerateRequestDTO.self, from: Data(body.utf8))
        #expect(throws: RequestValidationError.self) { try dto.validated() }
    }

    @Test func promptAt500CharsPasses() throws {
        let exact = String(repeating: "a", count: 500)
        let body = "{\"prompt\":\"\(exact)\"}"
        let dto = try JSONDecoder().decode(GenerateRequestDTO.self, from: Data(body.utf8))
        _ = try dto.validated()
    }

    @Test func stepsAndGuidanceBoundaries() throws {
        func validated(_ json: String) throws -> GenerationRequest {
            try JSONDecoder().decode(GenerateRequestDTO.self, from: Data(json.utf8)).validated().request
        }
        // steps=1 PNDMScheduler'da process'i düşüren crash (Scheduler.swift:199) — reddedilir.
        #expect(throws: RequestValidationError.self) {
            try JSONDecoder().decode(GenerateRequestDTO.self, from: Data(#"{"prompt":"x","steps":1}"#.utf8)).validated()
        }
        #expect(try validated(#"{"prompt":"x","steps":2}"#).steps == 2)
        #expect(try validated(#"{"prompt":"x","steps":50}"#).steps == 50)
        #expect(throws: RequestValidationError.self) {
            try JSONDecoder().decode(GenerateRequestDTO.self, from: Data(#"{"prompt":"x","steps":51}"#.utf8)).validated()
        }
        #expect(try validated(#"{"prompt":"x","guidance":1.0}"#).guidance == 1.0)
        #expect(try validated(#"{"prompt":"x","guidance":15.0}"#).guidance == 15.0)
        #expect(throws: RequestValidationError.self) {
            try JSONDecoder().decode(GenerateRequestDTO.self, from: Data(#"{"prompt":"x","guidance":0.5}"#.utf8)).validated()
        }
        #expect(throws: RequestValidationError.self) {
            try JSONDecoder().decode(GenerateRequestDTO.self, from: Data(#"{"prompt":"x","guidance":20.0}"#.utf8)).validated()
        }
    }

    @Test func errorEnvelopeRoundTrip() throws {
        let envelope = ApiErrorEnvelope(error: .init(code: ApiErrorCode.invalidRequest.rawValue, message: "mesaj"))
        let data = try JSONEncoder().encode(envelope)
        let back = try JSONDecoder().decode(ApiErrorEnvelope.self, from: data)
        #expect(back.error.code == "invalid_request")
        #expect(back.error.message == "mesaj")
    }
}
