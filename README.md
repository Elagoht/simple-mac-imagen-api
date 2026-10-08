# simple-mac-imagen-api

A free, fully **local** text-to-image HTTP API for Apple Silicon Macs.
Send text → get PNG bytes back. No cloud, no API keys, no accounts.

Powered by Apple's [`ml-stable-diffusion`](https://github.com/apple/ml-stable-diffusion)
(Core ML, GPU) — and Apple's on-device Foundation Models for Turkish→English prompt
translation and long-prompt condensation.

> The server binary is named `resimuretici` — Turkish for "image generator".

## System requirements

| | |
|---|---|
| Hardware | Apple Silicon Mac (M1 or newer) |
| OS | **macOS 26 or later** |
| RAM | 8 GB works with SD 1.5 · **16 GB recommended** (SDXL) |
| Disk | ~0.9 GB (SD 1.5) / ~3 GB (SDXL) for the model |
| Apple Intelligence | **Optional** — powers Turkish→English translation and long-prompt condensation. Without it the server still runs; prompts are used as-is (SD models are English-trained, so quality is best with English or with Apple Intelligence on). |

## Install (from Releases — no build needed)

1. Download **`simple-mac-imagen-api-macos-arm64.zip`** from the
   [Releases](../../releases) page.
2. Unzip, then remove the Gatekeeper quarantine from the binary:

   ```bash
   cd simple-mac-imagen-api
   xattr -d com.apple.quarantine resimuretici
   ```

3. Download a model (once; free, no account needed):

   ```bash
   chmod +x fetch-model.sh
   ./fetch-model.sh          # SD 1.5 — fast (~870 MB)
   ./fetch-model.sh --sdxl   # SDXL — quality (~2.9 GB)
   ```

4. Run:

   ```bash
   ./resimuretici            # serves http://127.0.0.1:8787
   # or the quality model:
   ./resimuretici --model Models/coreml-sdxl-base
   ```

You can keep both models side by side and switch with `--model`.
You can also copy a `Models/` folder from another machine instead of downloading.

## Models

| Model | Resolution | Speed (25 steps, M4) | Download |
|---|---|---|---|
| SD 1.5 (6-bit) | 512×512 | ~20 s/image | `./fetch-model.sh` |
| SDXL Base (6-bit) | 768×768 | ~80 s/image | `./fetch-model.sh --sdxl` |

Model type is detected automatically (`--model` just points at a folder).
Both are downloaded from Apple's repos on
[Hugging Face](https://huggingface.co/apple) and remain subject to their licenses.

## API

### `POST /generate`

JSON body:

| Field | Type | Default | Rule |
|---|---|---|---|
| `prompt` | string | required | 1..8000 chars |
| `negative_prompt` | string | `""` | ≤ 8000 chars |
| `steps` | int | `25` | 2..50 (`1` is rejected — known library crash) |
| `guidance` | double | `7.5` | 1.0..15.0 |
| `seed` | uint/null | `null` (random) | echoed in `X-Seed` |
| `translate` | bool | `true` | Turkish→English translation on/off (does **not** disable condensation) |

Success: `200` with `image/png` bytes, plus headers:
- `X-Prompt-Used` — the final (translated/condensed) prompt actually sent to the model, percent-encoded
- `X-Seed` — the seed used (repeat it to reproduce an image)
- `X-Generation-Ms` — generation time

Errors: `{"error":{"code":"...","message":"..."}}` —
`invalid_request` 400 · `queue_full` 429 · `generation_failed` 500 · `model_not_ready` 503.

One image is generated at a time; further requests queue (max 8 waiting, extras get 429).

`GET /health` → `{"status":"ok|loading","model":"...","busy":false,"queue":0}`

### Go example

```go
body := strings.NewReader(`{"prompt":"kırmızı bir elma, illüstrasyon tarzında"}`)
resp, err := http.Post("http://127.0.0.1:8787/generate", "application/json", body)
if err != nil {
    log.Fatal(err)
}
defer resp.Body.Close()
if resp.StatusCode != http.StatusOK {
    b, _ := io.ReadAll(resp.Body)
    log.Fatalf("error %d: %s", resp.StatusCode, b)
}
f, err := os.Create("image.png")
if err != nil {
    log.Fatal(err)
}
defer f.Close()
io.Copy(f, resp.Body)
```

## Notes

- **Long prompts:** the SD text encoder only reads the first 77 tokens (~250–350
  characters); everything beyond is silently dropped by the library. Prompts exceeding
  77 tokens are therefore **automatically condensed** on-device (key subjects, style and
  mood preserved) — the effective prompt is always visible in `X-Prompt-Used`. Short
  prompts pass through untouched (no LLM call, no latency).
- **Turkish prompts** are translated to English on-device first (pure-ASCII prompts are
  assumed English and skipped).
- The server binds `127.0.0.1` by default (`--host` to change). There is **no
  authentication** — if you bind beyond localhost, do it only on a trusted LAN.
- Options: `--port`, `--host`, `--model` (env: `RESIM_PORT`, `RESIM_HOST`, `RESIM_MODEL_DIR`).

## Build from source

Requires macOS 26+ with Xcode 26 (or Command Line Tools from the macOS 26+ SDK):

```bash
git clone <this repo>
cd simple-mac-imagen-api
swift build -c release
Scripts/fetch-model.sh
.build/release/resimuretici
```

Note: running the **test suite** (`swift test`) currently expects Apple's Command Line
Tools layout (`Package.swift` carries a CLT-specific linker path for the test target);
the release binary itself has no such dependency.
