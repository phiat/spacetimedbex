defmodule Spacetimedbex.Client do
  @moduledoc """
  High-level SpacetimeDB client that ties Connection, ClientCache, and Schema together.

  ## Usage

      defmodule MyApp.SpaceClient do
        use Spacetimedbex.Client

        def config do
          %{
            host: "localhost:3000",
            database: "my_db",
            subscriptions: ["SELECT * FROM users", "SELECT * FROM messages"]
          }
        end

        def on_connect(identity, _conn_id, token, state) do
          IO.puts("Connected with identity: \#{inspect(identity)}")
          {:ok, Map.put(state, :token, token)}
        end

        def on_insert("users", row, state) do
          IO.puts("New user: \#{inspect(row)}")
          {:ok, state}
        end
      end

      # Start it
      {:ok, pid} = Spacetimedbex.Client.start_link(MyApp.SpaceClient, %{})

      # Call a reducer
      Spacetimedbex.Client.call_reducer(pid, "create_user", %{"name" => "Alice", "age" => 30})

      # Query the cache
      Spacetimedbex.Client.get_all(pid, "users")

  ## Callbacks

  All callbacks are optional except `config/0`.

  - `config()` — returns connection configuration map
  - `on_connect(identity, connection_id, token, state)` — called on initial connection
  - `on_subscribe_applied(table_name, rows, state)` — called per table when subscription data arrives
  - `on_insert(table_name, row, state)` — called per inserted row, and per event-table row
    (event rows are never stored in the cache)
  - `on_delete(table_name, row, state)` — called per deleted row
  - `on_update(table_name, old_row, new_row, state)` — called when a row with the same PK is deleted then inserted (row replacement). If not implemented, `on_delete` then `on_insert` fire instead
  - `on_transaction(changes, state)` — called with full transaction; return `{:ok, state, :skip_row_callbacks}` to suppress per-row callbacks
  - `on_reducer_result(request_id, result, state)` — called when a reducer completes
  - `on_unsubscribe_applied(query_set_id, rows, state)` — called when an unsubscribe completes; `rows` is a list of `%{table_name: name, rows: [row]}` (empty unless `send_dropped_rows: true`)
  - `on_query_result(request_id, result, state)` — called with one-off query results
  - `on_procedure_result(request_id, status, state)` — called when a procedure completes;
    status is `{:returned, bsatn_binary}` or `{:internal_error, message}`
  - `on_disconnect(reason, state)` — called on disconnection. The local cache is cleared;
    after an automatic reconnect the subscriptions are re-applied and
    `on_subscribe_applied` fires again with fresh rows.
  """

  @type state :: term()
  @type changes :: [
          %{
            table_name: String.t(),
            inserts: [map()],
            deletes: [map()]
          }
        ]

  @callback config() :: map()

  @callback on_connect(
              identity :: binary(),
              connection_id :: binary(),
              token :: String.t(),
              state
            ) :: {:ok, state}

  @callback on_subscribe_applied(table_name :: String.t(), rows :: [map()], state) :: {:ok, state}
  @callback on_insert(table_name :: String.t(), row :: map(), state) :: {:ok, state}
  @callback on_delete(table_name :: String.t(), row :: map(), state) :: {:ok, state}
  @callback on_update(table_name :: String.t(), old_row :: map(), new_row :: map(), state) ::
              {:ok, state}
  @callback on_transaction(changes, state) :: {:ok, state} | {:ok, state, :skip_row_callbacks}
  @callback on_reducer_result(request_id :: non_neg_integer(), result :: term(), state) ::
              {:ok, state}
  @callback on_unsubscribe_applied(query_set_id :: non_neg_integer(), rows :: [map()], state) ::
              {:ok, state}
  @callback on_query_result(request_id :: non_neg_integer(), result :: term(), state) ::
              {:ok, state}
  @callback on_procedure_result(request_id :: non_neg_integer(), status :: term(), state) ::
              {:ok, state}
  @callback on_disconnect(reason :: term(), state) :: {:ok, state}

  @optional_callbacks [
    on_connect: 4,
    on_subscribe_applied: 3,
    on_insert: 3,
    on_delete: 3,
    on_update: 4,
    on_transaction: 2,
    on_reducer_result: 3,
    on_unsubscribe_applied: 3,
    on_query_result: 3,
    on_procedure_result: 3,
    on_disconnect: 2
  ]

  defmacro __using__(_opts) do
    quote do
      @behaviour Spacetimedbex.Client
    end
  end

  use GenServer

  alias Spacetimedbex.BSATN.ValueEncoder
  alias Spacetimedbex.ClientCache
  alias Spacetimedbex.ClientCache.RowDecoder
  alias Spacetimedbex.Connection

  defstruct [
    :callback_module,
    :user_state,
    :cache_pid,
    :conn_pid,
    :schema,
    :config
  ]

  # --- Public API ---

  @doc """
  Start a Client GenServer.

  ## Parameters
  - `module` — callback module that `use Spacetimedbex.Client`
  - `init_state` — initial user state passed to callbacks
  - `opts` — GenServer options (e.g. `:name`)
  """
  def start_link(module, init_state, opts \\ []) do
    name = Keyword.get(opts, :name, module)
    config_override = Keyword.get(opts, :config)
    GenServer.start_link(__MODULE__, {module, init_state, config_override}, name: name)
  end

  @doc "Call a reducer with a map of arguments. Auto-encodes via schema."
  def call_reducer(pid, reducer_name, args_map \\ %{}) do
    GenServer.call(pid, {:call_reducer, reducer_name, args_map})
  end

  @doc "Call a reducer with pre-encoded BSATN binary arguments."
  def call_reducer_raw(pid, reducer_name, bsatn_binary) do
    GenServer.call(pid, {:call_reducer_raw, reducer_name, bsatn_binary})
  end

  @doc "Call a procedure with pre-encoded BSATN binary arguments."
  def call_procedure_raw(pid, procedure_name, bsatn_binary \\ <<>>) do
    GenServer.call(pid, {:call_procedure_raw, procedure_name, bsatn_binary})
  end

  @doc """
  Unsubscribe from a query set by ID.

  Options: `:send_dropped_rows` (default `true`) — ask the server for the rows
  leaving the subscription so they can be removed from the local cache.
  """
  def unsubscribe(pid, query_set_id, opts \\ []) do
    opts = Keyword.put_new(opts, :send_dropped_rows, true)
    GenServer.call(pid, {:unsubscribe, query_set_id, opts})
  end

  @doc "Execute a one-off SQL query via WebSocket."
  def query(pid, query_string) do
    GenServer.call(pid, {:one_off_query, query_string})
  end

  @doc "Get all rows from a cached table."
  def get_all(pid, table_name) do
    GenServer.call(pid, {:get_all, table_name})
  end

  @doc "Find a row by primary key."
  def find(pid, table_name, pk_value) do
    GenServer.call(pid, {:find, table_name, pk_value})
  end

  @doc "Count rows in a cached table."
  def count(pid, table_name) do
    GenServer.call(pid, {:count, table_name})
  end

  @doc "Get the cached schema."
  def schema(pid) do
    GenServer.call(pid, :schema)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init({module, init_state, config_override}) do
    # Callbacks are detected with function_exported?/3, which requires the
    # module to be loaded (it may not be when a :config override is given).
    Code.ensure_loaded!(module)
    config = config_override || module.config()
    host = Map.fetch!(config, :host)
    database = Map.fetch!(config, :database)

    # Start ClientCache (fetches schema)
    cache_opts = [host: host, database: database, handler: self()]

    case ClientCache.start_link(cache_opts) do
      {:ok, cache_pid} ->
        schema = ClientCache.schema(cache_pid)

        # Start Connection with handler: self()
        conn_opts = [
          host: host,
          database: database,
          handler: self(),
          token: Map.get(config, :token),
          compression: Map.get(config, :compression, :none)
        ]

        case Connection.start_link(conn_opts) do
          {:ok, conn_pid} ->
            state = %__MODULE__{
              callback_module: module,
              user_state: init_state,
              cache_pid: cache_pid,
              conn_pid: conn_pid,
              schema: schema,
              config: config
            }

            {:ok, state}

          {:error, reason} ->
            {:stop, {:connection_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:cache_failed, reason}}
    end
  end

  @impl true
  def handle_call({:call_reducer, reducer_name, args_map}, _from, state) do
    case Map.get(state.schema.reducers, reducer_name) do
      nil ->
        {:reply, {:error, {:unknown_reducer, reducer_name}}, state}

      reducer_def ->
        case ValueEncoder.encode_reducer_args(args_map, reducer_def.params) do
          {:ok, bsatn} ->
            Connection.call_reducer(state.conn_pid, reducer_name, bsatn)
            {:reply, :ok, state}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  def handle_call({:unsubscribe, query_set_id, opts}, _from, state) do
    Connection.unsubscribe(state.conn_pid, query_set_id, opts)
    {:reply, :ok, state}
  end

  def handle_call({:one_off_query, query_string}, _from, state) do
    Connection.one_off_query(state.conn_pid, query_string)
    {:reply, :ok, state}
  end

  def handle_call({:call_reducer_raw, reducer_name, bsatn_binary}, _from, state) do
    Connection.call_reducer(state.conn_pid, reducer_name, bsatn_binary)
    {:reply, :ok, state}
  end

  def handle_call({:call_procedure_raw, procedure_name, bsatn_binary}, _from, state) do
    Connection.call_procedure(state.conn_pid, procedure_name, bsatn_binary)
    {:reply, :ok, state}
  end

  def handle_call({:get_all, table_name}, _from, state) do
    {:reply, ClientCache.get_all(state.cache_pid, table_name), state}
  end

  def handle_call({:find, table_name, pk_value}, _from, state) do
    {:reply, ClientCache.find(state.cache_pid, table_name, pk_value), state}
  end

  def handle_call({:count, table_name}, _from, state) do
    {:reply, ClientCache.count(state.cache_pid, table_name), state}
  end

  def handle_call(:schema, _from, state) do
    {:reply, state.schema, state}
  end

  @impl true
  def handle_info({:spacetimedb, msg}, state) do
    state = handle_spacetimedb_message(msg, state)
    {:noreply, state}
  end

  def handle_info({:cache_event, _event}, state) do
    # Ignore cache events — we handle everything from Connection messages directly
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- SpacetimeDB Message Handling ---

  defp handle_spacetimedb_message({:identity, identity, conn_id, token}, state) do
    # Auto-subscribe if configured
    subscriptions = Map.get(state.config, :subscriptions, [])

    if subscriptions != [] do
      Connection.subscribe(state.conn_pid, subscriptions)
    end

    invoke_callback(state, :on_connect, [identity, conn_id, token])
  end

  defp handle_spacetimedb_message({:subscribe_applied, _query_set_id, table_rows}, state) do
    decoded = RowDecoder.decode_table_rows(state.schema, table_rows)

    ClientCache.apply_changes(
      state.cache_pid,
      Enum.map(decoded, fn {table_name, rows} ->
        %{table_name: table_name, inserts: rows, deletes: []}
      end)
    )

    Enum.reduce(decoded, state, fn {table_name, rows}, acc ->
      invoke_callback(acc, :on_subscribe_applied, [table_name, rows])
    end)
  end

  defp handle_spacetimedb_message({:transaction_update, query_sets}, state) do
    apply_transaction(state, query_sets)
  end

  defp handle_spacetimedb_message({:reducer_result, req_id, _timestamp, result}, state) do
    state =
      case result do
        {:ok, _ret, %{query_sets: query_sets}} -> apply_transaction(state, query_sets)
        _ -> state
      end

    invoke_callback(state, :on_reducer_result, [req_id, result])
  end

  defp handle_spacetimedb_message({:unsubscribe_applied, query_set_id, table_rows}, state) do
    decoded =
      case table_rows do
        {:some, rows} -> RowDecoder.decode_table_rows(state.schema, rows)
        nil -> []
      end

    ClientCache.apply_changes(
      state.cache_pid,
      Enum.map(decoded, fn {table_name, rows} ->
        %{table_name: table_name, inserts: [], deletes: rows}
      end)
    )

    rows = Enum.map(decoded, fn {table_name, rows} -> %{table_name: table_name, rows: rows} end)
    invoke_callback(state, :on_unsubscribe_applied, [query_set_id, rows])
  end

  defp handle_spacetimedb_message({:one_off_query_result, request_id, result}, state) do
    invoke_callback(state, :on_query_result, [request_id, result])
  end

  defp handle_spacetimedb_message({:procedure_result, request_id, status}, state) do
    invoke_callback(state, :on_procedure_result, [request_id, status])
  end

  defp handle_spacetimedb_message({:disconnected, reason, _attempt}, state) do
    # Rows may change while we're offline; the resubscribe after reconnect
    # repopulates the cache from scratch.
    ClientCache.clear(state.cache_pid)
    invoke_callback(state, :on_disconnect, [reason])
  end

  defp handle_spacetimedb_message(_msg, state), do: state

  # --- Helpers ---

  defp apply_transaction(state, query_sets) do
    changes = RowDecoder.decode_query_sets(state.schema, query_sets)
    ClientCache.apply_changes(state.cache_pid, changes)

    case invoke_callback_result(state, :on_transaction, [changes]) do
      {:ok, new_state, :skip_row_callbacks} -> new_state
      {:ok, new_state} -> fire_row_callbacks(new_state, changes)
      :not_implemented -> fire_row_callbacks(state, changes)
    end
  end

  defp fire_row_callbacks(state, changes) do
    Enum.reduce(changes, state, fn %{table_name: table_name} = change, acc ->
      {updates, deletes, inserts} =
        match_updates(change.deletes, change.inserts, pk_names_for(acc, table_name))

      acc = Enum.reduce(deletes, acc, &invoke_callback(&2, :on_delete, [table_name, &1]))

      acc =
        Enum.reduce(updates, acc, fn {old_row, new_row}, inner ->
          fire_update(inner, table_name, old_row, new_row)
        end)

      # Event-table rows are transient: surfaced via on_insert, never cached.
      Enum.reduce(
        inserts ++ change.events,
        acc,
        &invoke_callback(&2, :on_insert, [table_name, &1])
      )
    end)
  end

  defp fire_update(state, table_name, old_row, new_row) do
    case invoke_callback_result(state, :on_update, [table_name, old_row, new_row]) do
      :not_implemented ->
        state
        |> invoke_callback(:on_delete, [table_name, old_row])
        |> invoke_callback(:on_insert, [table_name, new_row])

      {:ok, new_state} ->
        new_state

      {:ok, new_state, _} ->
        new_state
    end
  end

  # Pairs deletes and inserts sharing a primary key into updates.
  # Returns {updates, pure_deletes, pure_inserts}; tables without a PK have no updates.
  defp match_updates(deletes, inserts, []), do: {[], deletes, inserts}

  defp match_updates(deletes, inserts, pk_names) do
    deletes_by_pk = Map.new(deletes, &{ClientCache.row_key(&1, pk_names), &1})

    {updates, pure_inserts, unmatched} =
      Enum.reduce(inserts, {[], [], deletes_by_pk}, fn row, {upd, ins, dels} ->
        case Map.pop(dels, ClientCache.row_key(row, pk_names)) do
          {nil, dels} -> {upd, [row | ins], dels}
          {old_row, dels} -> {[{old_row, row} | upd], ins, dels}
        end
      end)

    pure_deletes =
      Enum.filter(deletes, &Map.has_key?(unmatched, ClientCache.row_key(&1, pk_names)))

    {Enum.reverse(updates), pure_deletes, Enum.reverse(pure_inserts)}
  end

  defp pk_names_for(state, table_name) do
    case Spacetimedbex.Schema.primary_key_names(state.schema, table_name) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  defp invoke_callback(state, callback_name, args) do
    case invoke_callback_result(state, callback_name, args) do
      {:ok, new_state} -> new_state
      {:ok, new_state, _} -> new_state
      :not_implemented -> state
    end
  end

  defp invoke_callback_result(state, callback_name, args) do
    module = state.callback_module

    if function_exported?(module, callback_name, length(args) + 1) do
      case apply(module, callback_name, args ++ [state.user_state]) do
        {:ok, new_user_state} ->
          {:ok, %{state | user_state: new_user_state}}

        {:ok, new_user_state, extra} ->
          {:ok, %{state | user_state: new_user_state}, extra}
      end
    else
      :not_implemented
    end
  end
end
