import Testing
import Foundation
@testable import resimuretici

@Suite struct SmokeGenerationTests {
    @Test func oneStepGenerationProducesValidPNG() async throws {
        let modelDir = ProcessInfo.processInfo.environment["RESIM_MODEL_DIR"]
            ?? "Models/coreml-sd-v1-5-palettized"
        guard FileManager.default.fileExists(atPath: modelDir) else {
            // Model yoksa FAIL değil SKIP (spec §10, README sözü).
            try Test.cancel("model indirilmemiş: \(modelDir) (Scripts/fetch-model.sh)")
        }
        let generator = try CoreMLImageGenerator(resourcesAt: URL(fileURLWithPath: modelDir))
        try generator.loadResources()
        let request = GenerationRequest(
            prompt: "a red apple on a wooden table",
            negativePrompt: "",
            steps: 4, // steps=1 PNDMScheduler'da crash — en düşük güvenli adım sayısının üstü
            guidance: 7.5,
            seed: 7
        )
        let image = try await generator.generate(request)
        let png = try PNGCodec.encode(image.cgImage)
        #expect(png.count > 1_000)
        #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        #expect(image.cgImage.width == 512)
    }
}
