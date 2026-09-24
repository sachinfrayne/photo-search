# PhotoSearch

A native Mac app for finding photos by describing them. Type
“painting in church”, “woman standing in front of a painting in an art
gallery” or “church in Italy” and the grid narrows to the photos that match.
Click a thumbnail to see it full size.

Everything runs on the Mac. Nothing is uploaded, and there is nothing to install:
double-click the app and it works.

## Using the app

1. Open `PhotoSearch.dmg` and drag `PhotoSearch.app` to Applications.
   The first time, macOS asks you to allow it (see `FIRST TIME ON MAC.txt`
   in the DMG, the same one-time step as PhotoSorter).
2. Choose your photos folder. PhotoSearch reads every photo in it; the
   first pass takes a few seconds per hundred photos.
3. Search. Clear the box to see everything again.

Adding photos:

- **Drop them into the folder** in Finder. PhotoSearch notices, tidies them
  into `Year / MM - Month / Country` (exactly like PhotoSorter) and makes them
  searchable within a few seconds.
- **Drag them onto the window.** They're *copied* into the folder, sorted and
  added. Your originals stay where they were, and photos already in the
  library aren't copied twice.

Photos already in their sorted place are never moved. That matters because the
country in the folder name is kept even for photos with no GPS data, and it's
used for searches like “church in Spain”.

In the full-size view: ← / → for the previous/next result, Esc to close,
pinch or double-click to zoom.

## How it works

```
PhotoSearch.app
├── MacOS/PhotoSearch    SwiftUI app
├── MacOS/qdrant         Qdrant vector database, run as a hidden background process
└── Resources/models/    Google SigLIP 2 base image + text encoders (Core ML)
```

- **Embeddings:** Google's [SigLIP 2](https://huggingface.co/google/siglip2-base-patch16-256)
  (base, 256 px, Apache-2.0) maps photos and text into the same 768-dimension space.
  It's converted to Core ML by `scripts/convert_siglip2.py` and runs on the Neural
  Engine, so indexing a photo takes well under a tenth of a second. SigLIP 2 was trained
  on multilingual data, which leaves the door open to searching in other languages.
- **Vector search:** the official [Qdrant](https://github.com/qdrant/qdrant) macOS
  binary. The app starts it on launch, bound to `127.0.0.1` on a random port with a
  per-launch API key. It stores its data in `~/Library/Application Support/PhotoSearch`
  and shuts it down on quit. A small watchdog stops Qdrant even if the app crashes.
- **Search:** the query is embedded and matched with Qdrant's Query API. Three things
  refine the result:
  - Place names, months, years and times of day become payload filters ("church in
    Spain", "2025", "sunset in October"). Time words like "sunrise", "sunset" and
    "night" filter on the hour the photo was taken, because the model can't tell a
    sunrise from a sunset but the camera clock can.
    Filter words are kept out of the text sent to the model, since "2025" says
    nothing about what's in a picture. A query that is only filters ("2025",
    "photos from August") simply lists those photos by date.
  - Apple Vision scene labels add a small score boost through a Qdrant formula query.
  - Each query is calibrated against a random sample of the library, so only photos
    that stand out for *that* query are shown. Raw CLIP scores aren't comparable
    between queries.
- **Sorting, metadata and geocoding** come from `PhotoSorterCore` in the
  [photo-sorter](https://github.com/sachinfrayne/photo-sorter) repo, shared with PhotoSorter.
- Photos are identified by a hash of their content. Moving or renaming a file just
  updates its location in the index, with no re-processing.

Why not Docker: it would require every user to install and run Docker Desktop.
A single native binary gives the same Qdrant with no setup.

## For power users

### Looking inside Qdrant

Choose **File › Open Search Database…**. That opens Qdrant's own web dashboard (bundled with
the app) in your browser. There you can browse the `photos` collection, inspect
payloads and run queries. Qdrant runs with a per-launch API key, which the app copies
to the clipboard. Paste it when the dashboard asks.

### Choosing a different model

Each model is a folder containing its Core ML encoders, its tokenizer and a
`model.json` that describes them. The app ships with `siglip2-base-256`.
To add your own, put its folder in `~/Library/Application Support/PhotoSearch/Models/`,
then pick it in **PhotoSearch › Settings…**. The app restarts and re-reads your photos
with the new model.

`model.json` looks like this:

```json
{
  "id": "siglip2-base-256",
  "name": "SigLIP 2 base-patch16-256",
  "license": "Apache-2.0",
  "dimensions": 768,
  "image": { "model": "image.mlpackage", "input": "image", "resize": "squash" },
  "text": { "model": "text.mlpackage", "input": "input_ids", "tokenizer": "huggingface",
            "contextLength": 64, "lowercase": true, "prompt": "a photo of {}" },
  "output": "embedding",
  "computeUnits": "cpuAndNeuralEngine"
}
```

- `tokenizer` is `huggingface` (a `tokenizer.json` in the folder) or `clip`
  (`clip-vocab.json` and `clip-merges.txt`).
- `resize` is `squash` (SigLIP) or `centerCrop` (CLIP).
- `scripts/convert_siglip2.py <hugging face id> <folder>` converts any SigLIP 2
  checkpoint into such a folder and checks it against PyTorch.
- `./scripts/fetch_deps.sh --extra-models` builds three more for comparison in
  `vendor/models`: SigLIP 2 So400m (1.5 GB), MobileCLIP S2 and MobileCLIP B (LT).
  MobileCLIP is research-only, so it's never bundled.

### Comparing models

Add `compareModels` to `~/Library/Application Support/PhotoSearch/config.json`
(Settings writes `searchModel` in the same file):

```json
{ "searchModel": "siglip2-base-256", "compareModels": ["siglip2-so400m-384", "mobileclip-s2"] }
```

Every listed model gets its own named vector in the same Qdrant collection, and
changing the list rebuilds the index. Then run the same search with each one:

```bash
.build/debug/PhotoSearch --models                                   # what's installed
.build/debug/PhotoSearch --compare "painting in church" --compare "beach"
```

## Building

Requires an Apple Silicon Mac with the Xcode Command Line Tools
(`xcode-select --install`). Full Xcode isn't needed. The
[photo-sorter](https://github.com/sachinfrayne/photo-sorter) repo must be
checked out next to this one (`../photo-sorter`).

```bash
./build_mac.sh
```

On the first run this downloads Qdrant and the dashboard into `vendor/`. It also
converts SigLIP 2 to Core ML, which needs [uv](https://docs.astral.sh/uv/), takes a few
minutes and downloads the PyTorch checkpoint once. It then produces `dist/PhotoSearch.app` and `dist/PhotoSearch.dmg`. Pushing to GitHub
builds the DMG in Actions too.

### Running from source

```bash
./scripts/fetch_deps.sh
swift run
```

Hidden command-line flags help with testing and tuning search. They use the app's
data folder unless `PHOTOSEARCH_DATA` points elsewhere:

```bash
.build/debug/PhotoSearch --index ~/Pictures/Library --search "painting in church"
.build/debug/PhotoSearch --labels                      # Vision labels per photo
.build/debug/PhotoSearch --import <library> <folder>   # same as dropping onto the window
.build/debug/PhotoSearch --compare "<query>"           # same search with every configured model
```

Other development variables: `PHOTOSEARCH_LIBRARY` overrides the photos folder, and
`PHOTOSEARCH_SNAPSHOTS=<dir>` makes the app save screenshots of its own window and quit.
`PHOTOSEARCH_MIN_Z`, `PHOTOSEARCH_MARGIN_Z` and `PHOTOSEARCH_BOOST_Z` override the search
cut-off settings when tuning.

## Limits (v1)

- The query parsing (places, months, stop words) is English. SigLIP 2 itself handles
  other languages, so that's the part to extend.
- Videos are sorted but not yet searchable.
- If nothing in the library matches, a few near misses can still appear.
- Apple Silicon only.

## Licence

PhotoSearch's own code is licensed under the [Apache License 2.0](LICENSE).
Bundled third-party components keep their own licences; see
`packaging/THIRD_PARTY_NOTICES.txt`.

The bundled model, SigLIP 2, is Apache-2.0, so built DMGs can be shared. The optional
MobileCLIP models are under Apple's research-only licence and are never bundled.
