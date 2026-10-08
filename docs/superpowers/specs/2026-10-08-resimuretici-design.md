# ResimUretici — Tasarım Spec'i

- **Tarih:** 2026-10-08
- **Durum:** Onaylandı (tasarım kullanıcaca onaylandı; spec gözden geçirme aşamasında)
- **Platform:** macOS 27.0.1, Apple M4, 16 GB RAM
- **Dil:** Swift 6.4 (SPM)

## 1. Amaç

Go ile yazılmış bir backend'in HTTP isteği attığı, metin prompt'tan resim (PNG byte) üreten,
Mac Mini M4'te tamamen lokal ve ücretsiz çalışan bir API sunucusu.

**Başarı kriterleri:**

1. `POST /generate` ile Türkçe bir prompt gönderildiğinde 200 + geçerli PNG (512×512) dönüyor.
2. Tamamen lokal: hiçbir istek dış servise gitmiyor (model indirmesi hariç, bir kerelik).
3. Manuel başlatma: `swift run resimuretici` veya release binary.
4. Aynı anda tek üretim; sonraki istekler sıraya giriyor.
5. Birim testleri ve (model mevcutsa) smoke entegrasyon testi geçiyor.

## 2. Arka Plan ve Kısıtlar (spike bulguları, 2026-10-08)

- Apple Image Playground'un arayüzsüz API'si `ImageCreator` **macOS 27'de kapatıldı**
  (Apple'ın Haziran 2026 duyurusu; bu makinede `ImageCreatorError.notSupported` canlı doğrulandı).
  Bu yol artık kullanılamaz; spec bunu varsayar ve geri dönüş planı içermez.
- `com.apple.developer.imageplayground` entitlement'ı ad-hoc imzayla kullanılamıyor
  (sistem süreci SIGKILL ile öldürüyor).
- Apple Intelligence bu makinede **hazır**: `SystemLanguageModel.availability == .available`
  → FoundationModels (cihaz-içi LLM) çeviri için kullanılabilir.
- Apple'ın `ml-stable-diffusion` paketi (Core ML) macOS 13.1+ / M1+ gerektirir; M4'te sorunsuz.
  Apple'ın hazır Core ML modelleri HuggingFace'te yayınlanmıştır (ücretsiz indirme).

## 3. Kapsam

**İçinde (v1):**

- Vapor 4 tabanlı HTTP sunucusu, `POST /generate` + `GET /health`
- `ml-stable-diffusion` ile Core ML üretim (varsayılan model: `apple/coreml-stable-diffusion-v1-5-palettized`)
- Türkçe→İngilizce prompt çevirisi (FoundationModels, kapatılabilir)
- FIFO üretim kuyruğu (tek eşzamanlı, maks 8 bekleyen)
- Model indirme script'i (`Scripts/fetch-model.sh`)
- Birim + smoke testler, README

**Dışında (v1):** LaunchAgent/otomatik başlatma, istek iptali, image-to-image, eşzamanlı çoklu model,
kimlik doğrulama, HTTPS, style preset'leri (Image Playground stillerinin SD karşılığı yok).

## 4. Mimari

Tek Swift executable (`resimuretici`), dört bileşen:

```
istek ─▶ Server (Vapor) ─▶ GenerationQueue (actor) ─▶ CoreMLImageGenerator
                │                                        (StableDiffusionPipeline)
                └─▶ PromptTranslator (FoundationModels, opsiyonel)
```

- **Server** (`Sources/resimuretici/Server.swift`): Route'lar, istek doğrulama, hata eşleme.
  Sadece `127.0.0.1:8787`'ye bağlanır (varsayılan). Model yüklendiğinde `/generate` açılır;
  yüklenene kadar `503`.
- **GenerationQueue** (`actor`): FIFO, tek eşzamanlı üretim. 8'den fazla bekleyen istek varsa
  yeni gelen `429` alır. İptal yok (v1) — bir üretim başlarsa bitene kadar sürer.
- **CoreMLImageGenerator**: `ImageGenerating` protokolünü uygular; `StableDiffusionPipeline`
  sarmalar. Tek pipeline instance'ı, sadece kuyruk actor'ü içinden erişilir. Testlerde mock ile
  değiştirilir.
- **PromptTranslator**: `PromptTranslating` protokolü. FoundationModels uygulaması; kullanılamıyorsa
  passthrough uygulamasına düşer ve konsola uyarı yazar (sunucu çalışmaya devam eder).

### Veri akışı

1. Go client → `POST /generate` (JSON gövde).
2. Doğrulama (400'ler). Kuyruk doluysa 429.
3. `translate=true` ve prompt ASCII değilse → FoundationModels ile İngilizce'ye çevrilir
   (çeviri başarısızsa orijinal prompt'la devam, uyarı loglanır).
4. Kuyrukta sıra gelince `ImageGenerator.generate` çalışır → CGImage → PNG encode.
5. Yanıt: 200, `image/png` byte'ları + debug başlıkları.

## 5. API Sözleşmesi

### `POST /generate`

İstek gövdesi (JSON):

| Alan | Tip | Zorunlu | Varsayılan | Kural |
|---|---|---|---|---|
| `prompt` | String | evet | — | 1..500 karakter |
| `negative_prompt` | String | hayır | `""` | 0..500 karakter |
| `steps` | Int | hayır | `25` | 1..50 |
| `guidance` | Double | hayır | `7.5` | 1.0..15.0 |
| `seed` | UInt64 / null | hayır | `null` (rastgele) | — |
| `translate` | Bool | hayır | `true` | — |

Başarılı yanıt: `200`, `Content-Type: image/png`, gövde PNG byte'ları. Yanıt başlıkları:
- `X-Prompt-Used`: üretime giden nihai (muhtemelen çevrilmiş) prompt — hata ayıklama için
- `X-Seed`: kullanılan gerçek seed (null verilmişse üretilen)
- `X-Generation-Ms`: üretim süresi

Hata yanıtı (tümü JSON): `{"error": {"code": "...", "message": "..."}}`

| Durum | code | Ne zaman |
|---|---|---|
| 400 | `invalid_request` | Eksik/geçersiz alan |
| 429 | `queue_full` | 8 bekleyen istek varken yeni istek |
| 500 | `generation_failed` | Pipeline üretim istisnası |
| 503 | `model_not_ready` | Model hâlâ yükleniyor |

Model klasörü yoksa sunucu **açılışta hata verip çıkar** (fail fast) — 503 sadece yükleme
süresi içindir.

### `GET /health`

```json
{"status": "loading" | "ok", "model": "coreml-sd-v1-5-palettized", "busy": false, "queue": 0}
```

## 6. Model Yönetimi

- Varsayılan model: `apple/coreml-stable-diffusion-v1-5-palettized` (6-bit, 512×512, ~1-2 GB RAM,
  M4'te beklenen ~5-10 sn/görsel 25 adımda). Beklentiler README'ye "tahmini" olarak yazılır;
  ölçüm implementation sırasında yapılır.
- `Scripts/fetch-model.sh`: HuggingFace'ten (`resolve/main` URL'leri, curl) gerekli kaynakları
  (`TextEncoder.mlmodelc`, `Unet*.mlmodelc`, `VAEDecoder.mlmodelc`, `vocab.json`, `merges.text`)
  `Models/coreml-sd-v1-5-palettized/` altına indirir. Bağımlılık gerektirmez (yalnız curl).
- Model klasörü CLI/env ile değiştirilebilir → SDXL'e geçiş sadece dosya indirme meselesi.
- `Models/` gitignore'da.

## 7. Çeviri Modülü

- Protokol: `PromptTranslating { func translate(_ prompt: String) async -> String }`
  (hata fırlatmaz; başarısızlıkta orijinali döner — üretim asla çeviri yüzünden durmaz).
- FoundationModels uygulaması: `LanguageModelSession` ile "yalnızca çeviriyi döndür" talimatı.
- Atlatma kuralı: prompt saf ASCII ise LLM'e hiç gidilmez (İngilizce varsayımı).
- FoundationModels kullanılamazsa: passthrough + bir kez uyarı logu.

## 8. Yapılandırma

| CLI | Env | Varsayılan |
|---|---|---|
| `--port N` | `RESIM_PORT` | `8787` |
| `--host ADDR` | `RESIM_HOST` | `127.0.0.1` |
| `--model PATH` | `RESIM_MODEL_DIR` | `Models/coreml-sd-v1-5-palettized` |

Açılış sırası: argüman çözümle → model klasörü kontrol (yoksa çıkış) → Vapor dinlemeye başlar
(arka planda) → pipeline yüklenir → `/health` `ok` olur.

## 9. Proje Yapısı

```
ResimUretici/
├── Package.swift                  (deps: vapor, apple/ml-stable-diffusion)
├── Sources/resimuretici/
│   ├── main.swift                 (argüman, başlatma)
│   ├── ApiModels.swift            (Codable istek/yanıt + doğrulama)
│   ├── Server.swift               (Vapor route'lar, hata eşleme)
│   ├── GenerationQueue.swift      (actor: FIFO, limit)
│   ├── ImageGenerator.swift       (protokol + CoreML uygulaması)
│   └── PromptTranslator.swift     (protokol + FoundationModels/passthrough)
├── Tests/ResimUreticiTests/       (ApiModels, queue, handler+mock, smoke)
├── Scripts/fetch-model.sh
├── Models/                        (gitignore)
└── README.md                      (kurulum, Go örneği, prompt önerileri)
```

`probe/` klasörü atıl spike kodudur; implementation başında silinir.

## 10. Test Stratejisi

- **ApiModels:** decode + doğrulama sınır değerleri (boş prompt, 501 karakter, steps 0/51…).
- **GenerationQueue:** FIFO sırası, tek eşzamanlılık, limit aşımı (429).
- **Server handler (mock generator + mock translator):** 200 + header'lar; 400/429/500/503 eşlemeleri.
- **Smoke entegrasyon:** model mevcutken steps=1 üretim → geçerli PNG (model yoksa `skip`).
- Çeviri testleri heuristic/passthrough üzerine; gerçek LLM çağrısı test edilmez (belirsiz, yavaş).

## 11. Riskler ve Önlemler

| Risk | Önlem |
|---|---|
| ml-stable-diffusion Swift 6 strict concurrency uyarıları | App target'ında `@preconcurrency import`; gerekirse Swift 5 dil modu |
| FoundationModels API drift | Çeviri modülü protokol arkasında; kullanılamazsa passthrough |
| İlk model indirmesi büyük (~1 GB) | fetch-model.sh ilerleme basar; README'de belirtilir |
| Üretim anında Metal/GPU hatası | 500 + sıra çalışmaya devam eder; pipeline yeniden yükleme v1'de yok (restart yeterli) |

## 12. Performans Beklentileri

- Pipeline yükleme: ~10-20 sn (açılışta bir kez)
- Üretim (25 step, 512²): ~5-10 sn hedef; ölçülüp README'ye yazılır
- Bellek: pipeline + üretim tepe noktası ~2-3 GB (16 GB'ta rahat)
