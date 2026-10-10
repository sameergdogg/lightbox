# lightbox

An open-source toolkit for letting AI look through an Apple Photos library on a Mac.

Ask "find good dating-profile photos of me", "every receipt from 2024" or "which of these five
near-identical shots is the keeper", and lightbox does the cheap part on every photo, the
expensive part only on a shortlist, and hands back grids of photos a model can actually look at.

> Status: L1–L4 work: index (library and shared albums), Vision signals, search, contact sheets, and Photos' own People, scores and captions. See `PLAN.md`.

## What it is

- **LightboxKit**, a Swift package (macOS 26+). It reads the library through PhotoKit, keeps an
  incremental SQLite index, and runs these tiers:
  - Apple Vision signals on every photo: aesthetics, face quality, eyes open, people count,
    sharpness.
  - Image embeddings for search by description.
  - An optional local vision model for judging: Ollama, or Apple's on-device model on
    macOS 27.
- **`lightbox`**, a command-line tool with JSON output. Claude Code and other agents can use it
  straight from a shell.
- **`lightbox-mcp`**, a thin MCP server over the same tools, for chat apps without a shell.

Apps embed LightboxKit directly. The Dedupe Mac app is the first consumer.

## Try it

```sh
swift build
.build/debug/lightbox index          # first run reads the whole library (~17 s for 55k items),
                                     # later runs only what changed since (~0.1 s)
.build/release/lightbox analyze      # Vision signals for every photo with local pixels
                                     # (~150 photos/s on an M4 Max; resumable; build with -c release)
.build/debug/lightbox stats          # what is in the index
.build/debug/lightbox show <uuid>    # one item's metadata and signals as JSON
.build/debug/lightbox doctor         # Photos access, coverage, and what default PhotoKit lookups miss
```

Every command takes `--json`. Use `--db <path>` for an index other than
`~/Library/Application Support/lightbox/index.sqlite`.

`analyze` records, per photo: Vision's aesthetics score and "utility" flag (screenshots,
receipts), sharpness and exposure, a people count, each face with its capture quality, pose and
eye openness, scene labels, and a feature print for similarity. It never downloads from
iCloud. A photo with no local rendition of at least 512 px is marked *waiting for pixels* and
picked up by a later run once its original has downloaded.

The first run asks for Photos access on behalf of your terminal app. Choose *Full Access*.
If you answered no earlier, turn it on in System Settings › Privacy & Security › Photos.

## Search and contact sheets

```sh
lightbox search --people solo --eyes-open --min-face-area 0.03 --min-aesthetic 0.3 \
                --sort aesthetic --distinct 30 --limit 40 --sheet ~/Desktop/portraits.jpg
lightbox search --label beach --label sunset --from 2022 --sheet beach.jpg
lightbox sheet -o picks.jpg <uuid> <uuid> …          # any photos, by local id or UUID
```

A sheet is a grid of up to 20 photos, each tile numbered. A `.json` key next to it maps the
numbers to identifiers. Results past 20 go on extra sheets (`-2`, `-3`, …). `--distinct N`
keeps one photo per N minutes, so results aren't ten frames of one shoot. Filters work only on
analyzed photos; the output says how many aren't analyzed yet.

## Albums and shared albums

```sh
lightbox albums                                   # your albums and iCloud shared ones, with counts
lightbox search --album "Trip" --sheet trip.jpg   # photos in an album (repeatable; all must match)
lightbox search --scope shared                    # only photos from shared albums (also: library, all)
lightbox analyze --fetch-shared                   # download previews of shared photos to analyze them
```

Photos from iCloud shared albums are indexed next to the library and marked as shared. They are
other people's photos and read-only: no lightbox tool will ever offer them for deletion. They
never arrive through "Download Originals", so `analyze` can't see them until you opt in with
`--fetch-shared`, which downloads a preview (a few hundred KB) for each. That is the only
network use in lightbox. Shared photos still get Photos' own scores and captions from
`import-apple` without any download, but Photos runs no face recognition on them, so
`--person` won't match them.

## Photos' own analysis (optional)

```sh
uv tool install osxphotos         # once
lightbox import-apple             # ~30-45 s for 50k photos; re-run any time
                                  # (--library <path> if your library isn't ~/Pictures/Photos Library.photoslibrary)
lightbox people                   # who Photos has named
lightbox search --person "Alex" --alone --eyes-open --sort apple --distinct 60 --sheet alex.jpg
lightbox search --text wedding --from 2023 --sheet wedding.jpg
```

Photos already knows who is in each photo, how good it thinks the photo is (an overall
score and 20+ sub-scores), whether each face's eyes are open, and a one-line caption.
`import-apple` reads that through [osxphotos](https://github.com/RhetTbull/osxphotos)
(read-only) and stores it next to lightbox's own signals. Searches that use it (`--person`,
`--alone`, `--text`, `--min-apple-score`, `--sort apple`) also reach photos whose originals are
still in iCloud. Per-face age and gender guesses are deliberately not imported.

## Faces, people in shared albums, and plain-language search

Photos names people only in your own library; it runs no face recognition on photos from
shared albums. lightbox carries the names over with a face model, calibrated on the faces
Photos has already tagged:

```sh
lightbox models pull arcface                 # InsightFace ArcFace; weights are non-commercial
lightbox faces --fetch-shared                # face vectors for every photo with a face (resumable)
lightbox identify "Your Name" --as me        # gallery from Photos' tags, calibrated on everyone else it named
lightbox search --face me --scope shared --eyes-open --sheet ~/Desktop/me-shared.jpg
```

`identify` holds out half of the tagged faces and reports how many it finds at two
thresholds: *sure* (about 0.1 % of other people's faces would pass) and *maybe* (about 1 %;
add `--maybe` to search with it). A face must also be nearer to the person than to anyone
else Photos has named, which keeps look-alike relatives out.

For search by description, SigLIP 2 (Apache-2.0) puts photos and text in one space:

```sh
lightbox models pull siglip2
lightbox embed                               # an image vector per photo, from small local renditions
lightbox search --about "dinner at a long table outdoors" --distinct 30 --sheet dinner.jpg
lightbox search --about "beach at sunset" --face me --from 2023
```

Every filter combines with `--about`; results come best match first. Model runtimes live in
the `LightboxModels` target, so an app that links only `LightboxKit` ships none of them.

## Claude (MCP)

`lightbox mcp` serves the same searches to Claude over MCP (stdio): `search_photos`,
`show_photo`, `contact_sheet`, `list_people`, `list_albums`, `library_stats`. All read-only.
Results come back as a numbered list plus contact sheets (twenty photos to an image), so Claude
can say "#4 and #11" and ask for a closer look.

```sh
# Claude Desktop: ~/Library/Application Support/Claude/claude_desktop_config.json
"mcpServers": { "lightbox": { "command": "/Users/you/.local/bin/lightbox", "args": ["mcp"] } }
# Claude Code
claude mcp add lightbox -- ~/.local/bin/lightbox mcp
```

`skills/lightbox/SKILL.md` teaches Claude how to use these tools well (start broad, one photo
per moment, compare finalists side by side). For Claude Code, link it into `~/.claude/skills/`;
for Claude Desktop or claude.ai, zip the `skills/lightbox` folder and upload it under
Settings › Capabilities › Skills.

Photos you look at this way are sent to the model provider, unlike everything else lightbox
does, which stays on the Mac. Use the signed install (`LIGHTBOX_SIGN_IDENTITY`) so the server
keeps the Photos access granted to lightbox.

## Install and keep it fresh

```sh
./Scripts/install.sh            # release build into ~/.local/bin
./Scripts/install-agent.sh      # hourly `lightbox refresh` LaunchAgent; --uninstall removes it
```

macOS remembers Photos access per code signature. Set `LIGHTBOX_SIGN_IDENTITY` to a real
signing identity, so the scheduled job keeps its access across reinstalls. The first scheduled
run asks for Photos access for *lightbox* itself. Logs: `~/Library/Logs/lightbox/refresh.log`.

## Design rules

1. **Cheap signals first, models last.** Vision and embeddings run on everything; a vision
   language model runs only on shortlists and close calls.
2. **Contact sheets.** One labelled grid of 12–20 thumbnails is one image in a model's context
   instead of twenty.
3. **Deletion is staged.** `stage` returns a contact sheet of exactly what would go and a token;
   `confirm` runs one PhotoKit delete into Recently Deleted. Favourites are refused, and every
   deletion is logged.
4. **Apple's own analysis is optional enrichment.** Photos already stores aesthetic scores, face
   attributes and People names in its private database. The CLI can import them through
   [osxphotos](https://github.com/RhetTbull/osxphotos) when it is installed. Sandboxed apps
   cannot, and LightboxKit never requires it.
5. **The Photos database is read-only.** Never written, never required.

## License

MIT. Model weights are downloaded separately under their own licences (`lightbox models`
lists them): SigLIP 2 is Apache-2.0; InsightFace's ArcFace weights are for non-commercial
research only, so check the licence before using `faces` and `identify` in anything you sell.
