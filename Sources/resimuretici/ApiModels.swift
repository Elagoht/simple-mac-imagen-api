import Foundation

struct GenerateRequestDTO: Codable, Sendable {
    var prompt: String
    var negativePrompt: String?
    var steps: Int?
    var guidance: Double?
    var seed: UInt64?
    var translate: Bool?

    enum CodingKeys: String, CodingKey {
        case prompt
        case negativePrompt = "negative_prompt"
        case steps, guidance, seed, translate
    }
}

struct GenerationRequest: Sendable, Equatable {
    var prompt: String
    var negativePrompt: String
    var steps: Int
    var guidance: Double
    var seed: UInt64

    static let defaultSteps = 25
    static let defaultGuidance = 7.5

    func withPrompt(_ newPrompt: String) -> GenerationRequest {
        var copy = self
        copy.prompt = newPrompt
        return copy
    }
}

enum RequestValidationError: Error, Equatable {
    case emptyPrompt
    case promptTooLong(current: Int)
    case negativePromptTooLong(current: Int)
    case stepsOutOfRange(value: Int)
    case guidanceOutOfRange(value: Double)
}

extension RequestValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptyPrompt: return "prompt boş olamaz"
        case .promptTooLong(let n): return "prompt en fazla 500 karakter olabilir (şu an \(n))"
        case .negativePromptTooLong(let n): return "negative_prompt en fazla 500 karakter olabilir (şu an \(n))"
        case .stepsOutOfRange(let v): return "steps 2...50 aralığında olmalı (verilen: \(v))"
        case .guidanceOutOfRange(let v): return "guidance 1.0...15.0 aralığında olmalı (verilen: \(v))"
        }
    }
}

extension GenerateRequestDTO {
    func validated() throws -> (request: GenerationRequest, translate: Bool) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw RequestValidationError.emptyPrompt }
        guard trimmedPrompt.count <= 500 else {
            throw RequestValidationError.promptTooLong(current: trimmedPrompt.count)
        }
        let negative = negativePrompt ?? ""
        guard negative.count <= 500 else {
            throw RequestValidationError.negativePromptTooLong(current: negative.count)
        }
        let stepCount = steps ?? GenerationRequest.defaultSteps
        // steps=1, PNDMScheduler'da process'i düşüren crashe yol açar (Scheduler.swift:199)
        // — Swift'te fatal error yakalanamadığı için bu değer kapıda reddedilir.
        guard (2...50).contains(stepCount) else {
            throw RequestValidationError.stepsOutOfRange(value: stepCount)
        }
        let scale = guidance ?? GenerationRequest.defaultGuidance
        guard (1.0...15.0).contains(scale) else {
            throw RequestValidationError.guidanceOutOfRange(value: scale)
        }
        let request = GenerationRequest(
            prompt: trimmedPrompt,
            negativePrompt: negative,
            steps: stepCount,
            guidance: scale,
            seed: seed ?? UInt64.random(in: 0..<UInt64.max)
        )
        return (request, translate ?? true)
    }
}

enum ApiErrorCode: String, Sendable {
    case invalidRequest = "invalid_request"
    case queueFull = "queue_full"
    case generationFailed = "generation_failed"
    case modelNotReady = "model_not_ready"
}

struct ApiErrorEnvelope: Codable, Sendable {
    struct Inner: Codable, Sendable {
        let code: String
        let message: String
    }
    let error: Inner
}
