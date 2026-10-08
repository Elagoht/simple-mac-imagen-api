import Vapor
import Foundation

final class ReadinessFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false

    func set() {
        lock.lock()
        ready = true
        lock.unlock()
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }
}

struct AppState: Sendable {
    let queue: GenerationQueue
    let preparer: PromptPreparer
    let modelName: String
    let readiness: ReadinessFlag
}

struct HealthResponse: Content {
    let status: String
    let model: String?
    let busy: Bool
    let queue: Int
}

enum ApiResponses {
    static func error(_ code: ApiErrorCode, _ message: String, status: HTTPResponseStatus) -> Response {
        let envelope = ApiErrorEnvelope(error: .init(code: code.rawValue, message: message))
        let data = (try? JSONEncoder().encode(envelope)) ?? Data("{}".utf8)
        let response = Response(status: status, body: .init(data: data))
        response.headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        return response
    }
}

func routes(_ app: Application, state: AppState) throws {
    app.get("health") { _ in
        let (busy, waiting) = await state.queue.status
        return HealthResponse(
            status: state.readiness.isReady ? "ok" : "loading",
            model: state.modelName,
            busy: busy,
            queue: waiting
        )
    }

    app.post("generate") { req in
        guard state.readiness.isReady else {
            return ApiResponses.error(
                .modelNotReady,
                "model hâlâ yükleniyor, kısa süre sonra tekrar dene",
                status: .serviceUnavailable
            )
        }
        let dto: GenerateRequestDTO
        do {
            dto = try req.content.decode(GenerateRequestDTO.self)
        } catch {
            return ApiResponses.error(
                .invalidRequest,
                "istek gövdesi şemaya uymuyor: \(error)",
                status: .badRequest
            )
        }
        let (generationRequest, translate): (GenerationRequest, Bool)
        do {
            (generationRequest, translate) = try dto.validated()
        } catch let error as RequestValidationError {
            return ApiResponses.error(
                .invalidRequest,
                error.errorDescription ?? "geçersiz istek",
                status: .badRequest
            )
        } catch {
            return ApiResponses.error(.invalidRequest, "geçersiz istek", status: .badRequest)
        }
        // Çeviri + token sığdırma (uzun prompt yoğunlaştırma) tek noktada.
        let prepared = await state.preparer.prepare(
            prompt: generationRequest.prompt,
            negativePrompt: generationRequest.negativePrompt,
            translate: translate
        )
        let effective = generationRequest
            .withPrompt(prepared.prompt)
            .withNegativePrompt(prepared.negativePrompt)
        let outcome: GenerationOutcome
        do {
            outcome = try await state.queue.enqueue(effective)
        } catch QueueError.queueFull {
            return ApiResponses.error(
                .queueFull,
                "kuyruk dolu (8 bekleyen sınırı), birazdan tekrar dene",
                status: .tooManyRequests
            )
        } catch {
            return ApiResponses.error(
                .generationFailed,
                "üretim başarısız: \(error)",
                status: .internalServerError
            )
        }
        let response = Response(status: .ok, body: .init(data: outcome.pngData))
        response.headers.replaceOrAdd(name: .contentType, value: "image/png")
        // Header değerleri latin-1'dir; Türkçe prompt mojibake olmasın diye percent-encode.
        let encodedPrompt = effective.prompt.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        response.headers.replaceOrAdd(name: "X-Prompt-Used", value: encodedPrompt)
        response.headers.replaceOrAdd(name: "X-Seed", value: String(effective.seed))
        response.headers.replaceOrAdd(name: "X-Generation-Ms", value: String(outcome.generationMs))
        return response
    }
}
