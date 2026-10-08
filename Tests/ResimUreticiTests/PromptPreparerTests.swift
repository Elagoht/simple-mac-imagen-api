import Testing
import Foundation
@testable import resimuretici

@Suite struct PromptPreparerTests {
    /// Karakter sayısını token sayısı sanan sahte sayaç (test determinizmi için).
    private struct CharCounter: TokenCounting {
        func count(_ text: String) -> Int { text.count }
    }

    private struct FixedTranslator: PromptTranslating {
        let result: String
        func translate(_ prompt: String) async -> String { result }
    }

    private struct FixedCondenser: PromptCondensing {
        let result: String
        func condense(_ text: String, isNegative: Bool) async -> String { result }
    }

    @Test func shortPromptPassesThroughUntouched() async {
        let preparer = PromptPreparer(
            translator: FixedTranslator(result: "a red apple"),
            counter: CharCounter(),
            condenser: FixedCondenser(result: "ASLA_KULLANILMAMALI")
        )
        let out = await preparer.prepare(prompt: "a red apple", negativePrompt: "")
        #expect(out.prompt == "a red apple")
        #expect(out.negativePrompt == "")
    }

    @Test func longPromptIsCondensed() async {
        let preparer = PromptPreparer(
            translator: PassthroughTranslator(),
            counter: CharCounter(),
            condenser: FixedCondenser(result: "a detailed still life")
        )
        let long = String(repeating: "kelime ", count: 100) // 700 "token"
        let out = await preparer.prepare(prompt: long, negativePrompt: "")
        #expect(out.prompt == "a detailed still life")
    }

    @Test func longNegativePromptIsCondensed() async {
        let preparer = PromptPreparer(
            translator: PassthroughTranslator(),
            counter: CharCounter(),
            condenser: FixedCondenser(result: "blurry")
        )
        let long = String(repeating: "kelime ", count: 100)
        let out = await preparer.prepare(prompt: "short", negativePrompt: long)
        #expect(out.prompt == "short")
        #expect(out.negativePrompt == "blurry")
    }

    @Test func emptyCondensationKeepsOriginal() async {
        let preparer = PromptPreparer(
            translator: PassthroughTranslator(),
            counter: CharCounter(),
            condenser: FixedCondenser(result: "   ")
        )
        let long = String(repeating: "kelime ", count: 100)
        let out = await preparer.prepare(prompt: long, negativePrompt: "")
        #expect(out.prompt == long)
    }

    @Test func translationRunsBeforeCounting() async {
        // Kısa Türkçe girdi, çeviri sonrası uzarsa yoğunlaştırılmalı (sıra kanıtı).
        let preparer = PromptPreparer(
            translator: FixedTranslator(result: String(repeating: "word ", count: 100)),
            counter: CharCounter(),
            condenser: FixedCondenser(result: "condensed")
        )
        let out = await preparer.prepare(prompt: "kısa", negativePrompt: "")
        #expect(out.prompt == "condensed")
    }

    @Test func noCounterMeansNoCondensation() async {
        let preparer = PromptPreparer(
            translator: PassthroughTranslator(),
            counter: nil,
            condenser: FixedCondenser(result: "ASLA")
        )
        let long = String(repeating: "kelime ", count: 100)
        let out = await preparer.prepare(prompt: long, negativePrompt: "")
        #expect(out.prompt == long)
    }
}
