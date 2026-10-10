# lightbox — notes for agents

Open-source (MIT) Swift toolkit that lets AI query and look at an Apple Photos library.
Read `README.md` for what it is and `PLAN.md` for milestones. The first consumer is the Dedupe
app (closed source). It depends on lightbox; lightbox must never import anything from it.

## Commands

```sh
swift build && swift test          # all with fakes, synthetic images, in-memory SQLite; no Photos access needed
.build/debug/lightbox index|analyze [--fetch-shared]|refresh|search|sheet|import-apple [--library]|people|albums|stats|show <id>|doctor|models|faces|identify|embed|mcp [--json] [--db path]
./Scripts/install.sh && ./Scripts/install-agent.sh   # ~/.local/bin + hourly LaunchAgent
swift build -c release             # use the release binary for `analyze` over a whole library
```

Layout: `Sources/LightboxKit/` holds `Model` (AssetRecord), `Index` (Database wrapper,
LibraryIndex with migrations, `+Signals`), `Source` (AssetSource, PhotoKitSource, ImageLoader),
`Analyze` (Grayscale pixel stats, VisionAnalyzer, AnalysisRunner), `Query` (PhotoQuery → SQL),
`Output` (ContactSheet, PhotoDeleter), `Apple` (osxphotos import), `Models` (the jobs models do:
`FaceEmbedder`, `ImageTextEmbedder`, `FaceAligner`, `VectorRunner`, `Identity`) and `Indexer.swift`.
`Sources/LightboxModels/` holds the model runtimes (ONNX Runtime, tokenizers) and providers
(ArcFace, SigLIP 2); only the CLI links it, so apps that embed LightboxKit ship no runtime.
`Sources/lightbox/` is the CLI, including `mcp` (the MCP server). `skills/lightbox/` is the
Claude skill that teaches a model to use the tools. `Support/lightbox-Info.plist` is linked into the CLI binary
so macOS can show the Photos prompt.

Schema changes go forward only: append to `LibraryIndex.migrations`, never edit a shipped
entry. Store dates as `timeIntervalSinceReferenceDate`, so they round-trip exactly.

## Rules

- **Public repo hygiene.** Nothing personal goes in: no photo ids, names, faces, library
  stats, or Apple account IDs. Test with synthetic images or public-domain samples only.
  Measurements on a real library go in as rounded, anonymous figures or not at all.
- **Never write to `Photos.sqlite`.** Read it only through osxphotos (optional enrichment) or
  `?mode=ro&immutable=1`. LightboxKit itself must work with PhotoKit alone, so sandboxed apps
  can use it.
- **Deletion only through the two-step path** (stage → confirm), never favourites, never
  shared-album photos (`AssetRecord.isShared`), always logged. No tool deletes in one call.
  The one exception is opt-in per caller: `PhotoDeleter(allowing: .favouritedBurstFrames)` may
  delete the hidden frames of a burst favourited as a whole (Photos marks every frame). The
  frame Photos shows is never deletable while it is a favourite.
- The only network use is `analyze --fetch-shared` (shared-album previews). Never download
  library originals.
- Fetch by local identifier with `includeAllBurstAssets = true`. The default omits non-picked
  burst frames; that bug broke Dedupe's iPhone tiles.
- **Command-line processes must call `PhotoKitSource.prepareCommandLineProcess()`** before
  requesting images. Without an `NSApplication`, `requestImage` returns nil with no error,
  even for photos stored on the Mac. PhotoKit also delivers image callbacks on the main
  queue, so never block the main thread while waiting for one.
- Image loads never use the network and are asynchronous `.opportunistic` (a synchronous
  request forces full quality and fails for iCloud-only originals). Bump
  `VisionAnalyzer.version` whenever signals change meaning; older rows are re-analyzed.
- Apple data (`import-apple`) is optional and never required by LightboxKit. Photos' face
  `eye_state`: 1 closed, 2 open, 0 unknown. Don't store or use the per-face age, gender or
  appearance guesses osxphotos also exposes.
- To look at photos, render a contact sheet (`lightbox search … --sheet` or `lightbox sheet`)
  and read the JPEG; refer to tiles by their number and resolve them through the `.json` key.
- Local vision models get **one image per message**. qwen3.5:9b saw 2 of 4 images when they
  were sent together. Ask for structured output with Ollama `format` JSON schema and `think: false`.
- macOS 26 deployment target. Gate Foundation Models image input behind `#available(macOS 27, *)`.
- Model weights are never committed; `lightbox models pull` downloads them to Application
  Support, with their licences shown. InsightFace's weights are non-commercial.
- The MCP server is read-only. Nothing that deletes or writes to Photos goes into it until the
  two-step stage/confirm path exists, and then only that.

Public: https://github.com/sameergdogg/lightbox (MIT).
