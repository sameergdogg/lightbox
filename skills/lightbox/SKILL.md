---
name: lightbox
description: Search and look through the user's Apple Photos library on their Mac with lightbox, including photos from iCloud shared albums. Use when the user asks to find, pick, compare or count their photos — e.g. "photos of me at the beach", "my best photos from the trip", "photos of me in shared albums", "which of these is sharpest". Works through the lightbox MCP tools (search_photos, show_photo, contact_sheet, list_people, list_albums, library_stats) or, in a terminal, the `lightbox` CLI.
---

# Working with a Photos library through lightbox

lightbox indexes the user's Apple Photos library on their Mac: dates, places, albums, People
names from Photos, Apple Vision signals (faces, eyes, sharpness, aesthetics, scene labels),
face identities that also cover shared albums, and image vectors for search by description.
Everything is read-only. Nothing you do through lightbox deletes, edits or moves a photo.

## Tools (MCP) and their CLI equivalents

| Tool | CLI | Use it to |
|---|---|---|
| `search_photos` | `lightbox search … --sheet out.jpg` | find photos; returns a numbered list and contact sheets |
| `show_photo` | `lightbox show <id>` | look closely at one photo, with everything known about it |
| `contact_sheet` | `lightbox sheet -o out.jpg <ids…>` | put a shortlist side by side (2–3 columns to compare) |
| `list_people` | `lightbox people` | People names from Photos, and identities recognised by face |
| `list_albums` | `lightbox albums` | the user's albums and the shared albums they belong to |
| `library_stats` | `lightbox stats` | what is indexed, analysed, face-scanned and embedded |

In a terminal, write sheets to a temporary folder and read the JPEG; its `.json` key maps tile
numbers to photo ids. Delete sheets when you are done.

## How to search well

- **Start broad, then narrow.** One `search_photos` call with the obvious filters, look at the
  sheet, then tighten (eyes open, solo, a minimum face size or aesthetic score) rather than
  guessing every filter up front.
- **People:** `faces: ["me"]` (or another identity from `list_people`) recognises a person by
  face, in the library *and* in shared albums. `people: ["Name"]` uses Photos' own People tags,
  which cover the library only and are often incomplete for recent years. Prefer `faces` when an
  identity exists; add `include_maybe_faces` only when recall matters more than precision.
- **Descriptions:** `about: "dinner at a long table outdoors"` ranks by meaning. Combine it with
  any filter (`faces`, `scope`, dates). Short, concrete descriptions work best.
- **Shared albums:** `scope: "shared"` searches photos other people shared with the user;
  `scope: "library"` only the user's own. Results mark shared photos.
- **One per moment:** use `distinct_minutes` (e.g. 30) so a burst or a shoot doesn't fill the
  sheet with near-identical frames.
- **Quality filters that work:** `eyes_open`, `group_size: "solo"`, `min_face_area` (0.03 for a
  portrait, 0.15 for a close-up), `min_aesthetic` (0.3 decent, 0.6 strong). Leave `include_utility`
  off unless the user wants screenshots or documents.
- Page with `offset` instead of asking for huge limits; 20–40 per call keeps sheets readable.

## Reading results

- Every result has a number (`#7`) that matches its tile on the contact sheet. Refer to photos by
  number when talking to the user, and keep the id to call `show_photo`.
- Captions under tiles: date, `A` Photos' aesthetic score, `a` Vision aesthetics, `q` best face
  quality, `e` the least-open eye (under 0.15 means someone blinked), `r` match to `about`.
- If a result line says some photos aren't analysed or embedded yet, say so: the answer may be
  incomplete until lightbox's next refresh.

## Picking "the best"

Judge photographs, not people: focus, open eyes, expression, light, framing, whether the
subject is the clear centre, and whether the moment reads. Shortlist with a sheet, then compare
two to four finalists with `contact_sheet` at 2 columns, and explain the choice in those terms.
Don't guess or comment on anyone's age, gender, body or other personal traits.

## Privacy

Photos you look at are sent to the model to be seen. Look at what the task needs, don't copy
images or ids anywhere else, and don't describe other people in the photos beyond what the user
asked about.
