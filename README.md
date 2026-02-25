# Spacetimedbex

SpacetimeDB client library for Elixir.

Connects to [SpacetimeDB](https://spacetimedb.com) via the v2 BSATN binary WebSocket protocol, providing real-time subscriptions, reducer calls, and a local client cache backed by ETS.

## Status

Early development. Core layers are functional, high-level API and tooling are next.

| Layer | Module | Status |
|-------|--------|--------|
| 1 - BSATN Codec | `Spacetimedbex.BSATN` | Done |
| 2 - Protocol Messages | `Spacetimedbex.Protocol` | Done |
| 2 - WebSocket Connection | `Spacetimedbex.Connection` | Done |
| 3 - Schema Parser | `Spacetimedbex.Schema` | Done |
| 3 - Client Cache (ETS) | `Spacetimedbex.ClientCache` | Done |
| 4 - High-level API | `Spacetimedbex` | Planned |
| - - Code Generation | `mix spacetimedb.gen` | Planned |
| - - HTTP API | `Spacetimedbex.HTTP` | Planned |

## Quick Start

```elixir
# Start a connection
{:ok, conn} = Spacetimedbex.Connection.start_link(
  host: "localhost:3000",
  database: "my_db",
  handler: self()
)

# You'll receive identity on connect
receive do
  {:spacetimedb, {:identity, identity, conn_id, token}} -> :ok
end

# Subscribe to tables
Spacetimedbex.Connection.subscribe(conn, ["SELECT * FROM users"])

# Call a reducer
Spacetimedbex.Connection.call_reducer(conn, "create_user", args_bsatn)

# Or use the ClientCache for automatic ETS-backed table mirroring
{:ok, cache} = Spacetimedbex.ClientCache.start_link(
  host: "localhost:3000",
  database: "my_db"
)

Spacetimedbex.ClientCache.get_all(cache, "users")
Spacetimedbex.ClientCache.find(cache, "users", 1)
```

## Installation

```elixir
# mix.exs
def deps do
  [
    {:spacetimedbex, git: "https://your-repo/spacetimedbex.git"}
  ]
end
```

## Architecture

### BSATN Codec

Binary SpacetimeDB Algebraic Type Notation — a compact little-endian binary format:

- Integers: `u8`..`u256`, `i8`..`i256` (little-endian)
- Floats: `f32`, `f64` (IEEE 754, little-endian)
- Strings/Bytes: `u32` length prefix + raw data (UTF-8 validated)
- Arrays: `u32` count prefix + concatenated elements
- Products (structs): fields concatenated in order, no framing
- Sums (enums): `u8` variant tag + payload

### Protocol (v2)

Client sends 5 message types: `Subscribe`, `Unsubscribe`, `OneOffQuery`, `CallReducer`, `CallProcedure`.

Server sends 8 message types with a 1-byte compression envelope (none/brotli/gzip): `InitialConnection`, `SubscribeApplied`, `UnsubscribeApplied`, `SubscriptionError`, `TransactionUpdate`, `OneOffQueryResult`, `ReducerResult`, `ProcedureResult`.

### OTP Design

- `Spacetimedbex.Connection` — WebSockex-based WebSocket connection with auto-reconnect, configurable backoff, and request ID tracking
- `Spacetimedbex.Schema` — Fetches and parses module schema (tables, reducers, typespace) via HTTP
- `Spacetimedbex.ClientCache` — ETS-backed local mirror of subscribed tables with row decoding
- `Spacetimedbex.ClientCache.RowDecoder` — Decodes BSATN row data into Elixir maps using schema

## Development

```bash
# Install dependencies
mix deps.get

# Run unit tests
just test

# Run all tests (requires SpacetimeDB on :3000)
just test-all

# Full quality check (compile + test + credo)
just check

# Build & publish test WASM module
just publish-test-module

# Interactive shell
just shell
```

See `justfile` for all available commands.

## License

MIT
