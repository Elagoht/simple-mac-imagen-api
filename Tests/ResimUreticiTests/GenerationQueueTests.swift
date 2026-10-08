import Testing
@testable import resimuretici

@Suite struct GenerationQueueTests {
    /// Sahte üretici: başlama sırasını ve eşzamanlılık tepe noktasını kaydeder.
    actor MockGenerator: ImageGenerating {
        let delayNanos: UInt64
        let shouldFail: Bool
        private(set) var startOrder: [UInt64] = []
        private var inFlight = 0
        private(set) var maxConcurrent = 0

        init(delayNanos: UInt64 = 100_000_000, shouldFail: Bool = false) {
            self.delayNanos = delayNanos
            self.shouldFail = shouldFail
        }

        func generate(_ request: GenerationRequest) async throws -> GeneratedImage {
            startOrder.append(request.seed)
            inFlight += 1
            maxConcurrent = max(maxConcurrent, inFlight)
            try? await Task.sleep(nanoseconds: delayNanos)
            inFlight -= 1
            if shouldFail { throw GeneratorError.noImageProduced }
            return GeneratedImage(cgImage: TestImages.solid(), seedUsed: request.seed)
        }
    }

    private func request(seed: UInt64) -> GenerationRequest {
        GenerationRequest(prompt: "p\(seed)", negativePrompt: "", steps: 1, guidance: 7.5, seed: seed)
    }

    @Test func fifoOrderAndSingleConcurrency() async throws {
        let generator = MockGenerator()
        let queue = GenerationQueue(generator: generator)

        // async let bildirim sırası yürütme sırasını garanti etmediği için FIFO'yu
        // deterministik kuruyoruz: her iş kuyruğa yerleşmeden sonrakini vermiyoruz.
        async let first = queue.enqueue(request(seed: 1))
        while await generator.startOrder.isEmpty {
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        async let second = queue.enqueue(request(seed: 2))
        while (await queue.status).waiting < 1 {
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        async let third = queue.enqueue(request(seed: 3))

        let outcome1 = try await first
        let outcome2 = try await second
        let outcome3 = try await third

        for outcome in [outcome1, outcome2, outcome3] {
            #expect(Array(outcome.pngData.prefix(4)) == [0x89, 0x50, 0x4E, 0x47]) // PNG imzası
            #expect(outcome.generationMs > 0)
        }
        let order = await generator.startOrder
        #expect(order == [1, 2, 3])
        let maxConcurrent = await generator.maxConcurrent
        #expect(maxConcurrent == 1)
    }

    @Test func queueFullWhenOverLimit() async throws {
        let generator = MockGenerator(delayNanos: 300_000_000)
        let queue = GenerationQueue(generator: generator, maxWaiting: 2)

        func run(_ seed: UInt64) async -> Result<GenerationOutcome, Error> {
            do { return .success(try await queue.enqueue(request(seed: seed))) }
            catch { return .failure(error) }
        }

        async let r1 = run(1)
        async let r2 = run(2)
        async let r3 = run(3)
        async let r4 = run(4)
        let results = await [r1, r2, r3, r4]

        let failures = results.compactMap { result -> Error? in
            if case .failure(let error) = result { return error }
            return nil
        }
        #expect(failures.count == 1)
        #expect(failures.first as? QueueError == .queueFull)
        #expect(results.count - failures.count == 3)
    }

    @Test func errorPropagatesToCaller() async throws {
        let queue = GenerationQueue(generator: MockGenerator(shouldFail: true), maxWaiting: 8)
        await #expect(throws: GeneratorError.noImageProduced) {
            try await queue.enqueue(request(seed: 9))
        }
    }

    @Test func statusReflectsRunningAndWaiting() async throws {
        let queue = GenerationQueue(generator: MockGenerator(delayNanos: 400_000_000), maxWaiting: 8)
        async let job1 = queue.enqueue(request(seed: 1))
        async let job2 = queue.enqueue(request(seed: 2))
        try await Task.sleep(nanoseconds: 50_000_000)
        let mid = await queue.status
        #expect(mid.busy == true)
        #expect(mid.waiting == 1)
        _ = try await job1
        _ = try await job2
        let end = await queue.status
        #expect(end.busy == false)
        #expect(end.waiting == 0)
    }
}
