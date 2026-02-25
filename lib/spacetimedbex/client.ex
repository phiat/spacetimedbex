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
  - `on_insert(table_name, row, state)` — called per inserted row
  - `on_delete(table_name, row, state)` — called per deleted row
  - `on_transaction(changes, state)` — called with full transaction; return `{:ok, state, :skip_row_callbacks}` to suppress per-row callbacks
  - `on_reducer_result(request_id, result, state)` — called when a reducer completes
  - `on_disconnect(reason, state)` — called on disconnection
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
  @callback on_transaction(changes, state) :: {:ok, state} | {:ok, state, :skip_row_callbacks}
  @callback on_reducer_result(request_id :: non_neg_integer(), result :: term(), state) ::
              {:ok, state}
  @callback on_disconnect(reason :: term(), state) :: {:ok, state}

  @optional_callbacks [
    on_connect: 4,
    on_subscribe_applied: 3,
    on_insert: 3,
    on_delete: 3,
    on_transaction: 2,
    on_reducer_result: 3,
    on_disconnect: 2
  ]

  defmacro __using__(_opts) do
    quote do
      @behaviour Spacetimedbex.Client
    end
  end

  use GenServer

  require Logger

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

  def handle_call({:call_reducer_raw, reducer_name, bsatn_binary}, _from, state) do
    Connection.call_reducer(state.conn_pid, reducer_name, bsatn_binary)
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

  defp handle_spacetimedb_message({:subscribe_applied, query_set_id, table_rows}, state) do
    # Feed to cache
    ClientCache.handle_event(state.cache_pid, {:subscribe_applied, query_set_id, table_rows})

    # Decode and fire callbacks per table
    Enum.reduce(table_rows, state, fn %{table_name: table_name, rows: row_list}, acc ->
      rows = decode_rows(acc, table_name, row_list)
      invoke_callback(acc, :on_subscribe_applied, [table_name, rows])
    end)
  end

  defp handle_spacetimedb_message({:transaction_update, query_sets}, state) do
    # Feed to cache
    ClientCache.handle_event(state.cache_pid, {:transaction_update, query_sets})

    # Build decoded changes
    changes = decode_transaction_changes(state, query_sets)

    # Fire on_transaction, check if we should skip row callbacks
    case invoke_callback_result(state, :on_transaction, [changes]) do
      {:ok, new_state, :skip_row_callbacks} ->
        new_state

      {:ok, new_state} ->
        fire_row_callbacks(new_state, changes)

      :not_implemented ->
        fire_row_callbacks(state, changes)
    end
  end

  defp handle_spacetimedb_message({:reducer_result, req_id, timestamp, result}, state) do
    # Feed to cache (handles embedded transaction)
    ClientCache.handle_event(state.cache_pid, {:reducer_result, req_id, timestamp, result})

    # If result contains a transaction, decode and fire row callbacks
    state = handle_reducer_transaction(state, result)

    invoke_callback(state, :on_reducer_result, [req_id, result])
  end

  defp handle_spacetimedb_message({:disconnected, reason, _attempt}, state) do
    invoke_callback(state, :on_disconnect, [reason])
  end

  defp handle_spacetimedb_message(_msg, state), do: state

  # --- Helpers ---

  defp decode_rows(state, table_name, row_list) do
    case Spacetimedbex.Schema.columns_for(state.schema, table_name) do
      {:ok, columns} -> RowDecoder.decode_row_list(row_list, columns)
      {:error, _} -> []
    end
  end

  defp decode_transaction_changes(state, query_sets) do
    Enum.flat_map(query_sets, fn %{tables: tables} ->
      Enum.flat_map(tables, &decode_table_changes(state, &1))
    end)
  end

  defp decode_table_changes(state, %{table_name: table_name, rows: update_rows}) do
    Enum.flat_map(update_rows, fn
      {:persistent, %{inserts: inserts, deletes: deletes}} ->
        [
          %{
            table_name: table_name,
            inserts: decode_rows(state, table_name, inserts),
            deletes: decode_rows(state, table_name, deletes)
          }
        ]

      {:event, _} ->
        []
    end)
  end

  defp handle_reducer_transaction(state, {:ok, _ret, %{query_sets: query_sets}}) do
    changes = decode_transaction_changes(state, query_sets)
    fire_row_callbacks(state, changes)
  end

  defp handle_reducer_transaction(state, _), do: state

  defp fire_row_callbacks(state, changes) do
    Enum.reduce(changes, state, fn %{table_name: table_name, inserts: inserts, deletes: deletes},
                                   acc ->
      acc =
        Enum.reduce(deletes, acc, fn row, inner_acc ->
          invoke_callback(inner_acc, :on_delete, [table_name, row])
        end)

      Enum.reduce(inserts, acc, fn row, inner_acc ->
        invoke_callback(inner_acc, :on_insert, [table_name, row])
      end)
    end)
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
