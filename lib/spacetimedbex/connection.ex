defmodule Spacetimedbex.Connection do
  @moduledoc """
  WebSocket connection to a SpacetimeDB database.

  Manages the v2 BSATN binary WebSocket protocol lifecycle:
  - Connects with optional JWT authentication
  - Receives and decodes server messages
  - Sends client messages (subscribe, call_reducer, etc.)
  - Tracks request IDs for response correlation
  - Handles reconnection

  ## Usage

      {:ok, conn} = Spacetimedbex.Connection.start_link(
        host: "localhost:3000",
        database: "my_db",
        token: "optional-jwt-token",
        handler: self()
      )

      # Subscribe to a table
      Spacetimedbex.Connection.subscribe(conn, ["SELECT * FROM users"])

      # Call a reducer
      Spacetimedbex.Connection.call_reducer(conn, "create_user", args_bsatn)

  Messages are delivered to the handler process as `{:spacetimedb, message}` tuples.
  """

  use WebSockex

  require Logger

  alias Spacetimedbex.Protocol.ClientMessage

  alias Spacetimedbex.Protocol.ClientMessage.{
    CallProcedure,
    CallReducer,
    OneOffQuery,
    Subscribe,
    Unsubscribe
  }

  alias Spacetimedbex.Protocol.ServerMessage
  alias Spacetimedbex.Url

  defstruct [
    :host,
    :database,
    :token,
    :handler,
    :identity,
    :connection_id,
    :compression,
    next_request_id: 1,
    next_query_set_id: 1,
    pending_requests: %{},
    connected: false,
    max_reconnect_attempts: 5,
    base_backoff_ms: 1_000,
    max_backoff_ms: 10_000
  ]

  @type t :: %__MODULE__{}

  @ws_subprotocol "v2.bsatn.spacetimedb"

  # --- Public API ---

  @doc """
  Start a WebSocket connection to SpacetimeDB.

  ## Options
  - `:host` - Host and port (e.g., "localhost:3000"). Prefix with `https://` to connect
    over TLS (`wss://`), e.g. `"https://maincloud.spacetimedb.com"`. Required.
  - `:database` - Database name or identity. Required.
  - `:token` - JWT auth token. Optional (server will mint one if omitted). Reconnects
    reuse the token issued by the server, so the identity survives a reconnect.
  - `:handler` - PID or registered name to receive `{:spacetimedb, msg}` messages. Required.
  - `:compression` - Compression preference: `:none` or `:gzip`. Default `:none`.
    (Brotli is not supported.)
  - `:max_reconnect_attempts` - Max reconnection attempts before giving up. Default 5.
  - `:base_backoff_ms` - Base backoff time in ms (multiplied by attempt). Default 1000.
  - `:max_backoff_ms` - Maximum backoff time in ms. Default 10000.
  - `:name` - Optional process name registration.
  """
  def start_link(opts) do
    case Keyword.get(opts, :compression, :none) do
      c when c in [:none, :gzip] -> do_start_link(opts)
      other -> {:error, {:unsupported_compression, other}}
    end
  end

  defp do_start_link(opts) do
    host = Keyword.fetch!(opts, :host)
    database = Keyword.fetch!(opts, :database)
    handler = Keyword.fetch!(opts, :handler)
    token = Keyword.get(opts, :token)
    compression = Keyword.get(opts, :compression, :none)
    max_attempts = Keyword.get(opts, :max_reconnect_attempts, 5)
    base_backoff = Keyword.get(opts, :base_backoff_ms, 1_000)
    max_backoff = Keyword.get(opts, :max_backoff_ms, 10_000)
    name_opt = if opts[:name], do: [name: opts[:name]], else: []

    state = %__MODULE__{
      host: host,
      database: database,
      token: token,
      handler: handler,
      compression: compression,
      max_reconnect_attempts: max_attempts,
      base_backoff_ms: base_backoff,
      max_backoff_ms: max_backoff
    }

    url = build_url(host, database, compression)
    headers = build_headers(token)

    ws_opts =
      [
        extra_headers: headers,
        handle_initial_conn_failure: true
      ] ++ name_opt

    WebSockex.start_link(url, __MODULE__, state, ws_opts)
  end

  # All sending functions accept `request_id:` (and `subscribe/3` also
  # `query_set_id:`) to use caller-chosen ids, as `Spacetimedbex.Client` does.
  # Omitted ids are allocated from this connection's own counters.

  @doc """
  Subscribe to one or more SQL queries as a query set.

  Pass `query_set_id:` to choose the id; otherwise one is allocated and
  reported to the handler as `{:subscribe_sent, query_set_id, request_id}`.
  """
  def subscribe(conn, query_strings, opts \\ []) when is_list(query_strings) do
    WebSockex.cast(conn, {:subscribe, query_strings, opts})
  end

  @doc "Unsubscribe from a query set. Options: `:send_dropped_rows` (default `false`), `:request_id`."
  def unsubscribe(conn, query_set_id, opts \\ []) do
    WebSockex.cast(conn, {:unsubscribe, query_set_id, opts})
  end

  @doc "Execute a one-off SQL query."
  def one_off_query(conn, query_string, opts \\ []) do
    WebSockex.cast(conn, {:one_off_query, query_string, opts})
  end

  @doc "Call a reducer with BSATN-encoded arguments."
  def call_reducer(conn, reducer_name, args_bsatn \\ <<>>, opts \\ []) do
    WebSockex.cast(conn, {:call_reducer, reducer_name, args_bsatn, opts})
  end

  @doc """
  Call a procedure with BSATN-encoded arguments. The result arrives as
  `{:spacetimedb, {:procedure_result, request_id, status}}` where status is
  `{:returned, bsatn_binary}` or `{:internal_error, message}`.
  """
  def call_procedure(conn, procedure_name, args_bsatn \\ <<>>, opts \\ []) do
    WebSockex.cast(conn, {:call_procedure, procedure_name, args_bsatn, opts})
  end

  @doc "Get the current connection state."
  def get_state(conn) do
    conn |> :sys.get_state(5_000) |> sanitize_state()
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  # --- WebSockex Callbacks ---

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("SpacetimeDB: WebSocket connected to #{state.host}/#{state.database}")
    {:ok, %{state | connected: true}}
  end

  @impl true
  def handle_frame({:binary, data}, state) do
    case ServerMessage.decompress(data) do
      {:ok, payload} ->
        case ServerMessage.decode(payload) do
          {:ok, message, _rest} ->
            state = handle_server_message(message, state)
            {:ok, state}

          {:error, reason} ->
            Logger.warning("SpacetimeDB: Failed to decode message: #{inspect(reason)}")
            {:ok, state}
        end

      {:error, reason} ->
        Logger.warning("SpacetimeDB: Decompression failed: #{inspect(reason)}")
        {:ok, state}
    end
  end

  def handle_frame({:text, _data}, state) do
    Logger.warning("SpacetimeDB: Received unexpected text frame on BSATN connection")
    {:ok, state}
  end

  @impl true
  def handle_cast({:subscribe, query_strings, opts}, state) do
    {request_id, state} = take_request_id(state, opts)
    {query_set_id, state} = take_query_set_id(state, opts)

    msg = %Subscribe{
      request_id: request_id,
      query_set_id: query_set_id,
      query_strings: query_strings
    }

    state = track_request(state, request_id, {:subscribe, query_set_id, query_strings})
    notify(state, {:subscribe_sent, query_set_id, request_id})
    {:reply, {:binary, ClientMessage.encode(msg)}, state}
  end

  def handle_cast({:unsubscribe, query_set_id, opts}, state) do
    {request_id, state} = take_request_id(state, opts)
    flags = if opts[:send_dropped_rows], do: :send_dropped_rows, else: :default
    msg = %Unsubscribe{request_id: request_id, query_set_id: query_set_id, flags: flags}
    state = track_request(state, request_id, {:unsubscribe, query_set_id})
    {:reply, {:binary, ClientMessage.encode(msg)}, state}
  end

  def handle_cast({:one_off_query, query_string, opts}, state) do
    {request_id, state} = take_request_id(state, opts)
    msg = %OneOffQuery{request_id: request_id, query_string: query_string}
    state = track_request(state, request_id, {:one_off_query, query_string})
    {:reply, {:binary, ClientMessage.encode(msg)}, state}
  end

  def handle_cast({:call_reducer, reducer_name, args_bsatn, opts}, state) do
    {request_id, state} = take_request_id(state, opts)
    msg = %CallReducer{request_id: request_id, reducer: reducer_name, args: args_bsatn}
    state = track_request(state, request_id, {:call_reducer, reducer_name})
    {:reply, {:binary, ClientMessage.encode(msg)}, state}
  end

  def handle_cast({:call_procedure, procedure_name, args_bsatn, opts}, state) do
    {request_id, state} = take_request_id(state, opts)
    msg = %CallProcedure{request_id: request_id, procedure: procedure_name, args: args_bsatn}
    state = track_request(state, request_id, {:call_procedure, procedure_name})
    {:reply, {:binary, ClientMessage.encode(msg)}, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason, attempt_number: attempt, conn: conn}, state) do
    Logger.warning("SpacetimeDB: Disconnected (attempt #{attempt}): #{inspect(reason)}")

    state = %{state | connected: false, pending_requests: %{}}
    notify(state, {:disconnected, reason, attempt})

    if attempt < state.max_reconnect_attempts do
      backoff = min(state.base_backoff_ms * attempt, state.max_backoff_ms)
      Process.sleep(backoff)
      # Rebuild headers so the reconnect presents the latest server-issued token.
      {:reconnect, %{conn | extra_headers: build_headers(state.token)}, state}
    else
      Logger.error("SpacetimeDB: Max reconnection attempts reached, giving up")
      notify(state, :connection_failed)
      {:ok, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("SpacetimeDB: Connection terminated: #{inspect(reason)}")
    notify(state, {:terminated, reason})
    :ok
  end

  # --- Internal ---

  defp build_url(host, database, compression) do
    compression_param =
      case compression do
        :none -> "None"
        :gzip -> "Gzip"
      end

    "#{Url.ws_base(host)}/database/#{Url.segment(database)}/subscribe?compression=#{compression_param}"
  end

  defp build_headers(nil) do
    [{"Sec-WebSocket-Protocol", @ws_subprotocol}]
  end

  defp build_headers(token) do
    [
      {"Authorization", "Bearer #{token}"},
      {"Sec-WebSocket-Protocol", @ws_subprotocol}
    ]
  end

  defp handle_server_message(%ServerMessage.InitialConnection{} = msg, state) do
    Logger.info("SpacetimeDB: Identity assigned, connection_id received")

    state = %{state | identity: msg.identity, connection_id: msg.connection_id, token: msg.token}
    notify(state, {:identity, msg.identity, msg.connection_id, msg.token})
    state
  end

  defp handle_server_message(%ServerMessage.SubscribeApplied{} = msg, state) do
    state = complete_request(state, msg.request_id)
    notify(state, {:subscribe_applied, msg.query_set_id, msg.rows})
    state
  end

  defp handle_server_message(%ServerMessage.UnsubscribeApplied{} = msg, state) do
    state = complete_request(state, msg.request_id)
    notify(state, {:unsubscribe_applied, msg.query_set_id, msg.rows})
    state
  end

  defp handle_server_message(%ServerMessage.SubscriptionError{} = msg, state) do
    state = if msg.request_id, do: complete_request(state, msg.request_id), else: state
    notify(state, {:subscription_error, msg.query_set_id, msg.error})
    state
  end

  defp handle_server_message(%ServerMessage.TransactionUpdate{} = msg, state) do
    notify(state, {:transaction_update, msg.query_sets})
    state
  end

  defp handle_server_message(%ServerMessage.ReducerResult{} = msg, state) do
    state = complete_request(state, msg.request_id)
    notify(state, {:reducer_result, msg.request_id, msg.timestamp, msg.result})
    state
  end

  defp handle_server_message(%ServerMessage.OneOffQueryResult{} = msg, state) do
    state = complete_request(state, msg.request_id)
    notify(state, {:one_off_query_result, msg.request_id, msg.result})
    state
  end

  defp handle_server_message(%ServerMessage.ProcedureResult{} = msg, state) do
    state = complete_request(state, msg.request_id)
    notify(state, {:procedure_result, msg.request_id, msg.status})
    state
  end

  defp take_request_id(state, opts) do
    case opts[:request_id] do
      nil -> {state.next_request_id, %{state | next_request_id: state.next_request_id + 1}}
      id -> {id, state}
    end
  end

  defp take_query_set_id(state, opts) do
    case opts[:query_set_id] do
      nil -> {state.next_query_set_id, %{state | next_query_set_id: state.next_query_set_id + 1}}
      id -> {id, state}
    end
  end

  defp track_request(state, request_id, info) do
    %{state | pending_requests: Map.put(state.pending_requests, request_id, info)}
  end

  defp complete_request(state, request_id) do
    %{state | pending_requests: Map.delete(state.pending_requests, request_id)}
  end

  defp notify(%{handler: handler}, message) do
    send(handler, {:spacetimedb, message})
  end

  @doc false
  def sanitize_state(state) do
    %{
      host: state.host,
      database: state.database,
      identity: state.identity,
      connection_id: state.connection_id,
      connected: state.connected,
      pending_requests: map_size(state.pending_requests),
      next_request_id: state.next_request_id,
      next_query_set_id: state.next_query_set_id
    }
  end
end
