# Changelog

All notable changes to ObanUI will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial library skeleton: `{ObanUI, ...}` supervisor + `oban_ui_dashboard` router
  macro, served as a Hex-installable Phoenix LiveView dashboard.
- Jobs page with state-tab chips, sortable column headers, partial-match
  worker/queue/tag/node/priority filters, args-path search and time-range
  pickers. URL-synced — every filter and the sort directive round-trip
  through the query string.
- Custom combobox component with server-rendered suggestion dropdowns
  (replaces browser `<datalist>`), substring matching against `ilike`,
  click-to-fill and a per-filter match-count badge.
- Real-time updates over `Oban.Notifier` (Postgres `LISTEN`/`NOTIFY`),
  coalesced into 100 ms ticks per topic to keep broadcast cost flat
  regardless of insert rate.
- Job detail drawer: branched per-attempt timeline, errors with
  stacktrace, args preview through resolver formatting, edit form for
  priority / tags / scheduled_at / max_attempts on non-executing jobs,
  per-job retry / cancel / delete actions and **live process diagnostics**
  for executing jobs (PID, memory, status, stacktrace via `:sys.get_state`
  + `:rpc.call`).
- Bulk actions over the full filtered set with impact preview;
  ≤1000-row sets run synchronously, larger sets dispatch to
  `ObanUI.Jobs.BulkWorker` and broadcast progress.
- Queues overview + per-queue detail with executing/available/scheduled
  counts, throughput sparkline, per-node breakdown, leader info from
  `oban_peers`, and pause / resume / scale / stop controls (local /
  global).
- Dashboard with stacked success/failure/discard chart, 1h/6h/24h/7d
  range picker, top-N worker and queue tallies, rolling success rate.
- Crons read-only view with friendly natural-language descriptions and
  live next-run countdown.
- Multi-instance support: list of named Oban supervisors, instance
  picker in the top bar, `/oban/i/:instance/...` mirror routes.
- Optional Postgres persistence of throughput rollups via
  `mix oban_ui.gen.migration` + `stats: [persist: true]`. Survives BEAM
  restarts; pruned daily via the Stats.Pruner.
- Accessibility: ARIA landmarks, skip-link to main, focus-trapped
  drawer with Escape-to-close, polite live regions for flash, vim-style
  keyboard shortcuts (`/`, `g j/q/c/d`, `Esc`), reconnect banner driven
  by socket events on `<html>`.
- CSP nonce propagation onto the library's `<link>` and `<script>`
  tags via the `csp_nonce_assign_key:` router option.
- Resolver behaviour with `format_job_args/1` + `format_job_meta/1` so
  hosts whose jobs use `:erlang.term_to_binary` can decode args for
  display without changing how they're stored.
- `mix oban_ui.diagnose` task that boots the host app and verifies
  Config / PubSub / Oban / Notifier / oban_jobs / oban_ui_metrics /
  assets. Exits non-zero on failure for use as a release smoke test.
- `ObanUI.Sandbox.allow/3` helper for hosts using
  `Ecto.Adapters.SQL.Sandbox` in tests — round-trips the owner PID
  through the live session so LiveViews see fixture data.

### Out of scope (Pro-only)
- Workflows graph, dynamic crons editor, recorded outputs, smart-engine
  introspection, batches and rate-limiter UI all require Oban Pro and
  are deliberately not implemented here.

[Unreleased]: https://github.com/ariemer/oban_ui/compare/HEAD
