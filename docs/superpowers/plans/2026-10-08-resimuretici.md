# ResimUretici Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Go backend'inin çağıracağı, metin prompt'tan PNG üreten, tamamen lokal (Core ML, M4 GPU) HTTP API sunucusu.

**Architecture:** Tek Swift executable: Vapor 4 HTTP sunucusu → FIFO üretim kuyruğu (actor, tek eşzamanlı) → `ml-stable-diffusion` (`StableDiffusionPipeline`, Core ML). Prompt'lar FoundationModels (cihaz-içi LLM) ile Türkçe→İngilizce çevrilir (kapatılabilir, asla hata fırlatmaz).

**Tech Stack:** Swift 6.4 / SPM, Vapor 4, apple/ml-stable-diffusion, FoundationModels, XCTest + XCTVapor

**Spec:** `docs/superpowers/specs/2026-10-08-resimuretici-design.md` (bu plan spec'ten argümanlar; ikisi birlikte okunmalı)

## Global Constraints

- Hedef makine: macOS 27.0.1, Apple M4, 16 GB. `platforms: [.macOS(.v26)]`, `swift-tools-version:6.2`.
- Varsayılan bağlanma adresi `127.0.0.1:8787`; model klasörü `Models/coreml-sd-v1-5-palettized`.
- CLI/env: `--host`/`RESIM_HOST`, `--port`/`RESIM_PORT`, `--model`/`RESIM_MODEL_DIR` (CLI, env'i ezer).
- Doğrulama: prompt trim sonrası 1..500 karakter; `negative_prompt` ≤ 500; `steps` 1..50 (varsayılan 25); `guidance` 1.0..15.0 (varsayılan 7.5); `seed` UInt64/null; `translate` varsayılan `true`.
- Kuyruk: aynı anda 1 üretim, en fazla 8 bekleyen; taşarsa `429 queue_full`.
- Hata zarfı: `{"error":{"code":"...","message":"..."}}` — `invalid_request`(400), `queue_full`(429), `generation_failed`(500), `model_not_ready`(503).
- Başarı yanıtı: `200`, `Content-Type: image/png`, başlıklar `X-Prompt-Used`, `X-Seed`, `X-Generation-Ms`.
- Model kaynakları eksikse veya yükleme başarısızsa **exit(1)** (fail fast); 503 yalnız yükleme penceresinde.
- Çalışma anında dış ağ çağrısı yok (tek istisna: `Scripts/fetch-model.sh` ile bir kerelik model indirmesi). Çeviri on-device FoundationModels ile; asla throw etmez; saf ASCII prompt çevrilmez.
- Giriş noktası dosyası `EntryPoint.swift` (SPM'de `@main` ile `main.swift` birlikte olamaz).
- Derleme hatasında Swift 6 strict concurrency direnci olursa: hedefe `swiftSettings: [.swiftLanguageMode(.v5)]` ekle (fallback; önce Swift 6 modunu dene).
- Commit mesajları conventional (feat/test/docs/chore), gövde Türkçe olabilir, sonuna `Co-Authored-By: Claude Code <noreply@anthropic.com>`.

## Review Focus

Spec'in ima ettiği ama birim testlerle kapanmayan beş giriş sınıfı — her biri sahibi görevde testle sabitlendi:

1. **ASCII-only Türkçe prompt** ("kirmizi elma", diakritiksiz) → çeviri denemeden 200 PNG dönmeli. Test: Task 2 `testAsciiPromptSkipsTranslator`; README'ye de not (Task 8).
2. **9+ eşzamanlı istek patlaması** → 1'i çalışır, 8'i bekler, fazlası 429 alır; sunucu ayakta kalır. Test: Task 3 `testQueueFullWhenOverLimit`, Task 5 `testQueueFullReturns429UnderBurst`.
3. **Eksik/bozuk model klasörü** (ör. `vocab.json` yok) → açılışta exit(1) + eksik dosya adı yazılır, yarım servis asla başlamaz. Test: Task 4 `testValidateRejectsMissingResources` + Task 6 elle fail-fast adımı.
4. **Apple Intelligence kapatılmış / çeviri hatası** → yine 200 + orijinal prompt (tek uyarı, asla 500 değil). Test: Task 2 kontrat testleri (`translate` imzası throw etmez; FM impl `do/catch`).
5. **Aynı seed'in tekrar gönderilmesi** → `X-Seed` başlığı client seed'ini birebir yansıtır (tekrarlanabilirlik tutamacı). Test: Task 5 `testGenerateReturnsPNGWithHeaders` (seed 42).

---

### Task 1: Paket iskeleti + ApiModels

**Files:**
- Delete: `probe/` (atıl spike kodu)
- Create: `Package.swift`
- Create: `Sources/resimuretici/EntryPoint.swift` (yer tutucu; Task 6'da değişecek)
- Create: `Sources/resimuretici/ApiModels.swift`
- Test: `Tests/ResimUreticiTests/ApiModelsTests.swift`

**Interfaces (Produces — sonraki görevler buna bağlanır):**
- `struct GenerateRequestDTO: Codable, Sendable` — CodingKeys: `prompt`, `negative_prompt`, `steps`, `guidance`, `seed`, `translate`
- `func validated() throws -> (request: GenerationRequest, translate: Bool)`
- `struct GenerationRequest: Sendable, Equatable` — `prompt: String`, `negativePrompt: String`, `steps: Int`, `guidance: Double`, `seed: UInt64`; `static let defaultSteps = 25`; `static let defaultGuidance = 7.5`; `func withPrompt(_ newPrompt: String) -> GenerationRequest`
- `enum RequestValidationError: Error, Equatable, LocalizedError` — `emptyPrompt`, `promptTooLong(current:)`, `negativePromptTooLong(current:)`, `stepsOutOfRange(value:)`, `guidanceOutOfRange(value:)`
- `enum ApiErrorCode: String, Sendable` — `invalidRequest = "invalid_request"`, `queueFull = "queue_full"`, `generationFailed = "generation_failed"`, `modelNotReady = "model_not_ready"`
- `struct ApiErrorEnvelope: Codable, Sendable` — `let error: Inner`; `Inner { let code: String; let message: String }`

- [ ] **Step 1: Atıl spike kodunu sil**

```bash
cd /Users/furkanbaytekin/Desktop/ResimUretici && rm -rf probe
```

- [ ] **Step 2: Package.swift yaz**

```swift
// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "resimuretici",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", "4.100.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/ml-stable-diffusion.git", "1.0.0"..<"3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "resimuretici",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "StableDiffusion", package: "ml-stable-diffusion"),
            ]
        ),
        .testTarget(
            name: "ResimUreticiTests",
            dependencies: [
                .byName(name: "resimuretici"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "XCTVapor", package: "vapor"),
            ]
        ),
    ]
)
```

Not: `ml-stable-diffusion` için açık aralık bilinçli — çözümleyici en son uyumlu sürümü (2.x varsa o) seçer. Global Constraints'teki Swift 6 fallback'i yalnızca gerçek derleme hatasında uygula.

- [ ] **Step 3: Yer tutucu giriş noktası yaz**

`Sources/resimuretici/EntryPoint.swift`:

```swift
// Yer tutucu giriş noktası — Task 6'da gerçek main ile değişecek.
@main
struct ResimUreticiApp {
    static func main() {
        print("resimuretici: yer tutucu")
    }
}
```

- [ ] **Step 4: Bağımlılıkları çözümle**

```bash
swift package resolve
```
Beklenen: Vapor + ml-stable-diffusion indirilir (birkaç dakika, ağ gerekir). Hata yok.

- [ ] **Step 5: Testi yaz (kırmızı)**

`Tests/ResimUreticiTests/ApiModelsTests.swift`:

```swift
import XCTest
@testable import resimuretici

final class ApiModelsTests: XCTestCase {
    func testSnakeCaseDecoding() throws {
        let json = #"{"prompt":"cat","negative_prompt":"dog","seed":42,"translate":false}"#
        let dto = try JSONDecoder().decode(GenerateRequestDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.prompt, "cat")
        XCTAssertEqual(dto.negativePrompt, "dog")
        XCTAssertEqual(dto.seed, 42)
        XCTAssertEqual(dto.translate, false)
    }

    func testDefaultsApplied() throws {
        let json = #"{"prompt":"a cat"}"#
        let dto = try JSONDecoder().decode(GenerateRequestDTO.self, from: Data(json.utf8))
        let (request, translate) = try dto.validated()
        XCTAssertEqual(request.steps, 25)
        XCTAssertEqual(request.guidance, 7.5)
        XCTAssertEqual(request.negativePrompt, "")
        XCTAssertTrue(translate)
    }

    func testNullSeedBecomesRandomButDoesNotThrow() throws {
        let json = #"{"prompt":"a cat","seed":null}"#
        let dto = try JSONDecoder().decode(GenerateRequestDTO.self, from: Data(json.utf8))
        XCTAssertNoThrow(try dto.validated())
    }

    func testEmptyAndWhitespacePromptThrows() throws {
        for body in [#"{"prompt":""}"#, #"{"prompt":"   \n  "}"#] {
            let dto = try JSONDecoder().decode(GenerateRequestDTO.self, from: Data(body.utf8))
            XCTAssertThrowsError(try dto.validated())
        }
    }

    func testPromptOver500CharsThrows() throws {
        let long = String(repeating: "a", count: 501)
        let body = "{\"prompt\":\"\(long)\"}"
        let dto = try JSONDecoder().decode(GenerateRequestDTO.self, from: Data(body.utf8))
        XCTAssertThrowsError(try dto.validated())
    }

    func testPromptAt500CharsPasses() throws {
        let exact = String(repeating: "a", count: 500)
        let body = "{\"prompt\":\"\(exact)\"}"
        let dto = try JSONDecoder().decode(GenerateRequestDTO.self, from: Data(body.utf8))
        XCTAssertNoThrow(try dto.validated())
    }

    func testStepsAndGuidanceBoundaries() throws {
        func validated(_ json: String) throws -> GenerationRequest {
            try JSONDecoder().decode(GenerateRequestDTO.self, from: Data(json.utf8)).validated().request
        }
        XCTAssertEqual(try validated(#"{"prompt":"x","steps":1}"#).steps, 1)
        XCTAssertEqual(try validated(#"{"prompt":"x","steps":50}"#).steps, 50)
        XCTAssertThrowsError(try validated(#"{"prompt":"x","steps":0}"#))
        XCTAssertThrowsError(try validated(#"{"prompt":"x","steps":51}"#))
        XCTAssertEqual(try validated(#"{"prompt":"x","guidance":1.0}"#).guidance, 1.0)
        XCTAssertEqual(try validated(#"{"prompt":"x","guidance":15.0}"#).guidance, 15.0)
        XCTAssertThrowsError(try validated(#"{"prompt":"x","guidance":0.5}"#))
        XCTAssertThrowsError(try validated(#"{"prompt":"x","guidance":20.0}"#))
    }

    func testErrorEnvelopeRoundTrip() throws {
        let envelope = ApiErrorEnvelope(error: .init(code: ApiErrorCode.invalidRequest.rawValue, message: "mesaj"))
        let data = try JSONEncoder().encode(envelope)
        let back = try JSONDecoder().decode(ApiErrorEnvelope.self, from: data)
        XCTAssertEqual(back.error.code, "invalid_request")
        XCTAssertEqual(back.error.message, "mesaj")
    }
}
```

- [ ] **Step 6: Testin düştüğünü doğrula**

```bash
swift test --filter ApiModelsTests 2>&1 | tail -5
```
Beklenen: BUILD ERROR — `GenerateRequestDTO` tipi yok (ApiModels.swift henüz yazılmadı).

- [ ] **Step 7: Uygulamayı yaz (yeşil)**

`Sources/resimuretici/ApiModels.swift`:

```swift
import Foundation

struct GenerateRequestDTO: Codable, Sendable {
    var prompt: String
    var negativePrompt: String?
    var steps: Int?
    var guidance: Double?
    var seed: UInt64?
    var translate: Bool?

    enum CodingKeys: String, CodingKey {
        case prompt
        case negativePrompt = "negative_prompt"
        case steps, guidance, seed, translate
    }
}

struct GenerationRequest: Sendable, Equatable {
    var prompt: String
    var negativePrompt: String
    var steps: Int
    var guidance: Double
    var seed: UInt64

    static let defaultSteps = 25
    static let defaultGuidance = 7.5

    func withPrompt(_ newPrompt: String) -> GenerationRequest {
        var copy = self
        copy.prompt = newPrompt
        return copy
    }
}

enum RequestValidationError: Error, Equatable {
    case emptyPrompt
    case promptTooLong(current: Int)
    case negativePromptTooLong(current: Int)
    case stepsOutOfRange(value: Int)
    case guidanceOutOfRange(value: Double)
}

extension RequestValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptyPrompt: return "prompt boş olamaz"
        case .promptTooLong(let n): return "prompt en fazla 500 karakter olabilir (şu an \(n))"
        case .negativePromptTooLong(let n): return "negative_prompt en fazla 500 karakter olabilir (şu an \(n))"
        case .stepsOutOfRange(let v): return "steps 1...50 aralığında olmalı (verilen: \(v))"
        case .guidanceOutOfRange(let v): return "guidance 1.0...15.0 aralığında olmalı (verilen: \(v))"
        }
    }
}

extension GenerateRequestDTO {
    func validated() throws -> (request: GenerationRequest, translate: Bool) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw RequestValidationError.emptyPrompt }
        guard trimmedPrompt.count <= 500 else {
            throw RequestValidationError.promptTooLong(current: trimmedPrompt.count)
        }
        let negative = negativePrompt ?? ""
        guard negative.count <= 500 else {
            throw RequestValidationError.negativePromptTooLong(current: negative.count)
        }
        let stepCount = steps ?? GenerationRequest.defaultSteps
        guard (1...50).contains(stepCount) else {
            throw RequestValidationError.stepsOutOfRange(value: stepCount)
        }
        let scale = guidance ?? GenerationRequest.defaultGuidance
        guard (1.0...15.0).contains(scale) else {
            throw RequestValidationError.guidanceOutOfRange(value: scale)
        }
        let request = GenerationRequest(
            prompt: trimmedPrompt,
            negativePrompt: negative,
            steps: stepCount,
            guidance: scale,
            seed: seed ?? UInt64.random(in: 0..<UInt64.max)
        )
        return (request, translate ?? true)
    }
}

enum ApiErrorCode: String, Sendable {
    case invalidRequest = "invalid_request"
    case queueFull = "queue_full"
    case generationFailed = "generation_failed"
    case modelNotReady = "model_not_ready"
}

struct ApiErrorEnvelope: Codable, Sendable {
    struct Inner: Codable, Sendable {
        let code: String
        let message: String
    }
    let error: Inner
}
```

- [ ] **Step 8: Testin geçtiğini doğrula**

```bash
swift test --filter ApiModelsTests 2>&1 | tail -5
```
Beklenen: `Executed 8 tests, with 0 failures`. (`resimuretici` derlemesine `import StableDiffusion` gerekmediği için ml-stable-diffusion bağımlılığı henüz derlenmez; yine de resolve adımında indirildi.)

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: paket iskeleti ve API istek modeli (GenerateRequestDTO, doğrulama, hata zarfı)

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 2: PromptTranslator (FoundationModels + passthrough)

**Files:**
- Create: `Sources/resimuretici/PromptTranslator.swift`
- Test: `Tests/ResimUreticiTests/PromptTranslatorTests.swift`

**Interfaces:**
- Consumes: (bağımsız)
- Produces:
  - `protocol PromptTranslating: Sendable { func translate(_ prompt: String) async -> String }` — **asla throw etmez**
  - `struct PassthroughTranslator: PromptTranslating`
  - `final class SmartPromptTranslator: PromptTranslating` — `init(translator: (any PromptTranslating)? = nil)`; saf ASCII prompt'u iç çevirmene hiç göndermez; çeviri trim sonrası boşsa orijinali döner
  - `final class FoundationModelsTranslator: PromptTranslating` — `static func make() -> FoundationModelsTranslator?` (Apple Intelligence yoksa nil)

- [ ] **Step 1: FoundationModels API yüzeyini doğrula**

```bash
F="$(xcrun --show-sdk-path)/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface"
grep -n "public class LanguageModelSession\|public init(instructions" "$F" | head -5
grep -n "func respond(to" "$F" | head -5
grep -n "enum Availability\|case available" "$F" | head -5
```
Beklenen: `LanguageModelSession(instructions:)` init'i, `respond(to:)` metodu, `SystemLanguageModel.default.availability == .available` karşılaştırması. İsimler farklıysa gerçek imzaya göre uyarla; mantık değişmez.

- [ ] **Step 2: Testi yaz (kırmızı)**

`Tests/ResimUreticiTests/PromptTranslatorTests.swift`:

```swift
import XCTest
@testable import resimuretici

final class PromptTranslatorTests: XCTestCase {
    private struct FixedTranslator: PromptTranslating {
        let result: String
        func translate(_ prompt: String) async -> String { result }
    }

    func testAsciiPromptSkipsTranslator() async {
        let smart = SmartPromptTranslator(translator: FixedTranslator(result: "ASLA_KULLANILMAMALI"))
        let out = await smart.translate("a red apple on a wooden table")
        XCTAssertEqual(out, "a red apple on a wooden table")
    }

    func testNonAsciiPromptIsTranslated() async {
        let smart = SmartPromptTranslator(translator: FixedTranslator(result: "a red apple"))
        let out = await smart.translate("kırmızı elma")
        XCTAssertEqual(out, "a red apple")
    }

    func testPassthroughReturnsOriginal() async {
        let out = await PassthroughTranslator().translate("kırmızı elma")
        XCTAssertEqual(out, "kırmızı elma")
    }

    func testWhitespaceOnlyTranslationFallsBackToOriginal() async {
        let smart = SmartPromptTranslator(translator: FixedTranslator(result: "   "))
        let out = await smart.translate("kırmızı elma")
        XCTAssertEqual(out, "kırmızı elma")
    }
}
```

- [ ] **Step 3: Testin düştüğünü doğrula**

```bash
swift test --filter PromptTranslatorTests 2>&1 | tail -5
```
Beklenen: BUILD ERROR — `PromptTranslating` tipi yok.

- [ ] **Step 4: Uygulamayı yaz (yeşil)**

`Sources/resimuretici/PromptTranslator.swift`:

```swift
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

    init(translator: (any PromptTranslating)? = nil) {
        if let translator {
            inner = translator
        } else if let fm = FoundationModelsTranslator.make() {
            inner = fm
        } else {
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
final class FoundationModelsTranslator: PromptTranslating, @unchecked Sendable {
    private let session: LanguageModelSession

    static func make() -> FoundationModelsTranslator? {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        return FoundationModelsTranslator()
    }

    private init() {
        session = LanguageModelSession(instructions: """
        Translate the user's text into concise, natural English suitable as an \
        image-generation prompt. Reply with ONLY the translated text.
        """)
    }

    func translate(_ prompt: String) async -> String {
        do {
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
```

- [ ] **Step 5: Testin geçtiğini doğrula**

```bash
swift test --filter PromptTranslatorTests 2>&1 | tail -5
```
Beklenen: `Executed 4 tests, with 0 failures`. (Gerçek LLM çağrısı test edilmez — belirsiz ve yavaş; kontrat mock'larla sabitlenir.)

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: prompt çevirisi (FoundationModels, ASCII atlatma, asla throw etmez)

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 3: PNGCodec + GenerationQueue (actor)

**Files:**
- Create: `Sources/resimuretici/GenerationQueue.swift` (PNGCodec, ImageGenerating protokolü, GeneratedImage, GeneratorError dahil)
- Test: `Tests/ResimUreticiTests/GenerationQueueTests.swift`
- Test support: `Tests/ResimUreticiTests/TestSupport.swift`

**Interfaces:**
- Consumes: `GenerationRequest` (Task 1)
- Produces:
  - `enum GeneratorError: Error, Equatable { case noImageProduced, pngEncodeFailed }`
  - `struct GeneratedImage: Sendable { let cgImage: CGImage; let seedUsed: UInt64 }`
  - `protocol ImageGenerating: Sendable { func generate(_ request: GenerationRequest) async throws -> GeneratedImage }`
  - `enum PNGCodec { static func encode(_ image: CGImage) throws -> Data }`
  - `struct GenerationOutcome: Sendable { let pngData: Data; let generationMs: Int }`
  - `enum QueueError: Error, Equatable { case queueFull }`
  - `actor GenerationQueue` — `init(generator: any ImageGenerating, maxWaiting: Int = 8)`; `func enqueue(_ request: GenerationRequest) async throws -> GenerationOutcome`; `var status: (busy: Bool, waiting: Int)` (await ile okunur)

- [ ] **Step 1: Test desteğini ve testleri yaz (kırmızı)**

`Tests/ResimUreticiTests/TestSupport.swift`:

```swift
import CoreGraphics
import Vapor
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

/// Vapor Response gövdesini Data olarak alır (ByteBuffer sarmalamaları arasında taşınabilir).
func bodyData(_ response: Response) -> Data {
    if let data = response.body.data { return data }
    return Data(response.body.string.utf8)
}
```

`Tests/ResimUreticiTests/GenerationQueueTests.swift`:

```swift
import XCTest
@testable import resimuretici

final class GenerationQueueTests: XCTestCase {
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

    func testFIFOOrderAndSingleConcurrency() async throws {
        let generator = MockGenerator()
        let queue = GenerationQueue(generator: generator)

        async let first = queue.enqueue(request(seed: 1))
        async let second = queue.enqueue(request(seed: 2))
        async let third = queue.enqueue(request(seed: 3))

        let outcome1 = try await first
        let outcome2 = try await second
        let outcome3 = try await third

        for outcome in [outcome1, outcome2, outcome3] {
            XCTAssertEqual(Array(outcome.pngData.prefix(4)), [0x89, 0x50, 0x4E, 0x47]) // PNG imzası
            XCTAssertGreaterThan(outcome.generationMs, 0)
        }
        let order = await generator.startOrder
        XCTAssertEqual(order, [1, 2, 3])
        let maxConcurrent = await generator.maxConcurrent
        XCTAssertEqual(maxConcurrent, 1)
    }

    func testQueueFullWhenOverLimit() async throws {
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
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first as? QueueError, .queueFull)
        XCTAssertEqual(results.count - failures.count, 3)
    }

    func testErrorPropagatesToCaller() async throws {
        let queue = GenerationQueue(generator: MockGenerator(shouldFail: true), maxWaiting: 8)
        do {
            _ = try await queue.enqueue(request(seed: 9))
            XCTFail("hata bekleniyordu")
        } catch let error as GeneratorError {
            XCTAssertEqual(error, .noImageProduced)
        }
    }

    func testStatusReflectsRunningAndWaiting() async throws {
        let queue = GenerationQueue(generator: MockGenerator(delayNanos: 400_000_000), maxWaiting: 8)
        async let job1 = queue.enqueue(request(seed: 1))
        async let job2 = queue.enqueue(request(seed: 2))
        try await Task.sleep(nanoseconds: 50_000_000)
        let mid = await queue.status
        XCTAssertTrue(mid.busy)
        XCTAssertEqual(mid.waiting, 1)
        _ = try await job1
        _ = try await job2
        let end = await queue.status
        XCTAssertFalse(end.busy)
        XCTAssertEqual(end.waiting, 0)
    }
}
```

- [ ] **Step 2: Testin düştüğünü doğrula**

```bash
swift test --filter GenerationQueueTests 2>&1 | tail -5
```
Beklenen: BUILD ERROR — `GenerationQueue` / `ImageGenerating` tipleri yok.

- [ ] **Step 3: Uygulamayı yaz (yeşil)**

`Sources/resimuretici/GenerationQueue.swift`:

```swift
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
```

- [ ] **Step 4: Testin geçtiğini doğrula**

```bash
swift test --filter GenerationQueueTests 2>&1 | tail -5
```
Beklenen: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: FIFO üretim kuyruğu (tek eşzamanlı, 8 bekleyen sınırı) ve PNG kodlayıcı

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 4: CoreMLImageGenerator

**Files:**
- Create: `Sources/resimuretici/ImageGenerator.swift`
- Test: `Tests/ResimUreticiTests/ImageGeneratorTests.swift`

**Interfaces:**
- Consumes: `GenerationRequest` (Task 1), `ImageGenerating`/`GeneratedImage`/`GeneratorError` (Task 3)
- Produces:
  - `final class CoreMLImageGenerator: ImageGenerating, @unchecked Sendable`
    - `init(resourcesAt directory: URL, computeUnits: MLModelConfiguration.ComputeUnits = .cpuAndGPU) throws`
    - `func loadResources() throws`
    - `static func validateResources(at directory: URL) throws`
    - `static let requiredResources = ["TextEncoder.mlmodelc", "VAEDecoder.mlmodelc", "vocab.json", "merges.text"]`

- [ ] **Step 1: ml-stable-diffusion API yüzeyini doğrula**

```bash
grep -rn "public var seed" .build/checkouts/ml-stable-diffusion/Sources/StableDiffusion/ | head -3
grep -rn "public init(resourcesAt" .build/checkouts/ml-stable-diffusion/Sources/StableDiffusion/ | head -3
grep -rn "func generateImages" .build/checkouts/ml-stable-diffusion/Sources/StableDiffusion/ | head -3
grep -rn "public var stepCount\|public var guidanceScale\|public var negativePrompt" .build/checkouts/ml-stable-diffusion/Sources/StableDiffusion/pipeline/StableDiffusionPipeline.swift | head -6
```
Karar kuralı: `seed` alanının tipi `UInt32` ise `config.seed = UInt32(truncatingIfNeeded: request.seed)`; `UInt64` ise `config.seed = request.seed`. Alan adları farklıysa gerçek API'ye göre uyarla; `init(resourcesAt:)` imzası `configuration:` parametresi içermiyorsa mevcut imzaya uy.

- [ ] **Step 2: Testleri yaz (kırmızı)**

`Tests/ResimUreticiTests/ImageGeneratorTests.swift`:

```swift
import XCTest
@testable import resimuretici

final class ImageGeneratorTests: XCTestCase {
    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resimuretici-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fillRequiredResources(_ dir: URL) throws {
        for name in CoreMLImageGenerator.requiredResources {
            let path = dir.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            } else {
                try Data("x".utf8).write(to: path)
            }
        }
    }

    func testValidateRejectsMissingResources() {
        let dir = makeTempDir()
        XCTAssertThrowsError(try CoreMLImageGenerator.validateResources(at: dir)) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(message.contains("vocab.json"), "eksik dosya adını içermeli: \(message)")
        }
    }

    func testValidateRejectsDirectoryItselfMissing() {
        let dir = makeTempDir().appendingPathComponent("yok-boyle-klasor")
        XCTAssertThrowsError(try CoreMLImageGenerator.validateResources(at: dir))
    }

    func testValidateAcceptsCompleteResources() throws {
        let dir = makeTempDir()
        try fillRequiredResources(dir)
        XCTAssertNoThrow(try CoreMLImageGenerator.validateResources(at: dir))
    }

    func testInitThrowsForMissingDirectory() {
        let dir = makeTempDir().appendingPathComponent("yok-boyle-klasor")
        XCTAssertThrowsError(try CoreMLImageGenerator(resourcesAt: dir))
    }
}
```

- [ ] **Step 3: Testin düştüğünü doğrula**

```bash
swift test --filter ImageGeneratorTests 2>&1 | tail -5
```
Beklenen: BUILD ERROR — `CoreMLImageGenerator` tipi yok.

- [ ] **Step 4: Uygulamayı yaz (yeşil)**

`Sources/resimuretici/ImageGenerator.swift`:

```swift
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
        "merges.text",
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

    init(resourcesAt directory: URL, computeUnits: MLModelConfiguration.ComputeUnits = .cpuAndGPU) throws {
        try Self.validateResources(at: directory)
        var configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        self.pipeline = try StableDiffusionPipeline(resourcesAt: directory, configuration: configuration)
    }

    func loadResources() throws {
        try pipeline.loadResources()
    }

    func generate(_ request: GenerationRequest) async throws -> GeneratedImage {
        var config = StableDiffusionPipeline.Configuration(prompt: request.prompt)
        config.negativePrompt = request.negativePrompt
        config.stepCount = request.steps
        config.guidanceScale = Float(request.guidance)
        config.seed = UInt32(truncatingIfNeeded: request.seed) // Step 1'de gerçek tip doğrulandı

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
```

Not: `generateImages` progress handler'ı her adımda `true` döner (v1'de iptal yok — spec kapsamı dışı). Safety checker varsayılan açık kalır (kütüphane davranışı); tetiklenirse nil görsel → `noImageProduced` → 500.

- [ ] **Step 5: Testin geçtiğini doğrula**

```bash
swift test --filter ImageGeneratorTests 2>&1 | tail -5
```
Beklenen: `Executed 4 tests, with 0 failures`. (Gerçek model üretimi Task 8'in smoke testinde.)

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: CoreML üretici (kaynak doğrulama, StableDiffusionPipeline sarmalayıcı)

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 5: Server (Vapor route'ları + readiness)

**Files:**
- Create: `Sources/resimuretici/Server.swift`
- Test: `Tests/ResimUreticiTests/ServerTests.swift`

**Interfaces:**
- Consumes: `GenerateRequestDTO.validated()` (T1), `ApiErrorEnvelope`/`ApiErrorCode` (T1), `PromptTranslating` (T2), `GenerationQueue`/`GenerationOutcome`/`QueueError` (T3)
- Produces:
  - `final class ReadinessFlag: Sendable` — `func set()`; `var isReady: Bool { get }`
  - `struct AppState: Sendable { let queue: GenerationQueue; let translator: any PromptTranslating; let modelName: String; let readiness: ReadinessFlag }`
  - `func routes(_ app: Application, state: AppState) throws` — `GET /health`, `POST /generate`
  - `struct HealthResponse: Content { let status: String; let model: String?; let busy: Bool; let queue: Int }`
  - `enum ApiResponses { static func error(_ code: ApiErrorCode, _ message: String, status: HTTPResponseStatus) -> Response }`

- [ ] **Step 1: Testleri yaz (kırmızı)**

`Tests/ResimUreticiTests/ServerTests.swift`:

```swift
import XCTest
import Vapor
import XCTVapor
@testable import resimuretici

final class ServerTests: XCTestCase {
    private actor StubGenerator: ImageGenerating {
        let delayNanos: UInt64
        init(delayNanos: UInt64 = 0) { self.delayNanos = delayNanos }
        func generate(_ request: GenerationRequest) async throws -> GeneratedImage {
            if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
            return GeneratedImage(cgImage: TestImages.solid(), seedUsed: request.seed)
        }
    }

    private struct FailingGenerator: ImageGenerating {
        func generate(_ request: GenerationRequest) async throws -> GeneratedImage {
            throw GeneratorError.noImageProduced
        }
    }

    private func makeApp(
        generator: any ImageGenerating = StubGenerator(),
        translator: any PromptTranslating = PassthroughTranslator(),
        ready: Bool = true,
        maxWaiting: Int = 8
    ) async throws -> Application {
        let app = try await Application.make(Environment(name: "testing", arguments: ["vapor"]))
        let readiness = ReadinessFlag()
        if ready { readiness.set() }
        let state = AppState(
            queue: GenerationQueue(generator: generator, maxWaiting: maxWaiting),
            translator: translator,
            modelName: "test-model",
            readiness: readiness
        )
        try routes(app, state: state)
        return app
    }

    func testGenerateReturnsPNGWithHeaders() async throws {
        let app = try await makeApp()
        defer { app.shutdown() }
        struct Body: Encodable { let prompt: String; let seed: Int; let translate: Bool }
        try await app.test(.POST, "/generate", beforeResponse: { req in
            try req.content.encode(Body(prompt: "kırmızı elma", seed: 42, translate: false))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.first(name: "content-type")?.hasPrefix("image/png"), true)
            XCTAssertEqual(res.headers.first(name: "X-Seed"), "42")
            XCTAssertEqual(res.headers.first(name: "X-Prompt-Used"), "kırmızı elma")
            XCTAssertNotNil(res.headers.first(name: "X-Generation-Ms"))
            XCTAssertEqual(Array(bodyData(res).prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        })
    }

    func testInvalidPromptReturns400Envelope() async throws {
        let app = try await makeApp()
        defer { app.shutdown() }
        struct Body: Encodable { let prompt: String }
        try await app.test(.POST, "/generate", beforeResponse: { req in
            try req.content.encode(Body(prompt: ""))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
            let envelope = try JSONDecoder().decode(ApiErrorEnvelope.self, from: bodyData(res))
            XCTAssertEqual(envelope.error.code, "invalid_request")
        })
    }

    func testMalformedBodyReturns400() async throws {
        let app = try await makeApp()
        defer { app.shutdown() }
        try await app.test(.POST, "/generate", beforeResponse: { req in
            req.headers.replaceOrAdd(name: .contentType, value: "application/json")
            req.body = .init(string: #"{"gecersiz": true}"#)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testNotReadyReturns503() async throws {
        let app = try await makeApp(ready: false)
        defer { app.shutdown() }
        struct Body: Encodable { let prompt: String }
        try await app.test(.POST, "/generate", beforeResponse: { req in
            try req.content.encode(Body(prompt: "x"))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .serviceUnavailable)
            let envelope = try JSONDecoder().decode(ApiErrorEnvelope.self, from: bodyData(res))
            XCTAssertEqual(envelope.error.code, "model_not_ready")
        })
    }

    func testGenerationFailureReturns500() async throws {
        let app = try await makeApp(generator: FailingGenerator())
        defer { app.shutdown() }
        struct Body: Encodable { let prompt: String }
        try await app.test(.POST, "/generate", beforeResponse: { req in
            try req.content.encode(Body(prompt: "x", seed: 1, translate: false))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .internalServerError)
            let envelope = try JSONDecoder().decode(ApiErrorEnvelope.self, from: bodyData(res))
            XCTAssertEqual(envelope.error.code, "generation_failed")
        })
    }

    func testHealthOK() async throws {
        let app = try await makeApp()
        defer { app.shutdown() }
        try await app.test(.GET, "/health", afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let health = try JSONDecoder().decode(HealthResponse.self, from: bodyData(res))
            XCTAssertEqual(health.status, "ok")
            XCTAssertEqual(health.model, "test-model")
            XCTAssertFalse(health.busy)
            XCTAssertEqual(health.queue, 0)
        })
    }

    func testHealthLoadingWhenNotReady() async throws {
        let app = try await makeApp(ready: false)
        defer { app.shutdown() }
        try await app.test(.GET, "/health", afterResponse: { res in
            let health = try JSONDecoder().decode(HealthResponse.self, from: bodyData(res))
            XCTAssertEqual(health.status, "loading")
        })
    }

    func testQueueFullReturns429UnderBurst() async throws {
        let app = try await makeApp(generator: StubGenerator(delayNanos: 300_000_000), maxWaiting: 2)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 8391
        async let serverRun = app.asyncRun()
        try await Task.sleep(nanoseconds: 300_000_000) // sunucu ayağa kalksın

        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:8391/generate")!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = Data(#"{"prompt":"x","translate":false}"#.utf8)
                    let (_, response) = try? await URLSession.shared.data(for: request)
                    return response?.statusCode ?? 0
                }
            }
            var statuses: [Int] = []
            for await status in group { statuses.append(status) }
            XCTAssertEqual(statuses.filter { $0 == 200 }.count, 3)
            XCTAssertEqual(statuses.filter { $0 == 429 }.count, 1)
        }

        app.shutdown()
        _ = await serverRun
    }
}
```

Not: 429 patlama testi sabit port (8391) kullanır; port meşgulse test başarısız olur — başka süreç kapatılıp tekrar çalıştırılır.

- [ ] **Step 2: Testin düştüğünü doğrula**

```bash
swift test --filter ServerTests 2>&1 | tail -5
```
Beklenen: BUILD ERROR — `routes`/`AppState`/`ReadinessFlag` tipleri yok.

- [ ] **Step 3: Uygulamayı yaz (yeşil)**

`Sources/resimuretici/Server.swift`:

```swift
import Vapor
import Foundation

final class ReadinessFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false

    func set() {
        lock.lock()
        ready = true
        lock.unlock()
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }
}

struct AppState: Sendable {
    let queue: GenerationQueue
    let translator: any PromptTranslating
    let modelName: String
    let readiness: ReadinessFlag
}

struct HealthResponse: Content {
    let status: String
    let model: String?
    let busy: Bool
    let queue: Int
}

enum ApiResponses {
    static func error(_ code: ApiErrorCode, _ message: String, status: HTTPResponseStatus) -> Response {
        let envelope = ApiErrorEnvelope(error: .init(code: code.rawValue, message: message))
        let data = (try? JSONEncoder().encode(envelope)) ?? Data("{}".utf8)
        let response = Response(status: status, body: .init(data: data))
        response.headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        return response
    }
}

func routes(_ app: Application, state: AppState) throws {
    app.get("health") { _ in
        let (busy, waiting) = await state.queue.status
        return HealthResponse(
            status: state.readiness.isReady ? "ok" : "loading",
            model: state.modelName,
            busy: busy,
            queue: waiting
        )
    }

    app.post("generate") { req in
        guard state.readiness.isReady else {
            return ApiResponses.error(
                .modelNotReady,
                "model hâlâ yükleniyor, kısa süre sonra tekrar dene",
                status: .serviceUnavailable
            )
        }
        let dto: GenerateRequestDTO
        do {
            dto = try req.content.decode(GenerateRequestDTO.self)
        } catch {
            return ApiResponses.error(
                .invalidRequest,
                "istek gövdesi şemaya uymuyor: \(error)",
                status: .badRequest
            )
        }
        let (generationRequest, translate): (GenerationRequest, Bool)
        do {
            (generationRequest, translate) = try dto.validated()
        } catch let error as RequestValidationError {
            return ApiResponses.error(
                .invalidRequest,
                error.errorDescription ?? "geçersiz istek",
                status: .badRequest
            )
        } catch {
            return ApiResponses.error(.invalidRequest, "geçersiz istek", status: .badRequest)
        }
        let finalPrompt = translate
            ? await state.translator.translate(generationRequest.prompt)
            : generationRequest.prompt
        let effective = generationRequest.withPrompt(finalPrompt)
        let outcome: GenerationOutcome
        do {
            outcome = try await state.queue.enqueue(effective)
        } catch QueueError.queueFull {
            return ApiResponses.error(
                .queueFull,
                "kuyruk dolu (8 bekleyen sınırı), birazdan tekrar dene",
                status: .tooManyRequests
            )
        } catch {
            return ApiResponses.error(
                .generationFailed,
                "üretim başarısız: \(error)",
                status: .internalServerError
            )
        }
        let response = Response(status: .ok, body: .init(data: outcome.pngData))
        response.headers.replaceOrAdd(name: .contentType, value: "image/png")
        response.headers.replaceOrAdd(name: "X-Prompt-Used", value: effective.prompt)
        response.headers.replaceOrAdd(name: "X-Seed", value: String(effective.seed))
        response.headers.replaceOrAdd(name: "X-Generation-Ms", value: String(outcome.generationMs))
        return response
    }
}
```

- [ ] **Step 4: Testin geçtiğini doğrula**

```bash
swift test --filter ServerTests 2>&1 | tail -8
```
Beklenen: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Tüm test paketi**

```bash
swift test 2>&1 | tail -5
```
Beklenen: tüm önceki testlerle birlikte 0 failure.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: Vapor HTTP sunucusu (/generate, /health, hata zarfları, readiness)

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 6: AppConfig + gerçek EntryPoint (wiring + fail fast)

**Files:**
- Create: `Sources/resimuretici/AppConfig.swift`
- Modify: `Sources/resimuretici/EntryPoint.swift` (Task 1'deki yer tutucunun tamamı değişir)
- Test: `Tests/ResimUreticiTests/AppConfigTests.swift`

**Interfaces:**
- Consumes: `CoreMLImageGenerator` (T4), `routes`/`AppState`/`ReadinessFlag` (T5), `SmartPromptTranslator` (T2), `GenerationQueue` (T3)
- Produces:
  - `struct AppConfig: Equatable, Sendable` + `static func parse(_ args: [String], environment: [String: String]) -> AppConfig`
  - `enum Log { static func info(_ message: String); static func warn(_ message: String); static func error(_ message: String) }` (stderr'e yazar)
  - Çalışan sunucu: parse → `validateResources` (başarısızsa `Log.error` + `exit(1)`) → `Application.make` → `hostname`/`port` ata → generator + queue + translator + `routes` → arka planda `loadResources` (başarı: `readiness.set()`, hata: `Log.error` + `exit(1)`) → `app.asyncRun()` → `app.asyncShutdown()`

- [ ] **Step 1: Testleri yaz (kırmızı)**

`Tests/ResimUreticiTests/AppConfigTests.swift`:

```swift
import XCTest
@testable import resimuretici

final class AppConfigTests: XCTestCase {
    func testDefaults() {
        let config = AppConfig.parse([], environment: [:])
        XCTAssertEqual(config.host, "127.0.0.1")
        XCTAssertEqual(config.port, 8787)
        XCTAssertEqual(config.modelDirectory, "Models/coreml-sd-v1-5-palettized")
    }

    func testEnvironmentOverrides() {
        let config = AppConfig.parse([], environment: [
            "RESIM_PORT": "9000",
            "RESIM_MODEL_DIR": "/tmp/m",
            "RESIM_HOST": "0.0.0.0",
        ])
        XCTAssertEqual(config.port, 9000)
        XCTAssertEqual(config.modelDirectory, "/tmp/m")
        XCTAssertEqual(config.host, "0.0.0.0")
    }

    func testCLIOverridesEnvironment() {
        let config = AppConfig.parse(
            ["resimuretici", "--port", "8080", "--model", "/x", "--host", "1.2.3.4"],
            environment: ["RESIM_PORT": "9000"]
        )
        XCTAssertEqual(config.port, 8080)
        XCTAssertEqual(config.modelDirectory, "/x")
        XCTAssertEqual(config.host, "1.2.3.4")
    }

    func testInvalidPortArgKeepsDefault() {
        let config = AppConfig.parse(["resimuretici", "--port", "abc"], environment: [:])
        XCTAssertEqual(config.port, 8787)
    }
}
```

- [ ] **Step 2: Testin düştüğünü doğrula**

```bash
swift test --filter AppConfigTests 2>&1 | tail -5
```
Beklenen: BUILD ERROR — `AppConfig` tipi yok.

- [ ] **Step 3: AppConfig'i yaz (yeşil)**

`Sources/resimuretici/AppConfig.swift`:

```swift
import Foundation

struct AppConfig: Equatable, Sendable {
    var host = "127.0.0.1"
    var port = 8787
    var modelDirectory = "Models/coreml-sd-v1-5-palettized"

    static func parse(_ args: [String], environment: [String: String]) -> AppConfig {
        var config = AppConfig()
        if let value = environment["RESIM_HOST"] { config.host = value }
        if let value = environment["RESIM_PORT"], let port = Int(value) { config.port = port }
        if let value = environment["RESIM_MODEL_DIR"] { config.modelDirectory = value }
        var index = args.startIndex + 1 // args[0] çalıştırılabilirin adı
        while index < args.count {
            let argument = args[index]
            let valueAt: (Int) -> String? = { offset in
                let position = index + offset
                return position < args.count ? args[position] : nil
            }
            switch argument {
            case "--host":
                if let value = valueAt(1) { config.host = value; index += 2 } else { index += 1 }
            case "--port":
                if let value = valueAt(1), let port = Int(value) {
                    config.port = port
                    index += 2
                } else { index += 1 }
            case "--model":
                if let value = valueAt(1) { config.modelDirectory = value; index += 2 } else { index += 1 }
            default:
                index += 1
            }
        }
        return config
    }
}
```

```bash
swift test --filter AppConfigTests 2>&1 | tail -3
```
Beklenen: `Executed 4 tests, with 0 failures`.

- [ ] **Step 4: Gerçek EntryPoint'i yaz**

`Sources/resimuretici/EntryPoint.swift` (yer tutucunun TAMAMI şununla değişir):

```swift
import Vapor
import Foundation

enum Log {
    static func info(_ message: String) {
        FileHandle.standardError.write(Data("ℹ️  \(message)\n".utf8))
    }
    static func warn(_ message: String) {
        FileHandle.standardError.write(Data("⚠️  \(message)\n".utf8))
    }
    static func error(_ message: String) {
        FileHandle.standardError.write(Data("❌ \(message)\n".utf8))
    }
}

@main
struct ResimUreticiApp {
    static func main() async throws {
        let config = AppConfig.parse(
            CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment
        )
        let modelURL = URL(fileURLWithPath: config.modelDirectory)

        // Fail fast: model kaynakları eksikse hiç başlama.
        do {
            try CoreMLImageGenerator.validateResources(at: modelURL)
        } catch {
            Log.error(error.localizedDescription)
            Log.error("Modeli indirmek için: Scripts/fetch-model.sh")
            exit(1)
        }

        Log.info("model: \(config.modelDirectory)")
        Log.info("http://\(config.host):\(config.port) hazırlanıyor...")

        let app = try await Application.make(Environment(name: "production", arguments: ["vapor"]))
        app.http.server.configuration.hostname = config.host
        app.http.server.configuration.port = config.port

        let generator = try CoreMLImageGenerator(resourcesAt: modelURL)
        let readiness = ReadinessFlag()
        let state = AppState(
            queue: GenerationQueue(generator: generator),
            translator: SmartPromptTranslator(),
            modelName: modelURL.lastPathComponent,
            readiness: readiness
        )
        try routes(app, state: state)

        // Ağır model yüklemesi arka planda; sunucu hemen dinlemeye başlar (/health: loading).
        Task.detached {
            do {
                let startedAt = DispatchTime.now()
                try generator.loadResources()
                readiness.set()
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000_000
                Log.info(String(format: "model yüklendi (%.1f sn) — /generate hazır", seconds))
            } catch {
                Log.error("model yüklenemedi: \(error)")
                exit(1)
            }
        }

        do {
            try await app.asyncRun()
            try await app.asyncShutdown()
        } catch {
            Log.error("sunucu hatası: \(error)")
            try? await app.asyncShutdown()
            exit(1)
        }
    }
}
```

- [ ] **Step 5: Derle ve fail-fast'i elle doğrula**

```bash
swift build 2>&1 | tail -3
swift run resimuretici; echo "exit kodu: $?"
```
Beklenen: derleme başarılı; model henüz inmediği için `❌ model klasöründe eksik kaynaklar...` + `exit kodu: 1`.

- [ ] **Step 6: Tüm testler**

```bash
swift test 2>&1 | tail -3
```
Beklenen: 0 failure.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: AppConfig, Log ve gerçek EntryPoint (fail fast, arka plan model yüklemesi)

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 7: fetch-model.sh + model indirmesi

**Files:**
- Create: `Scripts/fetch-model.sh`

**Interfaces:**
- Produces: `Models/coreml-sd-v1-5-palettized/` altında `TextEncoder.mlmodelc`, `Unet*.mlmodelc`, `VAEDecoder.mlmodelc`, `vocab.json`, `merges.text` — Task 4'ün `requiredResources` listesini karşılar. Script `--list-only` modu dosya listesini indirip yazdırır (test edilebilir).

- [ ] **Step 1: Scripti yaz**

`Scripts/fetch-model.sh`:

```bash
#!/bin/bash
# apple/coreml-stable-diffusion-v1-5-palettized modelini indirir (ücretsiz, hesap gerekmez).
# Kullanım: Scripts/fetch-model.sh [--list-only]
set -euo pipefail

REPO="apple/coreml-stable-diffusion-v1-5-palettized"
OUT="Models/coreml-sd-v1-5-palettized"
API_URL="https://huggingface.co/api/models/${REPO}/tree/main?recursive=true"

# Sadece txt2img için gerekli kaynaklar; VAEEncoder + SafetyChecker atlanır (~1.5 GB tasarruf).
NEEDED='(TextEncoder\.mlmodelc|Unet.*\.mlmodelc|VAEDecoder\.mlmodelc|vocab\.json|merges\.text)'

FILES=$(curl -fsSL "$API_URL" \
  | python3 -c "import json,sys; [print(f['path']) for f in json.load(sys.stdin) if f['type']=='file']" \
  | grep -E "$NEEDED")

if [ "${1:-}" = "--list-only" ]; then
  echo "$FILES"
  exit 0
fi

mkdir -p "$OUT"
echo "$FILES" | while read -r path; do
  [ -z "$path" ] && continue
  dest="$OUT/$path"
  mkdir -p "$(dirname "$dest")"
  echo "⬇️  $path"
  curl -fL --retry 3 --progress-bar -o "$dest" "https://huggingface.co/${REPO}/resolve/main/${path}"
done

echo "OK: model $OUT altına indirildi."
```

- [ ] **Step 2: Çalıştırılabilir yap ve listeleme modunu test et**

```bash
chmod +x Scripts/fetch-model.sh
Scripts/fetch-model.sh --list-only
```
Beklenen: yalnızca `TextEncoder.mlmodelc/**`, `Unet*.mlmodelc/**`, `VAEDecoder.mlmodelc/**`, `vocab.json`, `merges.text` yolları; `VAEEncoder`/`SafetyChecker`/README geçmez.

- [ ] **Step 3: Gerçek indirmeyi çalıştır (bir kez, ~1 GB)**

```bash
Scripts/fetch-model.sh
```
Beklenen: birkaç dakika; son satır `OK: model ...`.

- [ ] **Step 4: İnen kaynakları doğrula**

```bash
ls Models/coreml-sd-v1-5-palettized/
```
Beklenen: `requiredResources` listesindeki 4 kaynağın tamamı mevcut (`TextEncoder.mlmodelc`, `VAEDecoder.mlmodelc`, `vocab.json`, `merges.text`) ve bir UNet paketi (`Unet.mlmodelc` veya benzeri).

- [ ] **Step 5: Commit**

```bash
git add Scripts/fetch-model.sh
git commit -m "feat: model indirme scripti (HF'ten v1-5-palettized, yalnız txt2img kaynakları)

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```
(Models/ gitignore'da; script commit'lenir, model içerik commit'lenmez.)

---

### Task 8: Smoke test + uçtan uca doğrulama + README

**Files:**
- Create: `Tests/ResimUreticiTests/SmokeGenerationTests.swift`
- Create: `README.md`

**Interfaces:**
- Consumes: `CoreMLImageGenerator` (T4), `PNGCodec` (T3), `GenerationRequest` (T1)
- Produces: çalışan, elle doğrulanmış API + README (kurulum, Go örneği, ölçülmüş performans)

- [ ] **Step 1: Smoke testi yaz**

`Tests/ResimUreticiTests/SmokeGenerationTests.swift`:

```swift
import XCTest
@testable import resimuretici

final class SmokeGenerationTests: XCTestCase {
    func testOneStepGenerationProducesValidPNG() async throws {
        let modelDir = ProcessInfo.processInfo.environment["RESIM_MODEL_DIR"]
            ?? "Models/coreml-sd-v1-5-palettized"
        guard FileManager.default.fileExists(atPath: modelDir) else {
            throw XCTSkip("model indirilmemiş: \(modelDir) (Scripts/fetch-model.sh)")
        }
        let generator = try CoreMLImageGenerator(resourcesAt: URL(fileURLWithPath: modelDir))
        try generator.loadResources()
        let request = GenerationRequest(
            prompt: "a red apple on a wooden table",
            negativePrompt: "",
            steps: 1,
            guidance: 7.5,
            seed: 7
        )
        let image = try await generator.generate(request)
        let png = try PNGCodec.encode(image.cgImage)
        XCTAssertGreaterThan(png.count, 1_000)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(image.cgImage.width, 512)
    }
}
```

- [ ] **Step 2: Tüm test paketini çalıştır (smoke artık gerçek üretim yapar)**

```bash
swift test 2>&1 | tail -5
```
Beklenen: 0 failure, 0 skip (model Task 7'de indi). Smoke test birkaç saniye sürer.

- [ ] **Step 3: Sunucuyu başlat ve uçtan uca doğrula**

```bash
swift run resimuretici > /tmp/resimuretici.log 2>&1 &
SERVER_PID=$!
# health 'ok' olana dek bekle:
for i in $(seq 1 60); do
  STATUS=$(curl -fsS http://127.0.0.1:8787/health | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo bekle)
  [ "$STATUS" = "ok" ] && break
  sleep 1
done
echo "health: $STATUS"
```
Beklenen: birkaç on saniye içinde `health: ok`.

- [ ] **Step 4: Türkçe prompt ile gerçek istek at**

```bash
curl -is -X POST http://127.0.0.1:8787/generate \
  -H "Content-Type: application/json" \
  -d '{"prompt":"kırmızı bir elma, ahşap masa üzerinde","steps":25}' \
  -o /tmp/resimuretici-out.png -D /tmp/resimuretici-headers.txt
grep -i "X-Prompt-Used\|X-Seed\|X-Generation-Ms\|HTTP/" /tmp/resimuretici-headers.txt
file /tmp/resimuretici-out.png
```
Beklenen: `HTTP/1.1 200 OK`; `X-Prompt-Used` İngilizce bir çeviri içeriyor; `file` çıktısı `PNG image data, 512 x 512`. Görüntüyü gözle doğrula: `open /tmp/resimuretici-out.png`.

- [ ] **Step 5: Performansı ölç ve kaydet**

```bash
time curl -s -X POST http://127.0.0.1:8787/generate \
  -H "Content-Type: application/json" \
  -d '{"prompt":"a red apple, illustration style"}' -o /dev/null
```
25 adımlık süreyi not et; sunucuyu kapat (`kill $SERVER_PID`) ve README'deki `PERFORMANS_SN` yer tutucusunu ölçülen değerle değiştir (2. tur da ölçüp ortalamayı yazmak yeterli).

- [ ] **Step 6: README yaz**

`README.md` (aşağıdaki şablonun tamamı; `PERFORMANS_SN` Step 5'te ölçülen değerle):

```markdown
# ResimUretici

Metinden resim üreten lokal HTTP API'si. Apple'ın ml-stable-diffusion kütüphanesi
(Core ML) ile Mac'te tamamen lokal çalışır — ücretsiz, bulut yok, API anahtarı yok.

## Kurulum ve çalıştırma

```bash
Scripts/fetch-model.sh        # ~1 GB, bir kez (ücretsiz, hesap gerekmez)
swift build -c release
.build/release/resimuretici   # varsayılan: http://127.0.0.1:8787
```

Seçenekler: `--port`, `--host`, `--model` (veya `RESIM_PORT`, `RESIM_HOST`, `RESIM_MODEL_DIR`).

## API

`POST /generate` — JSON gövde:

| Alan | Tip | Varsayılan | Kural |
|---|---|---|---|
| `prompt` | string | zorunlu | 1..500 karakter |
| `negative_prompt` | string | `""` | ≤ 500 karakter |
| `steps` | int | `25` | 1..50 |
| `guidance` | double | `7.5` | 1.0..15.0 |
| `seed` | uint/null | `null` (rastgele) | `X-Seed` başlığından okunur |
| `translate` | bool | `true` | Türkçe→İngilizce çeviri |

Başarı: `200`, `image/png` byte'ları + `X-Prompt-Used`, `X-Seed`, `X-Generation-Ms` başlıkları.
Hata: `{"error":{"code":"...","message":"..."}}` — `invalid_request` 400, `queue_full` 429,
`generation_failed` 500, `model_not_ready` 503.

`GET /health` → `{"status":"ok|loading","model":"...","busy":false,"queue":0}`

## Go örneği

```go
body := strings.NewReader(`{"prompt":"kırmızı bir elma, illüstrasyon tarzında"}`)
resp, err := http.Post("http://127.0.0.1:8787/generate", "application/json", body)
if err != nil {
    log.Fatal(err)
}
defer resp.Body.Close()
if resp.StatusCode != http.StatusOK {
    b, _ := io.ReadAll(resp.Body)
    log.Fatalf("hata %d: %s", resp.StatusCode, b)
}
f, err := os.Create("resim.png")
if err != nil {
    log.Fatal(err)
}
defer f.Close()
io.Copy(f, resp.Body)
```

## Notlar

- Türkçe (ASCII olmayan) prompt'lar Apple'ın cihaz-içi modeliyle İngilizce'ye çevrilir;
  saf ASCII prompt'lar olduğu gibi gider. Kapatmak için `"translate": false`.
- İllüstrasyon hissi için: prompt'a `flat illustration of ...` ekle, `negative_prompt`:
  `"photo, realistic, 3d render"`.
- Performans: 25 adım ≈ `PERFORMANS_SN` sn (M4, 512×512).
- Apple Intelligence ayarları çeviri için kullanılır; kapalıysa çeviri atlanır, üretim devam eder.
```

- [ ] **Step 7: Son tam doğrulama ve commit**

```bash
swift test 2>&1 | tail -3
git add -A
git commit -m "docs: README (kurulum, API, Go örneği) + smoke entegrasyon testi

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```
Beklenen: 0 failure; README commit'lendi. **Plan tamamlandı:** `swift run resimuretici` + Go'dan `POST /generate` ile PNG byte alınıyor.

---

## Self-Review (yazım sonrası kontrol)

**Spec coverage:** §4 bileşenler → T2 translator, T3 queue+PNG, T4 generator, T5 server, T6 wiring; §5 API sözleşmesi → T1 (DTO/zarf) + T5 (route'lar, başlıklar, kodlar); §6 model yönetimi → T4 `validateResources` + T7 script; §7 çeviri → T2; §8 yapılandırma → T6; §9 proje yapısı → tüm görevlerin dosya listeleri; §10 test stratejisi → T1-T5 birim, T8 smoke; §11 riskler → T1 (Swift 6 fallback notu), T2 (FM fallback + asla throw etmez), T3/T5 (hata→500, kuyruk ayakta), §12 performans → T8 ölçüm. Boşluk yok.

**Placeholder taraması:** Plan içinde TBD/TODO/"uygun şekilde ekle" yok; tek bilinçli yer tutucu README'deki `PERFORMANS_SN` ve onu dolduran ölçüm adımı (T8 Step 5).

**Tip tutarlılığı:** `enqueue(GenerationRequest)` T3↔T5; `ImageGenerating` T3 (protokol)↔T4 (uygulama)↔T5 (stub'lar); `validated()` T1↔T5; `AppState`/`ReadinessFlag` T5↔T6; `requiredResources` T4↔T7 script çıktısı; `withPrompt` T1↔T5. Uyumlu.

**Review Focus kapanışı:** 1→T2 `testAsciiPromptSkipsTranslator`; 2→T3 `testQueueFullWhenOverLimit` + T5 `testQueueFullReturns429UnderBurst`; 3→T4 `testValidateRejectsMissingResources` + T6 Step 5 elle doğrulama; 4→T2 kontrat testleri + impl'deki do/catch; 5→T5 `testGenerateReturnsPNGWithHeaders`.
