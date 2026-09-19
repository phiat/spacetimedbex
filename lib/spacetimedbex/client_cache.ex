defmodule Spacetimedbex.ClientCache do
  @moduledoc """
  ETS-backed local cache of subscribed SpacetimeDB tables.

  Maintains a mirror of server state by processing subscription and
  transaction update events from a `Spacetimedbex.Connection`.

  ## Usage

      {:ok, cache} = Spacetimedbex.ClientCache.start_link(
        host: "localhost:3000",
        database: "testmodule"
      )

      # After connection subscribes and events flow in:
      Spacetimedbex.ClientCache.get_all(cache, "person")
      Spacetimedbex.ClientCache.find(cache, "person", 1)
      Spacetimedbex.ClientCache.count(cache, "person")
  """

  use GenServer

  require Logger

  alias Spacetimedbex.ClientCache.{RowDecoder, Store}
  alias Spacetimedbex.Protocol.ServerMessage.TransactionUpdate
  alias Spacetimedbex.Schema

  defstruct [:schema, :store, :handler]

  @type t :: %__MODULE__{
          schema: Schema.t() | nil,
          store: struct(),
          handler: pid() | nil
        }

  # --- Public API ---

  @doc """
  Start the client cache.

  ## Options
  - `:host` - SpacetimeDB host (for schema fetch). Required unless `:schema` given.
  - `:database` - Database name. Required unless `:schema` given.
  - `:schema` - Optional pre-parsed `%Schema{}`. Skips HTTP fetch when provided.
  - `:handler` - Optional PID to forward `{:cache_event, event}` notifications.
  - `:name` - Optional process name.
  """
  def start_link(opts) do
    name_opt = if opts[:name], do: [name: opts[:name]], else: []
    GenServer.start_link(__MODULE__, opts, name_opt)
  end

  @doc "Get all rows from a cached table as a list of maps."
  def get_all(cache, table_name) do
    GenServer.call(cache, {:get_all, table_name})
  end

  @doc """
  Find a row by primary key value (a tuple for composite keys).

  Tables without a primary key are keyed by the full row map.
  """
  def find(cache, table_name, pk_value) do
    GenServer.call(cache, {:find, table_name, pk_value})
  end

  @doc "Count rows in a cached table."
  def count(cache, table_name) do
    GenServer.call(cache, {:count, table_name})
  end

  @doc "Get the parsed schema."
  def schema(cache) do
    GenServer.call(cache, :schema)
  end

  @doc """
  Process a raw SpacetimeDB event (as delivered by `Spacetimedbex.Connection`),
  decoding rows with the cache's schema.
  """
  def handle_event(cache, event) do
    GenServer.cast(cache, {:event, event})
  end

  @doc """
  Apply already-decoded changes, as produced by
  `Spacetimedbex.ClientCache.RowDecoder.decode_query_sets/2`.

  Rows are ref-counted across overlapping queries and query sets, the same
  way the official SDKs do it. The return value holds only the effective
  changes: rows that entered or left the cache (plus any event rows).
  """
  @spec apply_changes(GenServer.server(), [RowDecoder.table_changes()]) :: [
          RowDecoder.table_changes()
        ]
  def apply_changes(cache, changes) when is_list(changes) do
    GenServer.call(cache, {:apply, changes})
  end

  @doc "Remove all cached rows (e.g. after a disconnect)."
  def clear(cache) do
    GenServer.cast(cache, :clear)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    handler = Keyword.get(opts, :handler)

    schema_result =
      case Keyword.get(opts, :schema) do
        %Schema{} = schema -> {:ok, schema}
        nil -> Schema.fetch(Keyword.fetch!(opts, :host), Keyword.fetch!(opts, :database))
      end

    case schema_result do
      {:ok, schema} ->
        Logger.info(
          "ClientCache: initialized with #{map_size(schema.tables)} table(s): #{Enum.join(Map.keys(schema.tables), ", ")}"
        )

        {:ok, %__MODULE__{schema: schema, store: Store.new(schema), handler: handler}}

      {:error, reason} ->
        Logger.error("ClientCache: failed to fetch schema: #{inspect(reason)}")
        {:stop, {:schema_fetch_failed, reason}}
    end
  end

  @impl true
  def handle_call({:get_all, table_name}, _from, state) do
    {:reply, Store.get_all(state.store, table_name), state}
  end

  def handle_call({:find, table_name, pk_value}, _from, state) do
    {:reply, Store.find(state.store, table_name, pk_value), state}
  end

  def handle_call({:count, table_name}, _from, state) do
    {:reply, Store.count(state.store, table_name), state}
  end

  def handle_call(:schema, _from, state) do
    {:reply, state.schema, state}
  end

  def handle_call({:apply, changes}, _from, state) do
    {:reply, Store.apply_changes(state.store, changes), state}
  end

  @impl true
  def handle_cast({:event, event}, state) do
    process_event(event, state)
    {:noreply, state}
  end

  def handle_cast(:clear, state) do
    Store.clear(state.store)
    {:noreply, state}
  end

  # --- Event processing ---

  defp process_event({:subscribe_applied, _query_set_id, table_rows}, state) do
    apply_table_rows(state, table_rows, :inserts)
    notify(state, :subscribe_applied)
  end

  defp process_event({:unsubscribe_applied, _query_set_id, {:some, table_rows}}, state) do
    apply_table_rows(state, table_rows, :deletes)
    notify(state, :unsubscribe_applied)
  end

  defp process_event({:transaction_update, query_sets}, state) do
    Store.apply_changes(state.store, RowDecoder.decode_query_sets(state.schema, query_sets))
    notify(state, :transaction_update)
  end

  defp process_event(
         {:reducer_result, _req_id, _timestamp, {:ok, _ret, %TransactionUpdate{query_sets: qs}}},
         state
       ) do
    process_event({:transaction_update, qs}, state)
  end

  defp process_event({:reducer_result, _req_id, _timestamp, _other}, state) do
    notify(state, :reducer_result)
  end

  defp process_event(_event, _state), do: :ok

  defp apply_table_rows(state, table_rows, kind) do
    changes =
      state.schema
      |> RowDecoder.decode_table_rows(table_rows)
      |> Enum.map(fn {table_name, rows} ->
        Map.put(%{table_name: table_name, inserts: [], deletes: []}, kind, rows)
      end)

    Store.apply_changes(state.store, changes)
  end

  defp notify(%{handler: nil}, _event), do: :ok

  defp notify(%{handler: pid}, event) do
    send(pid, {:cache_event, event})
  end
end
