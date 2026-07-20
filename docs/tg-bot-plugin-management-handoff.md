# Telegram plugin management handoff

Date: 2026-07-21

## Current state

The implementation is feature-complete. The owner requested that further full
regression and read-only security review stop after the recorded checks, then
authorized direct delivery to the `beta` branch on 2026-07-21.

The Telegram bot is now an allowlisted private-chat plugin-management surface
over the same in-process managers used by the Web Console. Implemented flows:

- marketplace source add, refresh, removal, pagination, and entry review;
- marketplace installation with marketplace/module revisions plus normalized
  source and candidate snapshot proofs;
- HTTPS URL and pasted local YAML installation;
- installed-plugin detail, enable, disable, uninstall, update check/apply,
  execution reorder, and operator egress binding;
- all typed settings (`text`, `select`, `boolean`, `number`, and `location`);
- Telegram location input or manual `longitude,latitude,accuracy`, followed by
  a protected Telegram map preview;
- MITM master, HTTP/2, and QUIC fallback controls;
- complete action match/execution metadata, typed-setting schema/value,
  capture-host, mapping, storage, egress, and exact network-origin review;
- protected HTML review documents for long reviews; and
- mutation audit entries without logging settings, manifests, or tokens.

Every mutation uses a short-lived one-use confirmation bound to the
administrator, exact private chat, operation kind and payload, monotonic owner
operation generation, current CAS revision, and applicable installed/source/
candidate digests. Retired `b1:module:*` callbacks are no longer actionable.

## Concurrency and failure boundaries

- New navigation or `/cancel` advances the owner generation and cancels the
  previous preview context.
- Operation generations are process-wide monotonic values, so pruning cannot
  create an ABA reuse.
- Telegram-triggered remote fetches are limited to two process-wide; review
  rendering is limited to one process-wide.
- Preview operations have a two-minute total timeout.
- Review chunks and the final confirmation control are serialized; a
  confirmation is issued only after every inline chunk or the protected review
  document is delivered.
- Marketplace installation keeps the reviewed marketplace source locked
  through the module CAS commit, using the fixed marketplace-to-module order.
- Install and update apply always leave the resulting plugin disabled.
- Missing Telegram horizontal accuracy is stored conservatively as 100000
  metres rather than inventing precision.

## Manager and API projection changes

- `Controller` now exposes the marketplace and extension lifecycle needed by
  Telegram, including strict preview/expected-apply methods.
- Direct import, marketplace add/refresh, and marketplace install refetch or
  reparse on confirmation and reject changed expected proofs.
- Marketplace sources expose `snapshot_digest`, which covers the local display
  label, configured/final URLs, and normalized contents while excluding only
  fetch time.
- Installed/candidate module views expose action review metadata without script
  bodies. Exact stored bodies remain available through the authenticated
  snapshot endpoint.

## Verification completed before the pause

- Focused Go tests for Telegram state, callbacks, marketplace/install proofs,
  settings, location, cancellation/ABA, concurrency bounds, update disabled
  state, and controller preview/expected seams passed.
- `go vet ./...` passed.
- All Go tests except `TestPolicyManagerDeleteRollsBackOnSaveFailure` passed
  when that Windows-specific permission-semantics test was skipped.
- Web TypeScript typecheck passed.
- All 31 Vitest files / 260 tests passed.
- Web production build, PWA policy, and bundle budgets passed.
- The live official marketplace index previously passed the core strict parser
  and contained eight entries.
- Two read-only security review passes reported no remaining P0-P2 findings at
  their review points.

## Work performed after the last broad verification

The following final hardening edits were made after some of the broad checks
above and intentionally have not been re-run under the owner's pause request:

- operation guard stale-start/double-check handling and cancellation ordering;
- render/fetch semaphores and the two-minute preview/apply timeout;
- protected-review size bound raised to 32 MiB;
- full action and typed-setting schema rendering;
- exact marketplace local/remote display-name projection;
- conservative missing-location accuracy;
- update-candidate execution-order projection;
- marketplace-to-module commit-window locking and its concurrency test; and
- maintenance-confirmation revocation when an administrator is removed.

## Deferred follow-up checklist

1. Read `AGENTS.md`, `docs/architecture.md`, `MEMORY.md`, and this handoff.
2. Verify the delivered `beta` commit and preserve the architecture documented
   here when making follow-up changes.
3. If the owner re-authorizes it, run the broader Go and Web regression gates.
4. On Linux/CGO, run the required Go race tests. The current Windows session
   had `CGO_ENABLED=0`, so `-race` was unavailable.
5. Treat `TestPolicyManagerDeleteRollsBackOnSaveFailure` as a Windows filesystem
   semantics limitation unless it also fails on Linux.
6. Do not commit `web/dist`; it was generated only for verification.

## Primary implementation files

- `cmd/5gpn-dns/bot_extensions.go`
- `cmd/5gpn-dns/bot_extensions_flow.go`
- `cmd/5gpn-dns/bot_extensions_modules.go`
- `cmd/5gpn-dns/bot_extension_state.go`
- `cmd/5gpn-dns/bot_extension_values.go`
- `cmd/5gpn-dns/bot_extension_operations.go`
- `cmd/5gpn-dns/controller.go`
- `cmd/5gpn-dns/intercept_module_manager.go`
- `cmd/5gpn-dns/extension_marketplace.go`
- `docs/architecture.md`
- `MEMORY.md`
