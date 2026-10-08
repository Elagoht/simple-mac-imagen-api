#!/bin/bash
# Apple'ın Core ML stable diffusion modellerini indirir (ücretsiz, hesap gerekmez).
# Kullanım: Scripts/fetch-model.sh [--sdxl] [--list-only]
set -euo pipefail

LIST_ONLY=0
SDXL=0
for arg in "$@"; do
  case "$arg" in
    --list-only) LIST_ONLY=1 ;;
    --sdxl) SDXL=1 ;;
    *) echo "bilinmeyen argüman: $arg (kullanım: [--sdxl] [--list-only])" >&2; exit 1 ;;
  esac
done

if [ "$SDXL" = "1" ]; then
  REPO="apple/coreml-stable-diffusion-xl-base-ios"
  VARIANT_DIR="coreml-stable-diffusion-xl-base-ios_split_einsum_compiled"
  OUT="Models/coreml-sdxl-base"
  # SDXL: TextEncoder2 + chunk'lı Unet; VAEEncoder atlanır.
  NEEDED='(TextEncoder\.mlmodelc|TextEncoder2\.mlmodelc|UnetChunk[12]\.mlmodelc|VAEDecoder\.mlmodelc|vocab\.json|merges\.txt)'
else
  REPO="apple/coreml-stable-diffusion-v1-5-palettized"
  VARIANT_DIR="original/compiled"
  OUT="Models/coreml-sd-v1-5-palettized"
  # SD 1.5: yalnız txt2img kaynakları; VAEEncoder + SafetyChecker atlanır.
  NEEDED='(TextEncoder\.mlmodelc|Unet\.mlmodelc|VAEDecoder\.mlmodelc|vocab\.json|merges\.txt)'
fi

API_URL="https://huggingface.co/api/models/${REPO}/tree/main?recursive=true"
VARIANT='^'"$VARIANT_DIR"'/'
PREFIX="$VARIANT_DIR/"

FILES=$(curl -fsSL "$API_URL" \
  | python3 -c "import json,sys; [print(f['path']) for f in json.load(sys.stdin) if f['type']=='file']" \
  | grep -E "$VARIANT" | grep -E "$NEEDED" | sed "s|^$PREFIX||")

if [ "$LIST_ONLY" = "1" ]; then
  echo "$FILES"
  exit 0
fi

mkdir -p "$OUT"
echo "$FILES" | while read -r path; do
  [ -z "$path" ] && continue
  dest="$OUT/$path"
  mkdir -p "$(dirname "$dest")"
  echo "⬇️  $path"
  curl -fL --retry 3 --progress-bar -o "$dest" "https://huggingface.co/${REPO}/resolve/main/${VARIANT_DIR}/${path}"
done

echo "OK: model $OUT altına indirildi."
echo "Çalıştırma: resimuretici --model $OUT"
