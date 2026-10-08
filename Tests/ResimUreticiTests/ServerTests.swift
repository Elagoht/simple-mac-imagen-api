import Testing
import Foundation
import Vapor
@testable import resimuretici

@Suite struct ServerTests {
    private actor StubGenerator: ImageGenerating {
        let delayNanos: UInt64
        init(delayNanos: UInt64 = 0) { self.delayNanos = delayNanos }
        func generate(_ request: GenerationRequest) async throws -> GeneratedImage {
            if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
            return GeneratedImage(cgImage: TestImages.solid(), seedUsed: request.seed)
        }
    }

    private struct FailingGenerator: ImageGenerating {
        func generate(_ request: GenerationRequest) async throws -> GeneratedImage {
            throw GeneratorError.noImageProduced
        }
    }

    /// Paralel testler çakışmasın diye her sunucu benzersiz port alır.
    private final class PortCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 8451
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private static let ports = PortCounter()

    private struct Setup {
        let app: Application
        let runTask: Task<Void, Never>
        let port: Int
    }

    private func startServer(
        generator: any ImageGenerating = StubGenerator(),
        translator: any PromptTranslating = PassthroughTranslator(),
        ready: Bool = true,
        maxWaiting: Int = 8
    ) async throws -> Setup {
        let app = try await Application.make(Environment(name: "testing", arguments: ["vapor"]))
        let readiness = ReadinessFlag()
        if ready { readiness.set() }
        let state = AppState(
            queue: GenerationQueue(generator: generator, maxWaiting: maxWaiting),
            translator: translator,
            modelName: "test-model",
            readiness: readiness
        )
        try routes(app, state: state)
        let port = Self.ports.next()
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = port
        let runTask = Task { _ = try? await app.execute() }

        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
        for _ in 0..<100 {
            if (try? await URLSession.shared.data(from: healthURL)) != nil {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return Setup(app: app, runTask: runTask, port: port)
    }

    private func stop(_ setup: Setup) async {
        setup.runTask.cancel()
        try? await setup.app.asyncShutdown()
    }

    private func post(_ port: Int, _ json: String) async -> (Data, Int) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/generate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(json.utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return (Data(), 0)
        }
        return (data, http.statusCode)
    }

    private func get(_ port: Int, _ path: String) async -> (Data, Int) {
        guard let (data, response) = try? await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)\(path)")!
        ), let http = response as? HTTPURLResponse else {
            return (Data(), 0)
        }
        return (data, http.statusCode)
    }

    @Test func generateReturnsPNGWithHeaders() async throws {
        let setup = try await startServer()

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(setup.port)/generate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"prompt":"kırmızı elma","seed":42,"translate":false}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("image/png") == true)
        #expect(http.value(forHTTPHeaderField: "X-Seed") == "42")
        let promptUsed = try #require(
            http.value(forHTTPHeaderField: "X-Prompt-Used")?.removingPercentEncoding
        )
        #expect(promptUsed == "kırmızı elma")
        #expect(http.value(forHTTPHeaderField: "X-Generation-Ms") != nil)
        #expect(Array(data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47]) // PNG imzası
        await stop(setup)
    }

    @Test func invalidPromptReturns400Envelope() async throws {
        let setup = try await startServer()

        let (data, status) = await post(setup.port, #"{"prompt":""}"#)
        #expect(status == 400)
        let envelope = try JSONDecoder().decode(ApiErrorEnvelope.self, from: data)
        #expect(envelope.error.code == "invalid_request")
        await stop(setup)
    }

    @Test func malformedBodyReturns400() async throws {
        let setup = try await startServer()

        let (data, status) = await post(setup.port, #"{"gecersiz": true}"#)
        #expect(status == 400)
        let envelope = try JSONDecoder().decode(ApiErrorEnvelope.self, from: data)
        #expect(envelope.error.code == "invalid_request")
        await stop(setup)
    }

    @Test func notReadyReturns503() async throws {
        let setup = try await startServer(ready: false)

        let (data, status) = await post(setup.port, #"{"prompt":"x"}"#)
        #expect(status == 503)
        let envelope = try JSONDecoder().decode(ApiErrorEnvelope.self, from: data)
        #expect(envelope.error.code == "model_not_ready")
        await stop(setup)
    }

    @Test func generationFailureReturns500() async throws {
        let setup = try await startServer(generator: FailingGenerator())

        let (data, status) = await post(setup.port, #"{"prompt":"x","translate":false}"#)
        #expect(status == 500)
        let envelope = try JSONDecoder().decode(ApiErrorEnvelope.self, from: data)
        #expect(envelope.error.code == "generation_failed")
        await stop(setup)
    }

    @Test func healthOK() async throws {
        let setup = try await startServer()

        let (data, status) = await get(setup.port, "/health")
        #expect(status == 200)
        let health = try JSONDecoder().decode(HealthResponse.self, from: data)
        #expect(health.status == "ok")
        #expect(health.model == "test-model")
        #expect(health.busy == false)
        #expect(health.queue == 0)
        await stop(setup)
    }

    @Test func healthLoadingWhenNotReady() async throws {
        let setup = try await startServer(ready: false)

        let (data, status) = await get(setup.port, "/health")
        #expect(status == 200)
        let health = try JSONDecoder().decode(HealthResponse.self, from: data)
        #expect(health.status == "loading")
        await stop(setup)
    }

    @Test func queueFullReturns429UnderBurst() async throws {
        let setup = try await startServer(
            generator: StubGenerator(delayNanos: 300_000_000),
            maxWaiting: 2
        )

        var statuses: [Int] = []
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let (_, status) = await self.post(setup.port, #"{"prompt":"x","translate":false}"#)
                    return status
                }
            }
            for await status in group { statuses.append(status) }
        }
        #expect(statuses.filter { $0 == 200 }.count == 3)
        #expect(statuses.filter { $0 == 429 }.count == 1)
        await stop(setup)
    }
}
