import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum GeneratorError: Error, Equatable {
    case noImageProduced
    case pngEncodeFailed
}

struct GeneratedImage: Sendable {
    let cgImage: CGImage
    let seedUsed: UInt64
}

protocol ImageGenerating: Sendable {
    func generate(_ request: GenerationRequest) async throws -> GeneratedImage
}

enum PNGCodec {
    static func encode(_ image: CGImage) throws -> Data {
        let mutable = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutable, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw GeneratorError.pngEncodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw GeneratorError.pngEncodeFailed }
        return mutable as Data
    }
}

struct GenerationOutcome: Sendable {
    let pngData: Data
    let generationMs: Int
}

enum QueueError: Error, Equatable {
    case queueFull
}

/// FIFO üretim kuyruğu: aynı anda tek üretim, en fazla `maxWaiting` bekleyen.
actor GenerationQueue {
    private let generator: any ImageGenerating
    private let maxWaiting: Int

    private var running = false
    private var pending: [(request: GenerationRequest, continuation: CheckedContinuation<GenerationOutcome, Error>)] = []

    init(generator: any ImageGenerating, maxWaiting: Int = 8) {
        self.generator = generator
        self.maxWaiting = maxWaiting
    }

    /// (busy, bekleyen sayısı)
    var status: (busy: Bool, waiting: Int) {
        (running, pending.count)
    }

    func enqueue(_ request: GenerationRequest) async throws -> GenerationOutcome {
        guard pending.count < maxWaiting else { throw QueueError.queueFull }
        return try await withCheckedThrowingContinuation { continuation in
            pending.append((request, continuation))
            startNextIfNeeded()
        }
    }

    private func startNextIfNeeded() {
        guard !running, let job = pending.first else { return }
        pending.removeFirst()
        running = true
        let generator = self.generator
        Task {
            let startedAt = DispatchTime.now()
            let result: Result<GenerationOutcome, Error>
            do {
                let image = try await generator.generate(job.request)
                let png = try PNGCodec.encode(image.cgImage)
                let ms = Int(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000
                result = .success(GenerationOutcome(pngData: png, generationMs: ms))
            } catch {
                result = .failure(error)
            }
            await self.jobFinished(job.continuation, result)
        }
    }

    private func jobFinished(
        _ continuation: CheckedContinuation<GenerationOutcome, Error>,
        _ result: Result<GenerationOutcome, Error>
    ) {
        continuation.resume(with: result)
        running = false
        startNextIfNeeded()
    }
}
