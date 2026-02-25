# Spacetimedbex

SpacetimeDB client library for Elixir.

Connects to [SpacetimeDB](https://spacetimedb.com) via the v2 BSATN binary WebSocket protocol, providing real-time subscriptions, reducer calls, and a local client cache backed by ETS.

## Status

Early development. The following layers are planned:

| Layer | Module | Status |
|-------|--------|--------|
| 1 - BSATN Codec | `Spacetimedbex.BSATN` | Done |
| 2 - Protocol Messages | `Spacetimedbex.Protocol` | Done |
| 2 - WebSocket Connection | `Spacetimedbex.Connection` | Planned |
| 3 - Client Cache (ETS) | `Spacetimedbex.ClientCache` | Planned |
| 4 - High-level API | `Spacetimedbex` | Planned |
| - - Code Generation | `mix spacetimedb.gen` | Planned |
| - - HTTP API | `Spacetimedbex.HTTP` | Planned |

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
- Strings/Bytes: `u32` length prefix + raw data
- Arrays: `u32` count prefix + concatenated elements
- Products (structs): fields concatenated in order, no framing
- Sums (enums): `u8` variant tag + payload

### Protocol (v2)

Client sends 5 message types: `Subscribe`, `Unsubscribe`, `OneOffQuery`, `CallReducer`, `CallProcedure`.

Server sends 8 message types with a 1-byte compression envelope (none/brotli/gzip): `InitialConnection`, `SubscribeApplied`, `UnsubscribeApplied`, `SubscriptionError`, `TransactionUpdate`, `OneOffQueryResult`, `ReducerResult`, `ProcedureResult`.

### OTP Design

- `Spacetimedbex.Connection` — GenServer managing the WebSocket lifecycle
- `Spacetimedbex.ClientCache` — ETS-backed local mirror of subscribed tables
- `Spacetimedbex.Subscription` — query set management and delta application
- Callbacks via behaviours or Phoenix.PubSub

## Development

```bash
mix deps.get
mix test
mix credo
```

## License

MIT
