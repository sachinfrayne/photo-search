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
└── Resources/models/    Apple MobileCLIP-S2 image + text encoders (Core ML)
```

- **Embeddings:** Apple's [MobileCLIP-S2](https://huggingface.co/apple/coreml-mobileclip)
  maps photos and text into the same 512-dimension space. It runs on the Neural Engine
  through Core ML, so indexing a photo takes a few milliseconds.
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

### Trying other models

Create `~/Library/Application Support/PhotoSearch/config.json`:

```json
{
  "searchModel": "mobileclip-s2",
  "compareModels": ["mobileclip-blt"]
}
```

- `searchModel` is the model the app searches with. Built-in IDs are
  `mobileclip-s0`, `mobileclip-s1`, `mobileclip-s2` (default, bundled) and
  `mobileclip-blt`.
- `compareModels` are indexed alongside it. Each model gets its own named vector
  in the same Qdrant collection.
- Model files other than S2 go in `~/Library/Application Support/PhotoSearch/Models/`.
  `./scripts/fetch_deps.sh --extra-models` downloads MobileCLIP-B (LT) into `vendor/models`.
- Other CLIP-style Core ML models that use the CLIP tokenizer can be added under
  `"models"`, with the fields `id`, `imageModel`, `textModel`, `dimensions`,
  `imageInput`, `textInput` and `output`.
- Changing the set of models rebuilds the index on the next launch.

Then compare the same searches across every configured model:

```bash
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

This downloads Qdrant and the models into `vendor/` on the first run (about 250 MB),
then produces `dist/PhotoSearch.app` and `dist/PhotoSearch.dmg`. Pushing to GitHub
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

## Limits (v1)

- English queries. The embedding model sits behind an `EmbeddingModel` protocol. If it
  changes (for example to a multilingual text encoder), the index rebuilds itself.
- Videos are sorted but not yet searchable.
- If nothing in the library matches, the closest one to three photos are still shown.
- Apple Silicon only.

## Licence

PhotoSearch's own code is licensed under the [Apache License 2.0](LICENSE).
Bundled third-party components keep their own licences; see
`packaging/THIRD_PARTY_NOTICES.txt`.

> **Model licence:** the MobileCLIP-S2 weights are under Apple's Machine
> Learning Research Model licence, which only allows non-commercial research
> use. They aren't in this repository (`scripts/fetch_deps.sh` downloads them
> at build time), but a built `PhotoSearch.dmg` contains them. Swap in a
> permissively licensed model (for example SigLIP 2, Apache-2.0) before
> distributing the app.
