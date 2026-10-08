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

    /// SD 1.x/2.x için gerekli kaynaklar; XL'de TextEncoder2 ve (chunk'lı) Unet farkları
    /// validateResources içinde tip-duyarlı ele alınır.
    static let requiredResources = [
        "TextEncoder.mlmodelc",
        "VAEDecoder.mlmodelc",
        "vocab.json",
        "merges.txt",
    ]

    private let pipeline: any StableDiffusionPipelineProtocol

    enum PipelineKind: Equatable, Sendable {
        case sd
        case xl
    }

    /// TextEncoder2 varlığı SDXL kaynaklarına işaret eder.
    static func isXLResources(at directory: URL) -> Bool {
        preferredPipelineKind(at: directory) == .xl
    }

    /// Model tipine göre hangi pipeline'ın kullanılacağını belirler.
    static func preferredPipelineKind(at directory: URL) -> PipelineKind {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("TextEncoder2.mlmodelc").path)
            ? .xl : .sd
    }

    /// Model tipine uygun pipeline'ı kurar (SD 1.x/2.x veya SDXL).
    static func makePipeline(
        resourcesAt directory: URL,
        configuration: MLModelConfiguration
    ) throws -> any StableDiffusionPipelineProtocol {
        if isXLResources(at: directory) {
            return try StableDiffusionXLPipeline(
                resourcesAt: directory,
                configuration: configuration,
                reduceMemory: false
            )
        }
        return try StableDiffusionPipeline(
            resourcesAt: directory,
            controlNet: [],
            configuration: configuration,
            disableSafety: false,
            reduceMemory: false
        )
    }

    /// Gerekli kaynakların varlığını hızlıca kontrol eder (ağır yükleme loadResources'ta).
    /// .mlmodelc kaynakları dizin olmalı — aynı adlı düz dosya eksik sayılır.
    static func validateResources(at directory: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            throw ValidationError.missingResources(missing: ["<klasörün kendisi>: \(directory.path)"])
        }

        var required = requiredResources
        if fileExists(fileManager, directory, "TextEncoder2.mlmodelc") {
            required.append("TextEncoder2.mlmodelc")
            if !fileExists(fileManager, directory, "UnetChunk1.mlmodelc")
                || !fileExists(fileManager, directory, "UnetChunk2.mlmodelc") {
                required.append("UnetChunk1.mlmodelc")
                required.append("UnetChunk2.mlmodelc")
            }
        } else {
            required.append("Unet.mlmodelc")
        }

        let missing = required.filter { name -> Bool in
            let path = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: path.path, isDirectory: &isDirectory)
            if name.hasSuffix(".mlmodelc") {
                return !(exists && isDirectory.boolValue)
            }
            return !exists
        }
        guard missing.isEmpty else { throw ValidationError.missingResources(missing: missing) }
    }

    private static func fileExists(_ fm: FileManager, _ directory: URL, _ name: String) -> Bool {
        fm.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    init(resourcesAt directory: URL, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        try Self.validateResources(at: directory)
        var configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        self.pipeline = try Self.makePipeline(resourcesAt: directory, configuration: configuration)
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
