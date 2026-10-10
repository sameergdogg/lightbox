# lightbox — plan

Status: L1–L5, L8 and L9 done (index, Vision signals, search and contact sheets, Photos' own analysis, embeddings, MCP, face identities); L7 in part (guarded delete); L6 judges next. Public at https://github.com/sameergdogg/lightbox.
(the library measurements, existing projects, model benchmarks).

## Scope

Open source (MIT). Swift, macOS 26 minimum; iOS later if the Dedupe iPhone app wants it.
No dependency on Dedupe's private engine (`DedupeCore`). The dependency points one way: apps
depend on lightbox.

## Package layout (to build)

```
Package.swift
Sources/
  LightboxKit/
    Source/       PhotoKit enumeration (includeAllBurstAssets everywhere), pixel access
                  (local original via PHAssetResource, else requestImage), change tokens
    Index/        SQLite: assets, signals, faces, embeddings (float16 blobs), judgements,
                  albums written, deletion log
    Analyze/      T0 Vision signals · T1 embeddings (Core ML) · T2 judges
    Judge/        Judge protocol; OllamaJudge (/api/chat, JSON schema, one image per message);
                  FoundationModelsJudge (#available(macOS 27)); rubrics are versioned files
    Query/        filters, semantic search, near-duplicate neighbours (Vision feature print),
                  best-of ranking
    Output/       contact-sheet renderer, album writer, staged deletion
  lightbox/       CLI (swift-argument-parser), JSON on stdout
  lightbox-mcp/   MCP stdio server over the same commands (Swift MCP SDK)
Tests/
```

## Milestones

| # | Deliverable | Done when |
|---|---|---|
| L1 ✅ | Source + Index | `lightbox index` covers the whole library; burst frames resolve; a rescan after 10 new photos touches 10 rows |
| L2 ✅ | Vision signals (T0) | A ~50k-photo library in under 45 min, resumable; `lightbox show <id>` prints the signals |
| L3 ✅ | Contact sheets + query | `lightbox search --solo --eyes-open --min-aesthetic 0.4 --sheet` writes labelled grids Claude can read |
| L4 ✅ | Apple enrichment | `lightbox import-apple` pulls People, Apple scores and faces through osxphotos when installed; `--person <name>` works |
| L5 ✅ | Embeddings (T1) | `lightbox search --about "at the beach at sunset"` returns a sensible top 20 |
| L6 | Judges (T2) | `lightbox judge --rubric profile_photo` scores a shortlist through Ollama, cached and resumable; the Foundation Models judge on 27 |
| L7 (part) | Albums + staged delete | `lightbox album add`, `lightbox delete stage/confirm` with favourites refused and a deletion log |
| L8 ✅ | MCP | The same tools in Claude Desktop; images returned as MCP image content; deletion keeps its two steps |
| L9 ✅ | Identity | `lightbox faces` embeds faces; `search --person me --scope shared` finds the owner in shared albums, with a calibrated threshold |
| L10 | Evals | `lightbox eval <capability> --provider X` scores any model against the owner's own ground truth and prints the comparison |

L1–L3 is the first useful cut: Claude Code can already do the dating-photo task through the CLI.

## L1 results (2026-10-04, on a real library of about 55k items)

- Full sync: 17 s (debug build). An unchanged incremental sync takes 0.06 s and
  touches 0 rows. Downloading originals in Photos does not register as a change.
- "Ten new photos touch ten rows" is covered by `IndexerTests.tenNewPhotosTouchTenRows`
  against a fake source. It hasn't been watched on the real library yet; that happens the next
  time photos arrive.
- `doctor`: a lookup by id with PhotoKit's default options missed ≈12 % of items. Every one
  was a burst frame Photos hides, meaning neither the representative nor user-picked.
  Photos' own auto-picks are hidden too.
- Photos' database also holds rows for shared albums (`ZCOLLECTIONSHARE`). PhotoKit
  doesn't return them as library assets, and lightbox doesn't index them. Shared albums could
  be added later through `PHAssetCollection` if needed.

## L2 results (2026-10-04, same library)

- One pass over every photo: **3 min 18 s** in a release build. Photos with local pixels ran
  at about 45–185 per second, limited by HEIC decoding (`VTDecoderXPCService`), not by Vision.
  Photos without local pixels cost almost nothing. 0 failures. The index grows by about
  6 KB per analyzed photo, mostly the feature print.
- With Optimise Mac Storage, fewer than half the photos had a local rendition ≥ 512 px. For
  the rest PhotoKit offers only a 64 px thumbnail with network access off. Those are stored as
  *waiting for pixels* and fill in on later runs as originals download.
- **`requestImage` needs an `NSApplication` in a CLI process** (nil, no error, otherwise),
  and its callbacks arrive on the main queue. Handled by
  `PhotoKitSource.prepareCommandLineProcess()`.
- Eye openness checked by eye against face crops: the threshold is
  `VisionSignals.eyesOpenAtLeast = 0.18`; closed or squinting faces scored ≤ 0.16 and open ones
  ≥ 0.20. Laughs squint and sunglasses are noise, so ranking should treat this as one signal,
  not a hard filter.
- Not yet compared against Photos' own stored aesthetic scores (L4 will make that possible).

## L3 results (2026-10-04)

- `PhotoQuery` (people, eyes open, face size and quality, aesthetics, sharpness, labels,
  dates, favourites, location, sort, paging) compiles to one SQL query. A search takes a few
  milliseconds; a 20-photo sheet renders in well under a second from local previews.
- **Results bunch by shoot.** The top 20 solo portraits by aesthetics were five frames from
  one session, three from another, and so on. `distinctWithin` (`--distinct N` minutes) keeps
  one photo per moment, ranked best first. Feature-print similarity could replace the time
  window later.
- "Solo" means one person in the frame, not a particular person. Finding photos of *you*
  needs Photos' People names: L4.
- Scheduling: `Scripts/install.sh` (signed release build, atomic replace) and
  `Scripts/install-agent.sh` (hourly `lightbox refresh`). A launchd job is its own
  "responsible process", so Photos access is asked for and granted to lightbox itself, not
  the terminal.

## L4 results (2026-10-04)

- `import-apple`: an embedded osxphotos script, streamed as JSON lines. About 30 s for ~50k
  photos. Burst frames Photos hides get no Apple data; osxphotos skips them.
- Photos' face `eye_state`, checked by eye against crops: **1 = closed, 2 = open**, 0 = not
  analyzed. It also flags eyes cast down (at a phone, say) as closed, which lightbox's shape
  measure reads as open. On single-face photos the two agree well: 69 % of Apple's "closed"
  faces also measure closed, and 3 % of its "open" ones do.
- The two face tables use different origins. `faces` boxes are normalised to the oriented image
  with a **top-left** origin; `apple_faces.center_y` has a **bottom-left** origin. Join them on
  `|vx + vw/2 − cx| < 0.03` and `|1 − (vy + vh/2) − cy| < 0.03`, which pairs about 80 % of
  single-face photos. Crop pixels with `faces` as stored, without flipping y; a flipped crop
  silently misses the face.
- The same crops exposed a lightbox bug: eye openness was measured in image axes, so a face
  lying sideways scored 3.9. Version 2 measures along the eye's own axis
  (`VisionAnalyzer.version = 2`), with a rotation test.
- Fixed while testing: the text filter reused one positional binding for four `?`s.
- Searches without Vision filters now include unanalyzed photos (person, caption, date,
  Apple score). That matters while most originals are still in iCloud.
- **People names can be badly incomplete.** Photos can split one person across several
  unnamed groups over the years, so a name may cover only part of their photos. Naming or
  merging the groups in Photos fixes it at the source, phone included. Idea for L4.1: import unnamed groups with stable ids,
  `lightbox people --unnamed --sheet` (one face per group), and `--person-group <id>`.

## Shared albums and albums (2026-10-08)

- iCloud shared albums are visible through PhotoKit (`.albumCloudShared`) and their photos
  resolve by id, but a library fetch never returns them, so `enumerateAll` adds them.
  `AssetRecord.isShared` (source type `typeCloudShared`) marks them.
- Photos' change history doesn't reliably cover shared albums, so every sync compares the
  shared set directly (`Indexer.reconcileShared`). Album membership (regular and shared) is
  replaced in full each sync (schema v4: `albums`, `album_members`).
- `PhotoQuery.scope` (all, library, shared) and `.albums`; CLI `--scope`, `--album`, and `lightbox albums`.
- Shared photos have only a 64 px thumbnail, or nothing, on the Mac ("Download Originals" covers
  the library only), so `analyze --fetch-shared` (`AnalysisRunner.Options.fetchShared`) downloads
  previews for them, and only them. About 1 photo/s on the test library; iCloud serves
  shared-album previews slowly. Library originals are still never downloaded.
- `import-apple` gives shared photos Photos' scores and captions with no download. Photos runs no
  face recognition on shared content, so People never covers them.
- macOS 27: osxphotos 0.77.2 can't discover the system library ("Could not get path to photo
  library database"). `import-apple` now passes the library path (`--library`, default
  `~/Pictures/Photos Library.photoslibrary`) via `LIGHTBOX_PHOTOS_LIBRARY`.
- Consumers that delete must filter `isShared` out. Dedupe's Mac pipeline does.

## L7, first part (2026-10-08)

`PhotoDeleter`: `plan(ids)` (deletable, plus refusals: favourite, shared, missing) then
`delete(plan)`, which re-checks, makes one PhotoKit change, and returns what it actually deleted.
Dedupe's Mac app deletes through it.

Favouriting a burst in Photos marks every frame (in the test library, bursts were all-favourite
or not favourite at all). `PhotoDeleter(allowing: .favouritedBurstFrames)` lets a caller delete
a favourited burst's hidden frames (not the representative, not a user pick) when the user marks
them; the default still refuses every favourite. Still to do: the CLI `delete stage/confirm` with a token and
contact sheet, a deletion log table, and album writes.

## Roadmap (agreed 2026-10-04)

lightbox L1–L4 ✅ → Dedupe Mac D1 ✅ (packages + Mac target) → D2 (Mac vs iPhone parity) →
D3 ✅ (Vision keeper scorer) → D4 (Mac review UI + delete, with L7 staged delete alongside) →
L6 (local judges) → D5 (ground truth) → D6 (model tie-break, only if D5 says so). L5
(embeddings) and L8 (MCP) are chat-side and can slot in any time. The dating-profile use case
is parked: it will be run later by a dedicated agent on top of the CLI.

## Capabilities and evals (2026-10-09)

Measured on a real ~55k-photo library (details and numbers stay in the consumer's private
notes; what follows is what generalises). The lesson: **specialist models do the work, a VLM
works on shortlists.** An open-weight VLM was the weakest tool for identity and for picking the
better of two near-duplicates, and a useful one for rating criteria and re-ranking search hits.
Models will keep changing, so lightbox fixes the *jobs* and lets the models behind them swap:

| Capability | What it answers | Default provider (measured) | Notes |
|---|---|---|---|
| `identify` | is this person X? | ArcFace (InsightFace buffalo_l): AUC ≈ 0.998, flat across 17 years of one person's faces | VLMs given reference crops: ~88 % at best, fooled by look-alikes; Vision feature prints: AUC ≈ 0.88. buffalo_l weights are **non-commercial**: the CLI downloads them on the user's machine, lightbox never redistributes them |
| `embed` | text → photos, photo → similar | SigLIP 2 B/16 (Apache-2.0): best P@10 of six embedders, ~3 ms/photo on an M4 Max | so400m and PE-Core L cost 14× more for no gain; Photos' own captions were much weaker |
| `describe` | caption + tags for text search | Qwen3.5 2B/9B via llama-server | Only worth it overnight; fused with embeddings gains a little; wins attribute queries ("blurry") |
| `judge` | rate a photo against a rubric, or rerank hits | Qwen3.5-2B yes/no rerank of the top 30 (+0.04 P@10); gemma4 26B for counts and "would share" | Single-photo scores, never forced A/B (strong position bias); allow "either" |
| `edit` | best take, remove, upscale | classical best take (Vision landmarks + Poisson blend, no model); LaMa Core ML; FLUX.2 klein 4B (Apache) in the CLI | Generative eye fixes changed iris colour: never for faces |

How a provider plugs in: a protocol per capability, results cached per (asset, provider,
prompt/rubric version) in the index, and `lightbox eval` scoring it against ground truth the
user already has: Photos' People tags (identity; other named people as negatives cut false
positives tenfold), favourites, edits and burst picks (taste proxies, weak), a fixed query set
with cached judgements (search), and, from Dedupe, real keep/delete decisions. Swapping in next
year's model is a config change plus one eval run.

Runtime notes from the same runs: Ollama serialises Qwen3.5 requests; `llama-server -np 16` on
the same weights gave 2–4× throughput. Ollama won't hold a second model until the first unloads,
and changing `num_ctx` between calls reloads the model.

## L8 results (2026-10-09)

- `lightbox mcp` on the official Swift SDK (`modelcontextprotocol/swift-sdk` 0.12), stdio, one
  binary, so Claude Desktop launches the same signed lightbox that already holds Photos access
  (Desktop starts servers through its `disclaimer` helper, which makes lightbox, not Claude, the
  responsible process).
- Six read-only tools, annotated `readOnlyHint`. Tool calls go through one actor (the index is one
  SQLite connection). The SigLIP 2 text model loads on the first `about` search and stays loaded.
- Contact sheets for chat: 280 px tiles (about 1400 px wide; models downscale past ~1568 anyway)
  at JPEG quality 0.7 keep a 20-photo sheet at 300–560 KB, inside the ~1 MB chat clients allow per
  tool result; 1500 px at 0.75 reached 626 KB on a busy sheet.
- Measured through a scripted stdio session: `about` search 2.2 s cold (text model load), 0.4 s
  warm; face and filter searches 0.1–0.5 s including the sheet.
- Deletion stays out of MCP until the two-step `stage`/`confirm` exists.

## L5 and L9 results (2026-10-09)

- **Layout.** LightboxKit gained the jobs and storage only: `FaceEmbedder` and
  `ImageTextEmbedder` protocols, `FaceAligner` (Vision landmarks, five points, Umeyama similarity
  onto the ArcFace template), `VectorRunner` (resumable, like `AnalysisRunner`), `Identity`, and
  schema v5 (`vector_runs`, `face_vectors`, `image_vectors`, `identities`, `identity_matches`;
  Float16 vectors). The new `LightboxModels` target holds ONNX Runtime and swift-transformers and
  the two providers (`ArcFace`, `SigLIP2`). Only the CLI links it: a Dedupe Mac build stays at
  8 MB with no ONNX Runtime in it.
- **Weights** download on request into `~/Library/Application Support/lightbox/models`
  (`lightbox models pull arcface|siglip2`). ArcFace comes from InsightFace's `buffalo_l.zip`
  (non-commercial); SigLIP 2 from `onnx-community/siglip2-base-patch16-224-ONNX`.
- **ONNX Runtime and Core ML:** ArcFace runs through the Core ML provider. SigLIP 2's exported
  vision model fails to compile there ("Required param 'pad' is missing" on the patch
  convolution), and compiling the 1.1 GB text model cost 10 s per launch, so SigLIP 2 runs on
  the CPU: a query takes about 1.8 s including loading the text model; 55k photos embed in 17 min.
- **SigLIP 2 fidelity:** the Swift tokenizer reproduces open_clip's tokens exactly (lower case,
  punctuation stripped, end-of-text 1, pad 0 to 64; a test pins it). Image vectors from PhotoKit's
  384 px renditions match open_clip on the originals at cosine 0.979 on average, and the top 10
  for ten queries overlap 89 %.
- **Faces:** 27 photos/s at 1600 px. Shared-album photos are all looked at, not only those where
  the 1024 px Vision pass found a face: that raised the owner's shared matches by about 10 %.
- **Identity calibration bug, found and fixed:** calibrating on a gallery of every tagged face
  (every tagged face) while matching with a capped one (800, spread over the years) put the "sure" threshold far
  too low (61 % found). Mislabelled tags in a huge gallery pull other people close. Calibration
  now uses galleries capped exactly like the final ones: AUC 0.998, 97.5 % found at "sure" with no
  held-out face of another named person accepted. Thresholds are set on plain distances and the
  "nearer than any other named person" rule is applied on top; calibrating after the rule can
  leave no finite threshold, which would let a stranger Photos never named pass (a test covers it).
- `refresh` (the hourly job) now also runs `faces`, rebuilds every identity when new faces
  arrive, and runs `embed`, each only if its weights are installed.

## Changes made for the first consumer (2026-10-05)

- `AnalysisRunner.Options.only`: analyze a subset (Dedupe analyzes only duplicate-set members).
- `LibraryIndex.signalSummaries(ids:faceArea:)`: compact ranking numbers for many photos in one
  query. `faceArea` decides which faces count; comparisons of faces want bigger faces
  than the 1 % "main face" cut.
- `PhotoKitSource` change history: a 10 s budget and a 25 %-of-library cap, then a full sync.
  A sync spanning a People merge (12k+ photos changed) otherwise took 16 minutes.
- `lightbox sheet --columns N`, for keeper/runner-up pairs.
- Apps that run lightbox analysis without a frontmost window should hold a `userInitiated`
  `ProcessInfo` activity: App Nap cut throughput about 10×.

## Decided (2026-10-04)

- Swift; macOS 26; open source under MIT; repo name `lightbox`.
- osxphotos is an optional dependency for Apple's stored analysis. No fork of osxphotos or of
  sweetrb/apple-photos-mcp; borrow tool design from the latter.
- Deletion is part of the toolkit, in two steps (stage, then confirm).
- Default embedding model: SigLIP2-B (Apache 2.0), so the shipped Dedupe app can use it.

## Open

- Judge model default: partly answered (2026-10-09, see "Capabilities and evals"): no VLM beat
  chance at choosing between near-duplicates on proxy labels; gemma4 26B was the only one that
  abstained sensibly. Re-run against Dedupe's real decisions once they exist.
- Check that macOS shows its own confirmation for PhotoKit deletes from a CLI process.
- ✅ Published to GitHub (`sameergdogg/lightbox`) on 2026-10-10, with a fresh history.
