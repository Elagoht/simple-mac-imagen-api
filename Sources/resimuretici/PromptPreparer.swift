import Foundation
import StableDiffusion
import FoundationModels

protocol TokenCounting: Sendable {
    func count(_ text: String) -> Int
}

protocol PromptCondensing: Sendable {
    /// Asla throw etmez; başarısızlıkta orijinal metni döndürür.
    func condense(_ text: String, isNegative: Bool) async -> String
}

/// Üretim öncesi prompt hazırlığı: çevir → token say → gerekiyorsa yoğunlaştır.
struct PromptPreparer: Sendable {
    /// SD 1.5 kodlayıcısı 77 token alır; start/end tokenları ve güvenlik payı çıkarınca 70.
    static let maxTokens = 70

    let translator: any PromptTranslating
    let counter: (any TokenCounting)?
    let condenser: (any PromptCondensing)?

    func prepare(
        prompt: String,
        negativePrompt: String,
        translate: Bool = true
    ) async -> (prompt: String, negativePrompt: String) {
        // translate bayrağı yalnız çeviriyi kontrol eder; sığdırma (yoğunlaştırma) her zaman
        // uygulanır — yoksa 77 token üstü metin sessizce kaybolur.
        let translated = translate ? await translator.translate(prompt) : prompt
        let fittedPrompt = await fit(translated, isNegative: false)
        let fittedNegative = await fit(negativePrompt, isNegative: true)
        return (fittedPrompt, fittedNegative)
    }

    private func fit(_ text: String, isNegative: Bool) async -> String {
        guard let counter else { return text }
        guard counter.count(text) > Self.maxTokens else { return text }
        guard let condenser else { return text }
        let condensed = await condenser.condense(text, isNegative: isNegative)
        let trimmed = condensed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }
}

/// Kütüphanenin kendi BPE tokenizer'ıyla birebir aynı token sayımı.
/// Tokenizer init sonrası yalnız okunur (immutable) — @unchecked güvenli.
final class PromptTokenCounter: TokenCounting, @unchecked Sendable {
    private let tokenizer: BPETokenizer

    init?(modelDirectory: URL) {
        guard let tokenizer = try? BPETokenizer(
            mergesAt: modelDirectory.appending(path: "merges.txt"),
            vocabularyAt: modelDirectory.appending(path: "vocab.json")
        ) else { return nil }
        self.tokenizer = tokenizer
    }

    func count(_ text: String) -> Int {
        tokenizer.tokenize(input: text).tokenIDs.count
    }
}

/// Uzun metinleri 77 token altına sıkıştıran cihaz-içi LLM yoğunlaştırıcısı.
final class FoundationModelsCondenser: PromptCondensing {
    private static func instructions(isNegative: Bool) -> String {
        isNegative
            ? """
            Condense the user's long list of things to avoid in an image into a concise \
            English comma-separated list of the most important concepts (under 30 words). \
            Reply with ONLY the list.
            """
            : """
            Condense the user's long description into a vivid, concise English \
            image-generation prompt of at most 60 words, preserving the key subjects, \
            style and mood. Reply with ONLY the prompt.
            """
    }

    init() {}

    func condense(_ text: String, isNegative: Bool) async -> String {
        do {
            let session = LanguageModelSession(instructions: Self.instructions(isNegative: isNegative))
            return try await session.respond(to: text).content
        } catch {
            // Yoğunlaştırma asla üretimi bloklamaz: uyarı yaz, orijinali döndür
            // (kütüphane 77 token üstünü sessizce keser — X-Prompt-Used şeffaflık sağlar).
            FileHandle.standardError.write(
                Data("⚠️  yoğunlaştırma başarısız, orijinal prompt kullanılıyor: \(error)\n".utf8)
            )
            return text
        }
    }
}
