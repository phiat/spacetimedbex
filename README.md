# Spacetimedbex

[![Hex.pm](https://img.shields.io/hexpm/v/spacetimedbex.svg)](https://hex.pm/packages/spacetimedbex)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/spacetimedbex)
[![Elixir](https://img.shields.io/badge/elixir-~%3E_1.19-blueviolet)](https://elixir-lang.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

SpacetimeDB client library for Elixir.

Connects to [SpacetimeDB](https://spacetimedb.com) via the v2 BSATN binary WebSocket protocol, providing real-time subscriptions, reducer calls, a local ETS-backed client cache, an HTTP REST client, Phoenix PubSub integration, and code generation.

## Features

| Module | Description |
|--------|-------------|
| `Spacetimedbex.BSATN` | Binary codec — encoder, decoder, value encoder |
| `Spacetimedbex.Protocol` | v2 client/server message encoding and decoding |
| `Spacetimedbex.Connection` | WebSocket connection with auto-reconnect and backoff |
| `Spacetimedbex.Schema` | Schema fetcher and parser (tables, reducers, typespace) |
| `Spacetimedbex.ClientCache` | ETS-backed local mirror of subscribed tables |
| `Spacetimedbex.Client` | High-level client with callbacks and auto-encoding |
| `Spacetimedbex.Http` | HTTP REST client for all v1 API endpoints |
| `Spacetimedbex.Phoenix` | Phoenix PubSub adapter for broadcasting events |
| `Spacetimedbex.Codegen` | Code generation from schema |
| `mix spacetimedb.gen` | Mix task to generate structs, reducers, and client |

## Installation

```elixir
# mix.exs
def deps do
  [
    {:spacetimedbex, "~> 0.1.1"}
  ]
end
```

[Documentation](https://hexdocs.pm/spacetimedbex) | [Hex](https://hex.pm/packages/spacetimedbex) | [GitHub](https://github.com/phiat/spacetimedbex)

## Quick Start

### High-Level Client (recommended)

Define a client module with callbacks:

```elixir
defmodule MyApp.SpaceClient do
  use Spacetimedbex.Client

  def config do
    %{
      host: "localhost:3000",
      database: "my_db",
      subscriptions: ["SELECT * FROM users"]
    }
  end

  def on_connect(_identity, _conn_id, token, state) do
    {:ok, Map.put(state, :token, token)}
  end

  def on_insert("users", row, state) do
    IO.puts("New user: #{inspect(row)}")
    {:ok, state}
  end

  def on_update("users", old_row, new_row, state) do
    IO.puts("Updated: #{inspect(old_row)} → #{inspect(new_row)}")
    {:ok, state}
  end

  def on_delete("users", row, state) do
    IO.puts("Removed: #{inspect(row)}")
    {:ok, state}
  end
end
```

Start it and interact:

```elixir
{:ok, pid} = Spacetimedbex.Client.start_link(MyApp.SpaceClient, %{})

# Call a reducer (auto-encodes args via schema)
Spacetimedbex.Client.call_reducer(pid, "create_user", %{"name" => "Alice", "age" => 30})

# Query the local cache
Spacetimedbex.Client.get_all(pid, "users")
Spacetimedbex.Client.find(pid, "users", 1)

# One-off SQL query via WebSocket
Spacetimedbex.Client.query(pid, "SELECT * FROM users WHERE age > 25")

# Unsubscribe from a query set
Spacetimedbex.Client.unsubscribe(pid, query_set_id)
```

### Client Callbacks

All callbacks are optional except `config/0`:

| Callback | When it fires |
|----------|---------------|
| `on_connect(identity, conn_id, token, state)` | Initial connection established |
| `on_subscribe_applied(table, rows, state)` | Subscription data arrives |
| `on_insert(table, row, state)` | Row inserted |
| `on_delete(table, row, state)` | Row deleted |
| `on_update(table, old_row, new_row, state)` | Row replaced (same PK deleted + inserted) |
| `on_transaction(changes, state)` | Full transaction — return `{:ok, state, :skip_row_callbacks}` to suppress per-row callbacks |
| `on_reducer_result(request_id, result, state)` | Reducer completes |
| `on_unsubscribe_applied(query_set_id, rows, state)` | Unsubscribe completes |
| `on_query_result(request_id, result, state)` | One-off query result arrives |
| `on_disconnect(reason, state)` | Disconnected |

### Code Generation

Generate typed structs, reducer functions, and a client skeleton from a live database:

```bash
mix spacetimedb.gen \
  --host localhost:3000 \
  --database my_db \
  --module MyApp.SpacetimeDB \
  --output lib
```

Produces:
- `MyApp.SpacetimeDB.Tables.TableName` — `defstruct` + `@type t` + `from_row/1`
- `MyApp.SpacetimeDB.Reducers` — typed functions with `@spec`
- `MyApp.SpacetimeDB.Client` — `use Spacetimedbex.Client` skeleton with config

### HTTP REST Client

For operations that don't need a persistent WebSocket (identity management, database admin, ad-hoc SQL):

```elixir
alias Spacetimedbex.Http

# Identity
{:ok, %{"identity" => id, "token" => token}} = Http.create_identity("localhost:3000")

# SQL query
{:ok, results} = Http.sql("localhost:3000", "my_db", "SELECT * FROM users", token)

# Call a reducer over HTTP
:ok = Http.call_reducer("localhost:3000", "my_db", "create_user", ["Alice", 30], token)

# Database management
{:ok, _} = Http.publish_database("localhost:3000", "my_db", wasm_binary, token)
{:ok, info} = Http.get_database("localhost:3000", "my_db")
```

### Low-Level Connection

For full control over the WebSocket connection:

```elixir
{:ok, conn} = Spacetimedbex.Connection.start_link(
  host: "localhost:3000",
  database: "my_db",
  handler: self()
)

# Messages arrive as {:spacetimedb, msg} tuples
receive do
  {:spacetimedb, {:identity, identity, conn_id, token}} -> :connected
end

Spacetimedbex.Connection.subscribe(conn, ["SELECT * FROM users"])
Spacetimedbex.Connection.call_reducer(conn, "create_user", bsatn_args)
```

## Architecture

### BSATN Codec

Binary SpacetimeDB Algebraic Type Notation — a compact little-endian binary format:

- Integers: `u8`..`u256`, `i8`..`i256` (little-endian)
- Floats: `f32`, `f64` (IEEE 754, little-endian)
- Strings/Bytes: `u32` length prefix + raw data (UTF-8 validated)
- Arrays: `u32` count prefix + concatenated elements
- Products (structs): fields concatenated in order
- Sums (enums): `u8` variant tag + payload

### Protocol (v2)

Client sends: `Subscribe`, `Unsubscribe`, `OneOffQuery`, `CallReducer`, `CallProcedure`.

Server sends (with 1-byte compression envelope): `InitialConnection`, `SubscribeApplied`, `UnsubscribeApplied`, `SubscriptionError`, `TransactionUpdate`, `OneOffQueryResult`, `ReducerResult`, `ProcedureResult`.

### OTP Design

```
Application
├── Connection (WebSockex) — WebSocket with auto-reconnect
├── ClientCache (GenServer) — ETS-backed row storage
├── Schema — HTTP schema fetch + parse
└── Client (GenServer) — ties it all together with callbacks
```

## Development

```bash
mix deps.get          # Install dependencies
just test             # Unit tests (no server needed)
just test-all         # All tests (requires SpacetimeDB on :3000)
just check            # Compile (strict) + test + credo
just shell            # iex -S mix
```

See `justfile` for all available commands.

## License

MIT
