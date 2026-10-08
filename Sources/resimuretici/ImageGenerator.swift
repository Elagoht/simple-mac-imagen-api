import Foundation
import CoreML
import CoreGraphics
import StableDiffusion

/// Core ML (ml-stable-diffusion) tabanlı üretici.
/// `generate` yalnız GenerationQueue içinden çağrılır (tek eşzamanlı); bu yüzden
/// StableDiffusionPipeline'ın Sendable olmaması @unchecked ile kabul edilir.
final class CoreMLImageGenerator: ImageGenerating, @unchecked Sendable {
    enum ValidationError: LocalizedError {
        case missingResources(missing: [String])

        var errorDescription: String? {
            switch self {
            case .missingResources(let missing):
                return "model klasöründe eksik kaynaklar: \(missing.joined(separator: ", "))"
            }
        }
    }

    static let requiredResources = [
        "TextEncoder.mlmodelc",
        "VAEDecoder.mlmodelc",
        "vocab.json",
        "merges.txt",
    ]

    private let pipeline: StableDiffusionPipeline

    /// Gerekli kaynakların varlığını hızlıca kontrol eder (ağır yükleme loadResources'ta).
    static func validateResources(at directory: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            throw ValidationError.missingResources(missing: ["<klasörün kendisi>: \(directory.path)"])
        }
        let missing = requiredResources.filter {
            !fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        guard missing.isEmpty else { throw ValidationError.missingResources(missing: missing) }
    }

    init(resourcesAt directory: URL, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        try Self.validateResources(at: directory)
        var configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        self.pipeline = try StableDiffusionPipeline(
            resourcesAt: directory,
            controlNet: [],
            configuration: configuration,
            disableSafety: false,
            reduceMemory: false
        )
    }

    func loadResources() throws {
        try pipeline.loadResources()
    }

    func generate(_ request: GenerationRequest) async throws -> GeneratedImage {
        var config = PipelineConfiguration(prompt: request.prompt)
        config.negativePrompt = request.negativePrompt
        config.stepCount = request.steps
        config.guidanceScale = Float(request.guidance)
        config.seed = UInt32(truncatingIfNeeded: request.seed) // 1.1.1'de seed UInt32
        config.disableSafety = false

        // Bloklayan üretimi işbirlikçi iş parçacığı havuzundan dışarı taşı.
        let images = try await Task.detached {
            try self.pipeline.generateImages(configuration: config) { _ in true }
        }.value

        guard let cgImage = images.compactMap({ $0 }).first else {
            throw GeneratorError.noImageProduced
        }
        return GeneratedImage(cgImage: cgImage, seedUsed: request.seed)
    }
}
