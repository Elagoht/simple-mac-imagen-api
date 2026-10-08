import CoreGraphics
@testable import resimuretici

enum TestImages {
    static func solid(size: Int = 4) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }
}

/// Karakter sayısını token gibi sayan sahte sayaç.
struct CharCounter: TokenCounting {
    func count(_ text: String) -> Int { text.count }
}

struct FixedCondenser: PromptCondensing {
    let result: String
    func condense(_ text: String, isNegative: Bool) async -> String { result }
}

/// Son aldığı isteği kaydeden sahte üretici.
actor RecordingGenerator: ImageGenerating {
    private(set) var lastRequest: GenerationRequest?
    func generate(_ request: GenerationRequest) async throws -> GeneratedImage {
        lastRequest = request
        return GeneratedImage(cgImage: TestImages.solid(), seedUsed: request.seed)
    }
}
