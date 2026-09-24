#!/usr/bin/env python3
"""Converts a Google SigLIP 2 checkpoint into a PhotoSearch model folder.

    uv run --python 3.12 --with "torch==2.7.0" --with transformers --with coremltools \
        --with sentencepiece --with protobuf --with pillow \
        scripts/convert_siglip2.py google/siglip2-base-patch16-256 vendor/models/siglip2-base-256

The folder gets image.mlpackage (Core ML, fp16) and text.mlpackage (fp16 with
8-bit weights, mostly its 256k-token vocabulary), the Hugging Face tokenizer files, and model.json describing how
PhotoSearch should drive them. A parity check against PyTorch runs at the end.
"""
import json
import sys
from pathlib import Path

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch
from PIL import Image
from transformers import AutoModel, AutoProcessor

CONTEXT = 64  # SigLIP 2 text length (trained with max_length padding)
PROMPT = "a photo of {}"


def features(out):
    """transformers returns a tensor or a ModelOutput depending on version."""
    return out if isinstance(out, torch.Tensor) else out.pooler_output


def patch_pooling_head(head):
    """SigLIP pools image tokens with nn.MultiheadAttention, which coremltools
    can't trace (an int() over a tensor shape). Same maths, written out."""
    mha = head.attention
    dim, heads = mha.embed_dim, mha.num_heads
    head_dim = dim // heads
    wq, wk, wv = mha.in_proj_weight.split(dim)
    bq, bk, bv = mha.in_proj_bias.split(dim)

    def forward(hidden_state, *args, **kwargs):
        batch, tokens = hidden_state.shape[0], hidden_state.shape[1]
        probe = head.probe.expand(batch, -1, -1)
        q = torch.nn.functional.linear(probe, wq, bq).view(batch, 1, heads, head_dim).transpose(1, 2)
        k = torch.nn.functional.linear(hidden_state, wk, bk).view(batch, tokens, heads, head_dim).transpose(1, 2)
        v = torch.nn.functional.linear(hidden_state, wv, bv).view(batch, tokens, heads, head_dim).transpose(1, 2)
        attn = torch.softmax(q @ k.transpose(-1, -2) / head_dim ** 0.5, dim=-1)
        pooled = (attn @ v).transpose(1, 2).reshape(batch, 1, dim)
        pooled = mha.out_proj(pooled)
        residual = pooled
        pooled = residual + head.mlp(head.layernorm(pooled))
        return pooled[:, 0]

    head.forward = forward


class ImageEncoder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, pixel_values):
        return features(self.model.get_image_features(pixel_values=pixel_values))


class TextEncoder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_ids):
        return features(self.model.get_text_features(input_ids=input_ids.long()))


def quantize(mlmodel):
    config = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric"))
    return cto.linear_quantize_weights(mlmodel, config)


def cosine(a, b):
    a, b = np.asarray(a).ravel(), np.asarray(b).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))


def main(hf_id, out_dir, sample_image=None):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    model = AutoModel.from_pretrained(hf_id, torch_dtype=torch.float32).eval().requires_grad_(False)
    processor = AutoProcessor.from_pretrained(hf_id)
    size = processor.image_processor.size["height"]

    with torch.no_grad():
        reference_pixels = torch.rand(1, 3, size, size) * 2 - 1
        before = features(model.get_image_features(pixel_values=reference_pixels))
        patch_pooling_head(model.vision_model.head)
        after = features(model.get_image_features(pixel_values=reference_pixels))
        print(f"pooling head rewrite: cos = {cosine(before, after):.6f}")
        image_enc, text_enc = ImageEncoder(model).eval(), TextEncoder(model).eval()
        dummy_pixels = torch.zeros(1, 3, size, size)
        dummy_ids = torch.zeros(1, CONTEXT, dtype=torch.int32)
        dims = image_enc(dummy_pixels).shape[-1]
        traced_image = torch.jit.trace(image_enc, dummy_pixels)
        traced_text = torch.jit.trace(text_enc, dummy_ids)

    # SigLIP normalizes pixels with mean 0.5, std 0.5: x / 127.5 - 1.
    image_ml = ct.convert(
        traced_image,
        inputs=[ct.ImageType(name="image", shape=(1, 3, size, size), scale=1 / 127.5,
                             bias=[-1.0, -1.0, -1.0], color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
    )
    text_ml = ct.convert(
        traced_text,
        inputs=[ct.TensorType(name="input_ids", shape=(1, CONTEXT), dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
    )
    # 8-bit weights barely move the text encoder (cos ~0.997 vs PyTorch) but
    # cost the image encoder noticeably (~0.96) on macOS 14's per-channel
    # scheme, so only the text side is quantized.
    text_ml = quantize(text_ml)
    image_ml.save(str(out / "image.mlpackage"))
    text_ml.save(str(out / "text.mlpackage"))
    processor.tokenizer.save_pretrained(str(out))
    (out / "chat_template.jinja").unlink(missing_ok=True)
    # The 8-bit weights crash Core ML's GPU path; CPU + Neural Engine is fine
    # (and the Neural Engine is what we want anyway).
    units = ct.ComputeUnit.CPU_AND_NE
    image_ml = ct.models.MLModel(str(out / "image.mlpackage"), compute_units=units)
    text_ml = ct.models.MLModel(str(out / "text.mlpackage"), compute_units=units)

    name = hf_id.split("/")[-1]
    manifest = {
        "id": out.name,
        "name": f"SigLIP 2 {name.replace('siglip2-', '')}",
        "source": f"https://huggingface.co/{hf_id}",
        "license": "Apache-2.0",
        "dimensions": int(dims),
        "image": {"model": "image.mlpackage", "input": "image", "resize": "squash"},
        "text": {"model": "text.mlpackage", "input": "input_ids", "tokenizer": "huggingface",
                 "contextLength": CONTEXT, "lowercase": True, "prompt": PROMPT},
        "output": "embedding",
        "computeUnits": "cpuAndNeuralEngine",
    }
    (out / "model.json").write_text(json.dumps(manifest, indent=2) + "\n")

    # Parity check, plus reference token ids for the Swift tokenizer test.
    texts = ["painting in church", "woman standing in front of painting in art gallery", "beach"]
    reference = {}
    with torch.no_grad():
        for t in texts:
            prompt = PROMPT.format(t).lower()
            ids = processor.tokenizer(prompt, padding="max_length", max_length=CONTEXT,
                                      truncation=True, return_tensors="np")["input_ids"].astype(np.int32)
            reference[prompt] = ids[0].tolist()
            torch_vec = text_enc(torch.from_numpy(ids)).numpy()
            ml_vec = text_ml.predict({"input_ids": ids})["embedding"]
            print(f"text  cos(torch, coreml) = {cosine(torch_vec, ml_vec):.4f}  {prompt!r}")
        if sample_image:
            img = Image.open(sample_image).convert("RGB")
            pixels = processor(images=img, return_tensors="pt")["pixel_values"]
            torch_vec = image_enc(pixels).numpy()
            ml_vec = image_ml.predict({"image": img.resize((size, size), Image.BILINEAR)})["embedding"]
            print(f"image cos(torch, coreml) = {cosine(torch_vec, ml_vec):.4f}")
    (out / "tokenizer_reference.json").write_text(json.dumps(reference) + "\n")
    print(f"wrote {out} ({dims} dims, {size}px)")


if __name__ == "__main__":
    main(*sys.argv[1:4])
