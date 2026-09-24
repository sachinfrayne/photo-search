#!/bin/bash
# Downloads the third-party pieces bundled into PhotoSearch.app:
#   - the Qdrant vector database (official macOS binary)
#   - Google SigLIP 2 base, the search model (converted to Core ML)
#   - Qdrant's web dashboard (for power users: File › Open Search Database…)
#
# Pass --extra-models to also fetch models for comparison (see README,
# "Trying other models").
# Everything lands in vendor/ (gitignored). Safe to re-run; existing files are kept.
set -euo pipefail
cd "$(dirname "$0")/.."

QDRANT_VERSION="v1.19.1"
WEB_UI_VERSION="v0.2.18"
MODEL_REPO="https://huggingface.co/apple/coreml-mobileclip/resolve/main"
MOBILECLIP_REPO="https://raw.githubusercontent.com/apple/ml-mobileclip/main/ios_app/MobileCLIPExplore/Resources"
VENDOR="vendor"

mkdir -p "$VENDOR/models"

if [ ! -x "$VENDOR/qdrant" ]; then
    echo "Downloading Qdrant $QDRANT_VERSION..."
    curl -fL --progress-bar -o "$VENDOR/qdrant.tar.gz" \
        "https://github.com/qdrant/qdrant/releases/download/$QDRANT_VERSION/qdrant-aarch64-apple-darwin.tar.gz"
    tar -xzf "$VENDOR/qdrant.tar.gz" -C "$VENDOR"
    rm "$VENDOR/qdrant.tar.gz"
    chmod +x "$VENDOR/qdrant"
fi

if [ ! -f "$VENDOR/dashboard/index.html" ]; then
    echo "Downloading Qdrant web dashboard $WEB_UI_VERSION..."
    curl -fL --progress-bar -o "$VENDOR/dashboard.zip" \
        "https://github.com/qdrant/qdrant-web-ui/releases/download/$WEB_UI_VERSION/dist-qdrant.zip"
    rm -rf "$VENDOR/dashboard" "$VENDOR/dist"
    unzip -q "$VENDOR/dashboard.zip" -d "$VENDOR"
    mv "$VENDOR/dist" "$VENDOR/dashboard"
    rm "$VENDOR/dashboard.zip"
fi

# The default search model: Google SigLIP 2 (Apache-2.0), converted to Core ML
# by scripts/convert_siglip2.py. The first build takes a few minutes and
# downloads the PyTorch checkpoint once.
convert_siglip2() {  # <hugging face id> <model folder>
    if [ ! -f "$VENDOR/models/$2/model.json" ]; then
        echo "Converting $1 to Core ML (one-time, a few minutes)..."
        uv run --quiet --python 3.12 --with "torch==2.7.0" --with transformers --with coremltools \
            --with sentencepiece --with protobuf --with pillow \
            scripts/convert_siglip2.py "$1" "$VENDOR/models/$2"
    fi
}
convert_siglip2 google/siglip2-base-patch16-256 siglip2-base-256

# Optional models for comparing (--extra-models): the larger SigLIP 2 So400m
# and Apple's MobileCLIP (research-only licence, so never bundled).
mobileclip() {  # <variant: s0|s1|s2|blt> <resize>
    local dir="$VENDOR/models/mobileclip-$1"
    [ -f "$dir/model.json" ] && return
    echo "Downloading MobileCLIP-$1..."
    for part in image text; do
        for f in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
            mkdir -p "$(dirname "$dir/$part.mlpackage/$f")"
            curl -fL --progress-bar -o "$dir/$part.mlpackage/$f" "$MODEL_REPO/mobileclip_$1_$part.mlpackage/$f"
        done
    done
    for f in clip-vocab.json clip-merges.txt; do
        curl -fL --progress-bar -o "$dir/$f" "$MOBILECLIP_REPO/$f"
    done
    cat > "$dir/model.json" <<JSON
{
  "id": "mobileclip-$1",
  "name": "MobileCLIP $(echo "$1" | tr a-z A-Z)",
  "source": "https://huggingface.co/apple/coreml-mobileclip",
  "license": "Apple ML Research Model licence (research use only)",
  "dimensions": 512,
  "image": { "model": "image.mlpackage", "input": "image", "resize": "$2" },
  "text": { "model": "text.mlpackage", "input": "text", "tokenizer": "clip", "contextLength": 77, "prompt": "a photo of {}" },
  "output": "final_emb_1"
}
JSON
}
if [ "${1:-}" = "--extra-models" ]; then
    convert_siglip2 google/siglip2-so400m-patch16-384 siglip2-so400m-384
    mobileclip s2 centerCrop
    mobileclip blt centerCrop
fi

echo "Dependencies ready in $VENDOR/"
