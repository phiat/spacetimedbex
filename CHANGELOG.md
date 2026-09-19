# Changelog

## v0.2.0 (2026-09-19)

Tested against SpacetimeDB 2.10.1. The v2 WebSocket wire format is unchanged since 2.0.

### Breaking changes

- `Client.call_reducer/3`, `call_reducer_raw/3`, `call_procedure_raw/3` and `query/2` return
  `{:ok, request_id}` instead of `:ok`. The id matches the `request_id` passed to
  `on_reducer_result/3`, `on_procedure_result/3` and `on_query_result/3`.
- `Client.unsubscribe/3` returns `{:error, :unknown_query_set}` for inactive query sets, and
  requests the dropped rows by default (`send_dropped_rows: true`).
- Special types decode to Elixir-friendly values everywhere (rows, `on_connect/4`, protocol
  structs). See `Spacetimedbex.Types`:
  - `Identity` / `ConnectionId`: lowercase hex strings. Previously rows held
    `%{"__identity__" => integer}` and `on_connect/4` received raw 32/16-byte binaries.
  - `Timestamp`: `DateTime` (including `ReducerResult`/`ProcedureResult` timestamps).
  - `TimeDuration`: `Duration`.
  - `Uuid`: UUID strings.
  Encoding accepts both the new forms and the old ones.
- Schema column types for those special types are now `:identity`, `:connection_id`,
  `:timestamp`, `:time_duration` and `:uuid`, instead of single-field products.
- The client cache is ref-counted, like the official SDKs. Row callbacks and
  `on_transaction/2` changes reflect rows that actually entered or left the cache. A row
  covered by several queries fires `on_insert`/`on_delete` once.
- If `on_update/4` is not implemented, row updates fire `on_delete/3` then `on_insert/3`.
  Before, updates were silently dropped, including by `Spacetimedbex.Phoenix`.
- `on_unsubscribe_applied/3` receives decoded rows (`[%{table_name: t, rows: [row]}]`);
  `on_transaction/2` changes include an `:events` key.
- `Client` owns its cache directly and no longer starts a `ClientCache` process.
  `ClientCache.apply_changes/2` is now synchronous and returns the effective changes.
- `Connection.start_link/1` returns `{:error, {:unsupported_compression, :brotli}}`, because
  brotli frames could never be decoded.
- `Http` functions send no `Authorization` header for a `nil` token, and treat any 2xx as
  success.
- Removed the direct `jason` dependency.

### Added

- `Client.subscribe/2` returns `{:ok, query_set_id}`. Active query sets keep their ids across
  automatic reconnects. `Client.subscriptions/1` lists them.
- `on_subscription_error/3` callback.
- Procedures: `Connection.call_procedure/4`, `Client.call_procedure_raw/3`,
  `on_procedure_result/3` and `Http.call_procedure/5`.
- TLS: pass `host: "https://..."` to use `https://` and `wss://` (e.g. Maincloud).
- Sum (enum) and map column types, in both decoding and encoding.
- Event-table rows are surfaced through `on_insert/3` and never cached.
- `Http.sql/4` results include `:total_duration_micros` and `:stats`.
- `Connection` functions accept caller-chosen `request_id:` / `query_set_id:` options.

### Fixed

- Any table with an enum column, including `ScheduleAt` on scheduled tables, crashed the cache.
- Tables without a primary key cached only one row.
- Out-of-range integer arguments raised inside the client process or silently wrapped. They
  now return `{:error, {:out_of_range, type, value}}`.
- Reducers with custom-type parameters could not be called: typespace refs in params were
  never resolved.
- Inline sums with more than two variants parsed as unknown types.
- Reconnects presented the original token, so anonymous clients got a new identity. The
  cache also kept stale rows across a reconnect.
- Optional callbacks could go undetected when the callback module was not yet loaded.
- Generated reducer functions with camelCase parameters did not compile. Generated typespecs
  now match decoded values.
- Rows were decoded twice per message.

### Dependencies

- `req` `~> 0.5 or ~> 0.6 or ~> 0.7`

## v0.1.2 (2026-04-29)

- HTTP route fixes for SpacetimeDB v2.0+ compatibility.

## v0.1.1 (2026-02-25)

- README badges and install instructions.

## v0.1.0

- Initial release.
