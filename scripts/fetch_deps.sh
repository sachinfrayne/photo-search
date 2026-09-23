#!/bin/bash
# Downloads the third-party pieces bundled into PhotoSearch.app:
#   - the Qdrant vector database (official macOS binary)
#   - Apple's MobileCLIP-S2 image and text encoders (Core ML)
#   - the CLIP tokenizer vocabulary
# Everything lands in vendor/ (gitignored). Safe to re-run; existing files are kept.
set -euo pipefail
cd "$(dirname "$0")/.."

QDRANT_VERSION="v1.19.1"
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

for part in image text; do
    pkg="$VENDOR/models/mobileclip_s2_$part.mlpackage"
    if [ ! -f "$pkg/Data/com.apple.CoreML/weights/weight.bin" ]; then
        echo "Downloading MobileCLIP-S2 $part encoder..."
        for f in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
            mkdir -p "$(dirname "$pkg/$f")"
            curl -fL --progress-bar -o "$pkg/$f" "$MODEL_REPO/mobileclip_s2_$part.mlpackage/$f"
        done
    fi
done

for f in clip-vocab.json clip-merges.txt; do
    if [ ! -f "$VENDOR/models/$f" ]; then
        echo "Downloading $f..."
        curl -fL --progress-bar -o "$VENDOR/models/$f" "$MOBILECLIP_REPO/$f"
    fi
done

echo "Dependencies ready in $VENDOR/"
