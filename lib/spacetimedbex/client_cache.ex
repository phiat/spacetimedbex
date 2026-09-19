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

  alias Spacetimedbex.ClientCache.RowDecoder
  alias Spacetimedbex.Protocol.ServerMessage.TransactionUpdate
  alias Spacetimedbex.Schema

  defstruct [:schema, :tables, :handler]

  @type table_meta :: %{tid: :ets.table(), pk_names: [String.t()]}

  @type t :: %__MODULE__{
          schema: Schema.t() | nil,
          tables: %{String.t() => table_meta()},
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
  `Spacetimedbex.ClientCache.RowDecoder.decode_query_sets/2`. Deletes are
  applied before inserts so primary-key updates land correctly.
  """
  def apply_changes(cache, changes) when is_list(changes) do
    GenServer.cast(cache, {:apply, changes})
  end

  @doc "Remove all cached rows (e.g. after a disconnect)."
  def clear(cache) do
    GenServer.cast(cache, :clear)
  end

  @doc false
  # Cache key for a row: the primary key value, a tuple for composite keys,
  # or the whole row when the table has no primary key.
  def row_key(row, []), do: row
  def row_key(row, [single_pk]), do: Map.get(row, single_pk)
  def row_key(row, pk_names), do: List.to_tuple(Enum.map(pk_names, &Map.get(row, &1)))

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
        tables = create_tables(schema)

        Logger.info(
          "ClientCache: initialized with #{map_size(schema.tables)} table(s): #{Enum.join(Map.keys(schema.tables), ", ")}"
        )

        {:ok, %__MODULE__{schema: schema, tables: tables, handler: handler}}

      {:error, reason} ->
        Logger.error("ClientCache: failed to fetch schema: #{inspect(reason)}")
        {:stop, {:schema_fetch_failed, reason}}
    end
  end

  @impl true
  def handle_call({:get_all, table_name}, _from, state) do
    result =
      case Map.get(state.tables, table_name) do
        nil -> []
        %{tid: tid} -> :ets.select(tid, [{{:_, :"$1"}, [], [:"$1"]}])
      end

    {:reply, result, state}
  end

  def handle_call({:find, table_name, pk_value}, _from, state) do
    result =
      with %{tid: tid} <- Map.get(state.tables, table_name),
           [{_key, row}] <- :ets.lookup(tid, pk_value) do
        row
      else
        _ -> nil
      end

    {:reply, result, state}
  end

  def handle_call({:count, table_name}, _from, state) do
    result =
      case Map.get(state.tables, table_name) do
        nil -> 0
        %{tid: tid} -> :ets.info(tid, :size)
      end

    {:reply, result, state}
  end

  def handle_call(:schema, _from, state) do
    {:reply, state.schema, state}
  end

  @impl true
  def handle_cast({:event, event}, state) do
    process_event(event, state)
    {:noreply, state}
  end

  def handle_cast({:apply, changes}, state) do
    apply_decoded(changes, state)
    {:noreply, state}
  end

  def handle_cast(:clear, state) do
    Enum.each(state.tables, fn {_name, %{tid: tid}} -> :ets.delete_all_objects(tid) end)
    {:noreply, state}
  end

  # --- Event processing ---

  defp process_event({:subscribe_applied, _query_set_id, table_rows}, state) do
    state.schema
    |> RowDecoder.decode_table_rows(table_rows)
    |> Enum.map(fn {table_name, rows} ->
      %{table_name: table_name, inserts: rows, deletes: []}
    end)
    |> apply_decoded(state)

    notify(state, :subscribe_applied)
  end

  defp process_event({:unsubscribe_applied, _query_set_id, {:some, table_rows}}, state) do
    state.schema
    |> RowDecoder.decode_table_rows(table_rows)
    |> Enum.map(fn {table_name, rows} ->
      %{table_name: table_name, inserts: [], deletes: rows}
    end)
    |> apply_decoded(state)

    notify(state, :unsubscribe_applied)
  end

  defp process_event({:transaction_update, query_sets}, state) do
    state.schema
    |> RowDecoder.decode_query_sets(query_sets)
    |> apply_decoded(state)

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

  defp apply_decoded(changes, state) do
    Enum.each(changes, fn %{table_name: table_name} = change ->
      case Map.get(state.tables, table_name) do
        nil ->
          Logger.warning("ClientCache: no table #{table_name} in schema")

        %{tid: tid, pk_names: pk_names} ->
          Enum.each(change.deletes, &:ets.delete(tid, row_key(&1, pk_names)))
          :ets.insert(tid, Enum.map(change.inserts, &{row_key(&1, pk_names), &1}))
      end
    end)
  end

  # --- ETS operations ---

  defp create_tables(schema) do
    Map.new(schema.tables, fn {table_name, _table_def} ->
      {:ok, pk_names} = Schema.primary_key_names(schema, table_name)
      tid = :ets.new(:spacetimedbex_table, [:set, :protected])
      {table_name, %{tid: tid, pk_names: pk_names}}
    end)
  end

  defp notify(%{handler: nil}, _event), do: :ok

  defp notify(%{handler: pid}, event) do
    send(pid, {:cache_event, event})
  end
end
