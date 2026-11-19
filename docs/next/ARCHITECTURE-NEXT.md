# SP Drive Next Generation — architecture and API contract

Status: contract frozen 2026-11-19 for the 2.0 upgrade. Canonical copy lives in `sp-drive.git` (`docs/next/`); the
copies in `sp-drive-macos.git` and `sp-drive-ios.git` are mirrors. Exact JSON shapes are finalised by the backend in
`docs/next/API-NEXT.md` on branch `next`; when the two differ, `API-NEXT.md` wins and this file is corrected.

## 1. What does not change

- One Fastify API (`/api/v1`), PostgreSQL 17, filesystem blob store, AES-256-GCM per-object keys wrapped by the master
  key, ClamAV quarantine pipeline, Postgres job queue + worker, PM2 + `mld`, pinned on m5ma:8660.
- WebAuthn passkeys, web sessions (cookie, rotated), device sessions (bearer, sliding), device linking by code.
- Change feed: per-owner `rev`, tombstones, `GET /sync/cursor|changes`, `POST /sync/items`, `baseVersionId` → 409
  `version_conflict`, `asNewFile`.
- Native clients: replicated File Provider extensions, SQLite mirror, operation journal, transfer queue, SHA-256
  verification, non-destructive conflicts. No WebView.
- Encryption is **server-side at rest**. SP Drive is not end-to-end encrypted and nothing may claim it is.

Everything below is **additive**: migration `003_next`, new routes, new optional fields. A 1.0 client keeps working
against a 2.0 server; a 2.0 client reads `GET /api/v1/meta` and hides what an older server lacks.

## 2. Capability discovery

`GET /api/v1/meta` (no auth) → `{ api: 2, version: "2.0.0", features: string[] }`.
Feature names: `events`, `content-search`, `ocr`, `semantic`, `ai`, `collab`, `collections`, `activity`, `storage`,
`similar-images`, `upload-history`. A feature is listed only when it actually works on that server (e.g. `semantic`
only when an embedding backend answered its probe, `ai` only when at least one provider is configured).

Native clients send `X-SPD-Client: <platform>/<app version> (<os version>)`, platform ∈ `macos | ios | ipados`.
The server stores platform and app version on the device session (devices dashboard).

## 3. Sync engine 2.0 (server side)

`GET /api/v1/sync/events` — Server-Sent Events, cookie or bearer.

| event | data | meaning |
|---|---|---|
| `hello` | `{ head }` | sent once on connect |
| `change` | `{ head }` | the owner's head revision advanced (coalesced, at most 1 per second) |
| `notify` | `{ kind }` | a notification was created |
| `: ping` comment | — | every 25 s |

Source: `pg_notify('spd_change', owner_id)` from the existing revision triggers; one LISTEN connection per API process.
A `change` event carries no item: the client then calls `GET /sync/changes?since=<cursor>` exactly as before. **Events
are a hint, never the source of truth**: every client keeps a polling fallback (30 s foreground when the stream is
down, platform-appropriate otherwise) and reconnects with exponential backoff + jitter (1 s → 60 s).

Client side (SPDriveSync on macOS, `Sync/` on iOS) adds, without replacing the engine: event listener, adaptive
transfer concurrency (1–6 by measured throughput and error rate), bandwidth cap, pause/resume, Wi-Fi-only and
cellular policy (iOS), Low Power Mode and battery awareness, priority transfers (user-initiated before background),
retries with exponential backoff, selective sync / folder pinning, crash-safe resume from the journal.

## 4. Search intelligence

Worker job `extract_text` per storage object (after a clean scan): plain text families read directly; PDF text layer;
Office/OpenDocument through the existing sandboxed PDF conversion or XML; **OCR** for images and for PDF pages with no
text layer. Extraction and OCR run locally on the node in the existing `sandbox-exec` sandbox (Apple Vision / PDFKit
helper compiled on the node). No document leaves the node for indexing.

Tables: `object_text (object_id pk, status, source, lang, pages, chars, error, updated_at)`,
`object_passages (object_id, seq, page, text, tsv tsvector, embedding real[] null)`. Passages are plaintext in
PostgreSQL: this is a deliberate, documented trade-off (see SECURITY-REVIEW) and can be switched off with
`SPD_INDEX_CONTENT=off`.

- `GET /api/v1/search` — existing parameters unchanged; new `in=name|content|all` (default `all`). Each hit gains
  `match: { where: 'name'|'content'|'both', snippet?: string, page?: number }`. Snippet marks hits with `⟦ ⟧`.
- `GET /api/v1/search/semantic?q=&limit=` → `{ available, hits: [{ file, score, passage: { text, page } }] }`.
- `GET /api/v1/files/:id/text` → `{ status: 'pending'|'ready'|'empty'|'unsupported'|'failed', source, pages, chars, excerpt }`.
- `GET /api/v1/index/status` → `{ content: { ready, pending, failed, unsupported }, semantic: { available, model, embedded } }`.

Only the caller's own live files (and files reachable through an active grant, §6) are ever returned.

## 5. Document intelligence (optional)

Provider layer `services/api/src/ai/`: `maclustr` (local, OpenAI-compatible, https://llm.spboucher.ai — preferred),
`anthropic`, `openai`, `openrouter`. Keys live in `~/.config/sp-drive/ai.env` on the node, never in git.
External providers are off unless `SPD_AI_EXTERNAL=on` **and** the account has turned on "allow external AI
providers" (`PATCH /api/v1/account { aiExternal: true }`). The local provider needs neither.

- `GET /api/v1/ai/providers` → `{ enabled, externalAllowed, default: { provider, model }, providers: [{ id, label, local, configured, models: [{ id, label, creator }] }] }`.
  `creator` (who made the model) is distinct from `id` of the provider (the API route).
- `POST /api/v1/ai/ask` `{ scope: { fileIds?: [], folderId?, all?: true }, question, provider?, model?, history?: [{ role, content }] }`
  → SSE: `sources` `[{ n, fileId, name, page, text }]`, then `delta` `{ text }`…, then `done` `{ provider, model, usage }`, or `error` `{ code, message }`.
  Retrieval-augmented: passages come from §4. The prompt contains only retrieved passages; the answer cites `[n]`.
  No retrieved passage → `done` with `{ empty: true }` and no model call. A file whose text is not indexed is reported as such.
- `POST /api/v1/ai/suggest` `{ fileIds }` → `{ suggestions: [{ fileId, name?, tags?: [], folder?: { id, path }, category?, reason }] }`.
  Nothing is applied by the server; the client applies with the ordinary endpoints after the user confirms.

## 6. Private sharing and workspaces

`folder_grants (id, folder_id, owner_id, grantee_id, role 'viewer'|'editor'|'uploader', created_at, revoked_at)`,
`folders.workspace_name text null` (a workspace is a shared folder with a name, members and an activity feed).

Owner routes (existing owner-scoped tree is untouched):
- `POST /api/v1/collab/resolve { email }` → `{ userId, displayName }` or 404 (exact match only, rate-limited: no directory enumeration).
- `GET|POST /api/v1/folders/:id/members`, `PATCH|DELETE /api/v1/folders/:id/members/:userId`.
- `GET /api/v1/folders/:id/activity`.

Grantee routes — a separate route family, so tenant isolation of the owner routes holds by construction:
- `GET /api/v1/shared-with-me` → `[{ grantId, role, owner: { displayName }, folder }]`.
- `GET /api/v1/shared/:grantId/children?folderId=`, `GET …/files/:fileId`, `…/files/:fileId/content`, `…/files/:fileId/preview/:kind`.
- editor: `POST …/folders`, `PATCH …/items/:id` (rename, move inside the grant), `POST …/trash`; editor + uploader: `POST …/uploads` (same resumable protocol; bytes count against the owner's quota; same scan pipeline).
- uploader lists nothing; viewer cannot write. Every call re-checks: grant live, caller is the grantee, target inside the granted subtree, not trashed. A failed check answers 404.

Native File Provider domains keep syncing only the account's own tree in 2.0; shared folders are browsed in-app
(documented platform difference).

## 7. Collections, activity, storage, duplicates, versions

- `GET|POST /api/v1/collections`, `PATCH|DELETE /api/v1/collections/:id`, `GET /api/v1/collections/:id/items`.
  Rule: `{ match: 'all'|'any', conditions: [{ field, op, value }], sort? }`; fields `kind, ext, name, tag, untagged,
  size, modified, created, starred, shared, folder, text`; ops `is, isNot, contains, gt, lt, within`. Compiled to
  parameterised SQL from a whitelist. A collection references files; it never copies bytes.
- `GET /api/v1/files/:id/activity`, `GET /api/v1/activity?before=&limit=` — real audit events only (upload, download
  where tracked, rename, move, share, version, restore, trash).
- `GET /api/v1/storage/overview` → quota, used, trash bytes, old-version bytes, counts, `byKind`, `byFolder`,
  `largest`, `growth` (daily, 90 d), `duplicates { groups, reclaimableBytes }`; `GET /api/v1/storage/folder/:id` for drill-down.
- `GET /api/v1/duplicates?mode=exact|similar-images` — exact by SHA-256 (flags "same content, different names");
  similar images by perceptual hash distance. Never deletes anything.
- `GET /api/v1/files/:id/versions`, `GET /api/v1/files/:id/versions/:versionId/content`; restore makes the old content
  the **new current version** and keeps every existing version (audit trail preserved).
- `GET /api/v1/uploads?state=recent` — upload history of the account (transfer centre).

## 8. Administration

`GET /api/v1/admin/system` gains: worker heartbeat, job queue by kind and status, preview/conversion failures,
converter probe, antivirus signature age, backup status (last dump age and size, last restore test, off-node copy
age). Admin only; no control surface for ordinary users.

## 9. Backups

Nightly local backup unchanged (sealed dump + sealed blobs, master key excluded). New: **off-node pull** — another
MacLustr node pulls `~/backups/sp-drive/` over SSH on a schedule, verifies a sample of object hashes against the
manifest, and writes a status file the API reports. The master key is never part of any backup set.

## 10. Clients

| | Web | macOS | iOS / iPadOS |
|---|---|---|---|
| Code | `apps/web` React/Vite | `sp-drive-macos` SwiftUI + AppKit | `sp-drive-ios` SwiftUI + UIKit |
| Shared | `packages/shared` | `SPDriveCore`, `SPDriveSync`, **`SPDriveNext`** | own `Core/`, `Sync/` + **`SPDriveNext`** |

`SPDriveNext` is a new Swift package product in `sp-drive-macos.git` holding the models and calls of every 2.0
endpoint above (events stream, search, AI streaming, collab, collections, activity, storage, duplicates, versions,
meta) behind a small `NextTransport` protocol (base URL + bearer provider + URLSession). Both native apps link it, so
the 2.0 logic exists once. The 1.0 engines (`SPDriveCore`/`SPDriveSync` on macOS, `Core/`+`Sync/` on iOS) stay in
place: merging them is a larger refactor of two validated File Provider stacks and is not part of 2.0.

Design language: `DESIGN-SYSTEM-V2.md` (one token set — colour, type scale, radii, elevation, motion curves and
durations — expressed as CSS variables on the web and as `SPDTheme` in Swift).
