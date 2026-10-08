#!/bin/bash
# apple/coreml-stable-diffusion-v1-5-palettized modelini indirir (ücretsiz, hesap gerekmez).
# Kullanım: Scripts/fetch-model.sh [--list-only]
set -euo pipefail

REPO="apple/coreml-stable-diffusion-v1-5-palettized"
OUT="Models/coreml-sd-v1-5-palettized"
API_URL="https://huggingface.co/api/models/${REPO}/tree/main?recursive=true"

# Yalnız "original/compiled" varyantı (macOS GPU için doğru düzen) ve sadece txt2img
# kaynakları: VAEEncoder + SafetyChecker atlanır (~1.5 GB tasarruf).
VARIANT='^original/compiled/'
NEEDED='(TextEncoder\.mlmodelc|Unet\.mlmodelc|VAEDecoder\.mlmodelc|vocab\.json|merges\.txt)'
PREFIX='original/compiled/'

FILES=$(curl -fsSL "$API_URL" \
  | python3 -c "import json,sys; [print(f['path']) for f in json.load(sys.stdin) if f['type']=='file']" \
  | grep -E "$VARIANT" | grep -E "$NEEDED" | sed "s|^$PREFIX||")

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
  curl -fL --retry 3 --progress-bar -o "$dest" "https://huggingface.co/${REPO}/resolve/main/original/compiled/${path}"
done

echo "OK: model $OUT altına indirildi."
