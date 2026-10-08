# ResimUretici

Metinden resim üreten lokal HTTP API'si. Apple'ın ml-stable-diffusion kütüphanesi
(Core ML) ile Mac'te tamamen lokal çalışır — ücretsiz, bulut yok, API anahtarı yok.

## Kurulum ve çalıştırma

```bash
Scripts/fetch-model.sh        # ~870 MB, bir kez (ücretsiz, hesap gerekmez)
swift build -c release
.build/release/resimuretici   # varsayılan: http://127.0.0.1:8787
```

Seçenekler: `--port`, `--host`, `--model` (veya `RESIM_PORT`, `RESIM_HOST`, `RESIM_MODEL_DIR`).

Model kaynakları eksikse sunucu açılmaz ve neyin eksik olduğunu yazar.

## API

`POST /generate` — JSON gövde:

| Alan | Tip | Varsayılan | Kural |
|---|---|---|---|
| `prompt` | string | zorunlu | 1..8000 karakter |
| `negative_prompt` | string | `""` | ≤ 8000 karakter |
| `steps` | int | `25` | 2..50 (1, kütüphanedeki bilinen çökme nedeniyle reddedilir) |
| `guidance` | double | `7.5` | 1.0..15.0 |
| `seed` | uint/null | `null` (rastgele) | `X-Seed` başlığından okunur |
| `translate` | bool | `true` | Türkçe→İngilizce çeviriyi kapatır/açar (yoğunlaştırmayı etkilemez) |

Başarı: `200`, `image/png` byte'ları + `X-Prompt-Used` (percent-encoded, üretime giden
nihai İngilizce prompt), `X-Seed`, `X-Generation-Ms` başlıkları.

Hata: `{"error":{"code":"...","message":"..."}}` — `invalid_request` 400, `queue_full` 429,
`generation_failed` 500, `model_not_ready` 503.

`GET /health` → `{"status":"ok|loading","model":"...","busy":false,"queue":0}`

Aynı anda tek üretim yapılır; sonraki istekler FIFO sıraya girer (en fazla 8 bekleyen,
taşan istek 429 alır).

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

- **Uzun promptlar:** SD 1.5'in metin kodlayıcısı 77 token (~250-350 karakter) alır; üzeri
  kütüphanede sessizce kesilir. Bu yüzden 77 tokenı aşan prompt/negative_prompt, Apple'ın
  cihaz-içi modeliyle (FoundationModels) **otomatik yoğunlaştırılır**: ana konular, stil ve
  ruh korunarak kısa bir İngilizce prompt'a sıkıştırılır. Modele gerçekte giden metin her
  zaman `X-Prompt-Used` başlığında görünür. Kısa promptlarda hiçbir işlem yapılmaz
  (LLM'e gidilmez, gecikme yok); uzun promptlarda +1-3 sn.
- Türkçe (ASCII olmayan) prompt'lar Apple'ın cihaz-içi modeliyle (FoundationModels)
  İngilizce'ye çevrilir; saf ASCII prompt'lar olduğu gibi gider. Kapatmak için
  `"translate": false` — bu bayrak yalnız çeviriyi kapatır, yoğunlaştırmayı değil
  (kapatması uzun metni sessizce kaybettirirdi).
- İllüstrasyon hissi için: prompt'a `flat illustration of ...` ekle, `negative_prompt`:
  `"photo, realistic, 3d render"`.
- Performans: 25 adım ≈ **19-20 sn** (M4, release, GPU, 512×512); model yüklenmesi
  açılışta ~12 sn.
- Apple Intelligence ayarları çeviri ve yoğunlaştırma için kullanılır; kapalıysa atlanır,
  üretim devam eder (bu durumda 77 token üstü metin kütüphanence kesilir).
- Model: `apple/coreml-stable-diffusion-v1-5-palettized` (6-bit, 512×512). SDXL'e geçmek
  için karşılık gelen Core ML klasörünü indirip `--model` ile göstermek yeterli.

## Testler

```bash
swift test    # birim testler + gerçek modelle smoke testi (model yoksa smoke atlanır)
```
