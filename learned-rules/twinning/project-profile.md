---
slug: twinning
generated_at: 2026-04-29T00:00:00Z
generated_by: discovery-agent
schema_version: 1
---

# Project profile — Twinning

## Stack

Twinning is a desktop application built on Tauri v2 + SvelteKit (Svelte 5) + TypeScript on the frontend and a Rust workspace on the backend. Package manager is `bun` for JS/TS; `cargo` drives the Rust workspace under `Cargo.toml` (workspace = `[src-tauri, crates/twinning-core, twinning-ai, twinning-providers, twinning-storage, twinning-pipeline, twinning-graph, twinning-cli, twinning-agent]`). Type-checking on the SvelteKit side runs through `svelte-check` against `tsconfig.json`. Tests use `cargo test` for Rust and Playwright for end-to-end. Releases are semantic-release driven from `.github/workflows/release.yml`. Tauri commands cross the FE/BE boundary; macOS keychain integration uses `keyring`.

## Build & test gates

- Build: `bun run build` *(Vite production bundle; CI runs this before Tauri packaging)*
- Test: `cargo test --workspace` *(unit + integration across all Rust crates)*
- Lint/check: `bun run check && bun run lint && cargo clippy --workspace -- -D warnings && cargo fmt --all -- --check`
- Integration/E2E: `bunx playwright test --project=e2e` *(smoke variant: `bunx playwright test --project=smoke`)*

## File layout

- `src/` — SvelteKit frontend (`routes/`, `lib/`, `app.html`, `app.css`).
- `src-tauri/` — Tauri shell crate: `src/`, `build.rs`, `capabilities/`, `gen/`, `icons/`, `Entitlements.plist`. The Rust app entry point lives here.
- `crates/` — workspace crates: `twinning-core`, `twinning-ai`, `twinning-providers`, `twinning-storage`, `twinning-pipeline`, `twinning-graph`, `twinning-cli`, `twinning-agent`.
- `docs/` — architecture docs (notably `docs/architecture/SYSTEM_ARCHITECTURE.md`), `docs/UX_PRINCIPLES.md`, `docs/knowledge/{gotchas,decisions,conventions}.md`, plus `docs/brainstorms/` and `docs/plans/` consumed by the harness.
- `tests/` and `e2e/` — Playwright specs.
- `static/` — SvelteKit static assets bundled into the Tauri app.

## Language idioms

- Svelte 5 runes (`$state`, `$derived`, `$effect`) for reactive state; do NOT introduce Svelte 4 stores in new code.
- Tauri commands are declared via `#[tauri::command] async fn cmd_x(...) -> Result<T, AppError>` and called from TS via `import { invoke } from '@tauri-apps/api/core'`. The plan's `api-contract` block is the source of truth for arg names/types.
- Rust workspace: each crate's tests are inline `#[cfg(test)] mod tests { ... }` grouped by nested mods; test names describe condition + expected result, no `test_` prefix.
- Storage tests use `SqliteStorageAdapter::new(":memory:")`.
- LLM clients are tested via manual trait doubles for `CompletionClient` and `Tool` traits — do not use mocking macros.
- `serde`/`serde_json` are the workspace defaults; types crossing the FE/BE boundary derive `Serialize, Deserialize`.
- Errors flow via `thiserror` enums per crate and bubble up to the Tauri command surface as `Result<_, AppError>`.

## Don'ts

- Don't put business logic in `src-tauri/src/` outside the thin Tauri command layer — domain code lives in `crates/twinning-*`.
- Don't bypass the workspace `Cargo.toml` resolver — every crate is `resolver = "2"` and pulls deps via `[workspace.dependencies]`.
- Don't disable `cargo clippy --workspace -- -D warnings` or `cargo fmt --check` in PR builds; CI gates on them.
- Don't write Svelte 4-style `<script>` blocks in new components — use Svelte 5 runes throughout.
- Don't introduce `localStorage` for any state that should persist across reinstalls; use the storage crate (sqlite via the `keyring`-protected key bundle).
- Don't add a TS file under `src/` without a matching `svelte-check` clean run; type errors silently break the dev loop.
- Don't commit secrets or local config — `config.local` and `.env*` are gitignored for a reason.
