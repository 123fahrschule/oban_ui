# Feature parity with `oban_web`

This document tracks ObanUI's coverage of every feature in the `oban_web`
package. Pro-only features are listed for completeness but explicitly
out-of-scope for ObanUI's open-source effort.

Legend: ✅ shipped · 🟡 partial / planned · ❌ out of scope · 🚫 not
applicable

## Jobs

| Feature | Status | Notes |
|---|---|---|
| Jobs list | ✅ | URL-synced filters, sort, pagination |
| State filter | ✅ | State-tab chips with live counts per state |
| Queue filter | ✅ | Substring (`ILIKE '%v%'`) |
| Worker filter | ✅ | Substring with combobox suggestions |
| Tag filter | ✅ | Postgres array overlap |
| Node filter | ✅ | `attempted_by` array contains-any |
| Priority filter | ✅ | 0–9 multi-value |
| Args path search | ✅ | `args.path:value` syntax → JSONB |
| Time-range filter | ✅ | `datetime-local` inserts |
| Sortable columns | ✅ | ID, state, queue, worker, priority, inserted_at |
| Cursor pagination | ✅ | Load-more button, paused live refresh on later pages |
| Live match count | ✅ | "Showing N matching jobs" above table |
| Per-filter count badges | ✅ | Shows restrictiveness of each active filter |
| Args preview column | ✅ | 80-char truncated, full args in drawer |
| Auto-complete suggestions | ✅ | Server-rendered combobox |
| Bulk select-all on visible page | ✅ | Tri-state indicator |
| Bulk action across whole filter | ✅ | Impact preview, sync ≤1000 / async worker |
| Single-job retry / cancel / delete | ✅ | Capability-gated |
| Bulk retry / cancel / delete | ✅ | With audit telemetry |
| Edit job (priority/tags/scheduled/max_attempts) | ✅ | Non-executing states only |
| Edit args / meta | ❌ | Hosts with `:erlang.term_to_binary` can't round-trip; see Resolver hook |

## Job detail drawer

| Feature | Status | Notes |
|---|---|---|
| Identity (id / worker / queue / state / attempt) | ✅ | |
| Branched per-attempt timeline | ✅ | SVG, hover for exact event timestamps, legend |
| Args display | ✅ | Through `resolver.format_job_args/1` |
| Meta display | ✅ | Through `resolver.format_job_meta/1` |
| Errors with stacktrace | ✅ | One block per attempt |
| Run-once / Edit | ✅ | Edit form for safe fields |
| Live process diagnostics | ✅ | PID, memory, status, current_stacktrace via `:sys.get_state` + `:rpc` — OSS-only |
| Recorded outputs | ❌ | Requires `Oban.Pro.Worker` |

## Queues

| Feature | Status | Notes |
|---|---|---|
| Queues list | ✅ | Cards with state counts + sparkline |
| Throughput sparkline | ✅ | 5-minute window per queue |
| Pause / Resume | ✅ | Local/global scope toggle |
| Scale concurrency | ✅ | Inline number input |
| Stop queue | ✅ | Drains running jobs |
| Per-node breakdown | ✅ | Read from `oban_jobs.attempted_by` |
| Leader info | ✅ | Reads `oban_peers`, surfaces stale lease |
| Queue detail page | ✅ | Per-queue throughput + node table |
| Partitioning controls | ❌ | Smart-engine only |
| Rate-limiter visualisation | ❌ | Smart-engine only |
| Global-concurrency anzeige | ❌ | Smart-engine only |

## Dashboard

| Feature | Status | Notes |
|---|---|---|
| State counts cards | ✅ | One per state |
| Throughput chart | ✅ | Stacked success/failure/discard, SVG |
| Range picker (1h / 6h / 24h / 7d) | ✅ | URL-synced |
| Success-rate gauge | ✅ | Rolling over the active window |
| Top workers | ✅ | Top-5 by executions in window |
| Top queues | ✅ | Top-5 by executions in window |
| Error timeline / heatmap | 🟡 | Falls back to single discard line on the throughput chart |
| Per-node summaries | 🟡 | Only on queue-detail, not as a dashboard widget |

## Crons

| Feature | Status | Notes |
|---|---|---|
| Static crons list | ✅ | Reads `Oban.Plugins.Cron` config |
| Natural-language description | ✅ | Local parser, no external lib |
| Next-run countdown | ✅ | Live-recomputed minute-aligned |
| Last-run timestamp | ✅ | From `oban_jobs.attempted_at` |
| Create / Edit dynamic crons | ❌ | Requires `Oban.Pro.Plugins.DynamicCron` |
| Pause / Resume dynamic crons | ❌ | Same |

## Plumbing

| Feature | Status | Notes |
|---|---|---|
| Mount via router macro | ✅ | `oban_ui_dashboard "/oban", ...` |
| Hex-shipped pre-built assets | ✅ | No Tailwind/esbuild in host |
| CSP-nonce on `<script>` / `<link>` | ✅ | `csp_nonce_assign_key:` option |
| Resolver-based auth | ✅ | `resolve_user/1`, `resolve_access/1` (per-action capabilities) |
| Resolver args/meta formatting | ✅ | `format_job_args/1`, `format_job_meta/1` |
| Multi-instance support | ✅ | `oban_names:`, picker in topbar, `/i/:instance/...` mirror routes |
| Real-time via `Oban.Notifier` | ✅ | Postgres `LISTEN`/`NOTIFY`, coalesced to 100ms ticks |
| Audit telemetry | ✅ | `[:oban_ui, :action]` for every operator change |
| Persistent stats (opt-in) | ✅ | `mix oban_ui.gen.migration` + `stats: [persist: true]` |
| `mix oban_ui.diagnose` task | ✅ | Verifies installation end-to-end |
| `ObanUI.Sandbox` helper | ✅ | Host tests through `Ecto.Adapters.SQL.Sandbox` |
| Theme: dark mode | ✅ | System / light / dark, persisted in `localStorage` |
| A11y: keyboard nav | ✅ | `/` focus filter, `g j/q/c/d` go-to, `Esc` close drawer |
| A11y: focus-trap drawer | ✅ | `role="dialog" aria-modal="true"` + JS hook |
| A11y: skip-link | ✅ | Visible on focus |
| A11y: live-region flash | ✅ | `aria-live="polite"` |
| Connectivity banner | ✅ | Toggled by socket `onError`/`onOpen` |

## Plugins / advanced

| Feature | Status | Notes |
|---|---|---|
| Workflows graph | ❌ | Requires `Oban.Pro.Workflow` |
| Batches view | ❌ | Requires `Oban.Pro.Batch` |
| Lifeline view | 🟡 | Surfaced as a regular executing-job with diagnostics |
| Reindexer status | ❌ | Plugin-specific, no UI |
| Inspect supervised-by | 🟡 | Available via diagnostics' `current_function` |
