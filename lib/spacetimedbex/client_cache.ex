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

  alias Spacetimedbex.Schema
  alias Spacetimedbex.ClientCache.RowDecoder

  defstruct [:schema, :ets_tables, :handler]

  @type t :: %__MODULE__{
          schema: Schema.t() | nil,
          ets_tables: %{String.t() => :ets.table()},
          handler: pid() | nil
        }

  # --- Public API ---

  @doc """
  Start the client cache.

  ## Options
  - `:host` - SpacetimeDB host (for schema fetch). Required.
  - `:database` - Database name. Required.
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

  @doc "Find a row by primary key value."
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
  Process a SpacetimeDB event. Called by the connection handler to feed
  events into the cache.
  """
  def handle_event(cache, event) do
    GenServer.cast(cache, {:event, event})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    host = Keyword.fetch!(opts, :host)
    database = Keyword.fetch!(opts, :database)
    handler = Keyword.get(opts, :handler)

    case Schema.fetch(host, database) do
      {:ok, schema} ->
        ets_tables = create_ets_tables(schema)

        Logger.info(
          "ClientCache: initialized with #{map_size(schema.tables)} table(s): #{Enum.join(Map.keys(schema.tables), ", ")}"
        )

        {:ok, %__MODULE__{schema: schema, ets_tables: ets_tables, handler: handler}}

      {:error, reason} ->
        Logger.error("ClientCache: failed to fetch schema: #{inspect(reason)}")
        {:stop, {:schema_fetch_failed, reason}}
    end
  end

  @impl true
  def handle_call({:get_all, table_name}, _from, state) do
    result =
      case Map.get(state.ets_tables, table_name) do
        nil -> []
        tid -> :ets.tab2list(tid) |> Enum.map(fn {_key, row} -> row end)
      end

    {:reply, result, state}
  end

  def handle_call({:find, table_name, pk_value}, _from, state) do
    result =
      case Map.get(state.ets_tables, table_name) do
        nil ->
          nil

        tid ->
          case :ets.lookup(tid, pk_value) do
            [{_key, row}] -> row
            [] -> nil
          end
      end

    {:reply, result, state}
  end

  def handle_call({:count, table_name}, _from, state) do
    result =
      case Map.get(state.ets_tables, table_name) do
        nil -> 0
        tid -> :ets.info(tid, :size)
      end

    {:reply, result, state}
  end

  def handle_call(:schema, _from, state) do
    {:reply, state.schema, state}
  end

  @impl true
  def handle_cast({:event, event}, state) do
    state = process_event(event, state)
    {:noreply, state}
  end

  # --- Event processing ---

  defp process_event({:subscribe_applied, _query_set_id, rows}, state) do
    Enum.each(rows, fn %{table_name: table_name, rows: row_list} ->
      apply_inserts(state, table_name, row_list)
    end)

    notify(state, :subscribe_applied)
    state
  end

  defp process_event({:transaction_update, query_sets}, state) do
    Enum.each(query_sets, fn %{tables: tables} ->
      Enum.each(tables, &apply_table_update(state, &1))
    end)

    notify(state, :transaction_update)
    state
  end

  defp process_event(
         {:reducer_result, _req_id, _timestamp,
          {:ok, _ret, %Spacetimedbex.Protocol.ServerMessage.TransactionUpdate{query_sets: qs}}},
         state
       ) do
    process_event({:transaction_update, qs}, state)
  end

  defp process_event({:reducer_result, _req_id, _timestamp, :ok_empty}, state) do
    notify(state, :reducer_result)
    state
  end

  defp process_event({:reducer_result, _req_id, _timestamp, _other}, state) do
    notify(state, :reducer_result)
    state
  end

  defp process_event(_event, state), do: state

  defp apply_table_update(state, %{table_name: table_name, rows: update_rows}) do
    Enum.each(update_rows, fn
      {:persistent, %{inserts: inserts, deletes: deletes}} ->
        apply_deletes(state, table_name, deletes)
        apply_inserts(state, table_name, inserts)

      {:event, _events} ->
        :ok
    end)
  end

  # --- ETS operations ---

  defp create_ets_tables(schema) do
    Map.new(schema.tables, fn {table_name, _table_def} ->
      tid = :ets.new(:spacetimedbex_table, [:set, :protected])
      {table_name, tid}
    end)
  end

  defp apply_inserts(state, table_name, row_list) do
    case {Map.get(state.ets_tables, table_name), Schema.columns_for(state.schema, table_name)} do
      {nil, _} ->
        Logger.warning("ClientCache: no ETS table for #{table_name}")

      {_, {:error, _}} ->
        Logger.warning("ClientCache: no schema for #{table_name}")

      {tid, {:ok, columns}} ->
        rows = RowDecoder.decode_row_list(row_list, columns)
        pk_indices = pk_indices_for(state.schema, table_name)
        pk_names = Enum.map(pk_indices, fn i -> Enum.at(columns, i) end) |> Enum.map(& &1.name)

        Enum.each(rows, fn row ->
          pk_value = extract_pk(row, pk_names)
          :ets.insert(tid, {pk_value, row})
        end)

        if rows != [] do
          Logger.debug("ClientCache: inserted #{length(rows)} row(s) into #{table_name}")
        end
    end
  end

  defp apply_deletes(state, table_name, row_list) do
    case {Map.get(state.ets_tables, table_name), Schema.columns_for(state.schema, table_name)} do
      {nil, _} ->
        :ok

      {_, {:error, _}} ->
        :ok

      {tid, {:ok, columns}} ->
        rows = RowDecoder.decode_row_list(row_list, columns)
        pk_indices = pk_indices_for(state.schema, table_name)
        pk_names = Enum.map(pk_indices, fn i -> Enum.at(columns, i) end) |> Enum.map(& &1.name)

        Enum.each(rows, fn row ->
          pk_value = extract_pk(row, pk_names)
          :ets.delete(tid, pk_value)
        end)

        if rows != [] do
          Logger.debug("ClientCache: deleted #{length(rows)} row(s) from #{table_name}")
        end
    end
  end

  defp pk_indices_for(schema, table_name) do
    case Schema.primary_key_for(schema, table_name) do
      {:ok, indices} -> indices
      {:error, _} -> [0]
    end
  end

  defp extract_pk(row, [single_pk]) do
    Map.get(row, single_pk)
  end

  defp extract_pk(row, pk_names) do
    List.to_tuple(Enum.map(pk_names, &Map.get(row, &1)))
  end

  defp notify(%{handler: nil}, _event), do: :ok

  defp notify(%{handler: pid}, event) do
    send(pid, {:cache_event, event})
  end
end
