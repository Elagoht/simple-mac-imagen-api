import Foundation
import FoundationModels

protocol PromptTranslating: Sendable {
    /// Asla throw etmez; başarısızlıkta orijinal prompt'u döndürür.
    func translate(_ prompt: String) async -> String
}

struct PassthroughTranslator: PromptTranslating {
    func translate(_ prompt: String) async -> String { prompt }
}

/// ASCII olmayan prompt'ları iç çevirmene (LLM) gönderir; saf ASCII'ye dokunmaz.
final class SmartPromptTranslator: PromptTranslating {
    private let inner: any PromptTranslating

    init(
        translator: (any PromptTranslating)? = nil,
        foundationModelsFactory: @escaping () -> FoundationModelsTranslator? = { FoundationModelsTranslator.make() },
        onFoundationModelsUnavailable: () -> Void = { Log.warn("FoundationModels kullanılamıyor, çeviri atlanıyor") }
    ) {
        if let translator {
            inner = translator
        } else if let fm = foundationModelsFactory() {
            inner = fm
        } else {
            onFoundationModelsUnavailable()
            inner = PassthroughTranslator()
        }
    }

    func translate(_ prompt: String) async -> String {
        guard !prompt.canBeConverted(to: .ascii) else { return prompt }
        let translated = await inner.translate(prompt)
        let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? prompt : trimmed
    }
}

/// Apple'ın cihaz-içi modeliyle (FoundationModels) çeviri.
final class FoundationModelsTranslator: PromptTranslating {
    private static let instructions = """
    Translate the user's text into concise, natural English suitable as an \
    image-generation prompt. Reply with ONLY the translated text.
    """

    static func make() -> FoundationModelsTranslator? {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        return FoundationModelsTranslator()
    }

    private init() {}

    func translate(_ prompt: String) async -> String {
        do {
            // Oturum çağrı başına: LanguageModelSession durumlu bir sohbettir;
            // paylaşılan oturumda transcript birikir ve eşzamanlı respond'lar
            // birbirine karışır (final review bulgusu).
            let session = LanguageModelSession(instructions: Self.instructions)
            let response = try await session.respond(to: prompt)
            return response.content
        } catch {
            // Çeviri asla üretimi bloklamaz: uyarı yaz, orijinali döndür.
            FileHandle.standardError.write(
                Data("⚠️  çeviri başarısız, orijinal prompt kullanılıyor: \(error)\n".utf8)
            )
            return prompt
        }
    }
}
