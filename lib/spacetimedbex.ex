defmodule Spacetimedbex do
  @moduledoc """
  SpacetimeDB client library for Elixir.

  Provides WebSocket-based real-time connectivity to SpacetimeDB databases
  using the v2 BSATN binary protocol.

  ## Getting Started

  The main entry point is `Spacetimedbex.Client` — a GenServer that manages
  a WebSocket connection, local ETS cache, and schema-driven encoding:

      defmodule MyApp.SpaceClient do
        use Spacetimedbex.Client

        def config do
          %{
            host: "localhost:3000",
            database: "my_db",
            subscriptions: ["SELECT * FROM users"]
          }
        end

        def on_insert("users", row, state) do
          IO.puts("New user: \#{inspect(row)}")
          {:ok, state}
        end
      end

      {:ok, pid} = Spacetimedbex.Client.start_link(MyApp.SpaceClient, %{})

  ## Module Overview

  - **`Spacetimedbex.Client`** — High-level client with callbacks
  - **`Spacetimedbex.Http`** — HTTP REST client for all v1 API endpoints
  - **`Spacetimedbex.Connection`** — Low-level WebSocket connection
  - **`Spacetimedbex.ClientCache`** — ETS-backed local table mirror
  - **`Spacetimedbex.Schema`** — Schema fetcher and parser
  - **`Spacetimedbex.Phoenix`** — Phoenix PubSub integration
  - **`Spacetimedbex.Codegen`** — Code generation from schema
  - **`Spacetimedbex.BSATN`** — Binary codec (encoder/decoder)
  - **`Spacetimedbex.Protocol`** — v2 message encoding/decoding

  ## Code Generation

  Generate typed Elixir modules from a live database:

      mix spacetimedb.gen --host localhost:3000 --database my_db --module MyApp.SpacetimeDB
  """
end
