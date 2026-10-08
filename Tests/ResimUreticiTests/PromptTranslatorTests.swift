import Testing
@testable import resimuretici

@Suite struct PromptTranslatorTests {
    private struct FixedTranslator: PromptTranslating {
        let result: String
        func translate(_ prompt: String) async -> String { result }
    }

    @Test func asciiPromptSkipsTranslator() async {
        let smart = SmartPromptTranslator(translator: FixedTranslator(result: "ASLA_KULLANILMAMALI"))
        let out = await smart.translate("a red apple on a wooden table")
        #expect(out == "a red apple on a wooden table")
    }

    @Test func nonAsciiPromptIsTranslated() async {
        let smart = SmartPromptTranslator(translator: FixedTranslator(result: "a red apple"))
        let out = await smart.translate("kırmızı elma")
        #expect(out == "a red apple")
    }

    @Test func passthroughReturnsOriginal() async {
        let out = await PassthroughTranslator().translate("kırmızı elma")
        #expect(out == "kırmızı elma")
    }

    @Test func whitespaceOnlyTranslationFallsBackToOriginal() async {
        let smart = SmartPromptTranslator(translator: FixedTranslator(result: "   "))
        let out = await smart.translate("kırmızı elma")
        #expect(out == "kırmızı elma")
    }

    @Test func fallbackWarnsWhenFoundationModelsUnavailable() {
        // Spec §7: FoundationModels yoksa passthrough + bir kez uyarı.
        final class Recorder {
            var warned = false
        }
        let recorder = Recorder()
        _ = SmartPromptTranslator(
            translator: nil,
            foundationModelsFactory: { nil },
            onFoundationModelsUnavailable: { recorder.warned = true }
        )
        #expect(recorder.warned == true)
    }
}
