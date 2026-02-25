defmodule Spacetimedbex.Phoenix do
  @moduledoc """
  Phoenix PubSub adapter for SpacetimeDB.

  Broadcasts SpacetimeDB table changes to Phoenix.PubSub topics, making it
  easy to build real-time Phoenix applications backed by SpacetimeDB.

  ## Topics

  - `"spacetimedb:{table_name}"` — insert/delete events for a table
  - `"spacetimedb:reducers"` — reducer result events

  ## Messages

  - `{:spacetimedb, :insert, table_name, row}`
  - `{:spacetimedb, :delete, table_name, row}`
  - `{:spacetimedb, :reducer_result, request_id, result}`

  ## Usage

      # In your supervision tree:
      children = [
        {Phoenix.PubSub, name: MyApp.PubSub},
        {Spacetimedbex.Phoenix,
         pubsub: MyApp.PubSub,
         host: "localhost:3000",
         database: "my_db",
         subscriptions: ["SELECT * FROM users"]}
      ]

      # In a LiveView:
      def mount(_params, _session, socket) do
        Phoenix.PubSub.subscribe(MyApp.PubSub, "spacetimedb:users")
        {:ok, socket}
      end

      def handle_info({:spacetimedb, :insert, "users", row}, socket) do
        {:noreply, stream_insert(socket, :users, row)}
      end
  """

  use Spacetimedbex.Client

  @doc """
  Start the Phoenix adapter.

  ## Options
  - `:pubsub` — Phoenix.PubSub module name (required)
  - `:host` — SpacetimeDB host (required)
  - `:database` — database name (required)
  - `:subscriptions` — list of SQL subscription queries
  - `:token` — optional JWT token
  - `:compression` — optional compression setting
  - `:name` — optional process name (defaults to `Spacetimedbex.Phoenix`)
  """
  def start_link(opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)
    name = Keyword.get(opts, :name, __MODULE__)

    config = %{
      host: Keyword.fetch!(opts, :host),
      database: Keyword.fetch!(opts, :database),
      subscriptions: Keyword.get(opts, :subscriptions, []),
      token: Keyword.get(opts, :token),
      compression: Keyword.get(opts, :compression, :none)
    }

    init_state = %{pubsub: pubsub}

    Spacetimedbex.Client.start_link(__MODULE__, init_state,
      name: name,
      config: config
    )
  end

  @doc "Get all rows from a cached table."
  def get_all(pid \\ __MODULE__, table_name) do
    Spacetimedbex.Client.get_all(pid, table_name)
  end

  @doc "Find a row by primary key."
  def find(pid \\ __MODULE__, table_name, pk_value) do
    Spacetimedbex.Client.find(pid, table_name, pk_value)
  end

  # --- Client Callbacks ---

  @impl true
  def config do
    # Not used — config is passed via start_link opts override
    %{host: "", database: ""}
  end

  @impl true
  def on_insert(table_name, row, state) do
    Phoenix.PubSub.broadcast(
      state.pubsub,
      "spacetimedb:#{table_name}",
      {:spacetimedb, :insert, table_name, row}
    )

    {:ok, state}
  end

  @impl true
  def on_delete(table_name, row, state) do
    Phoenix.PubSub.broadcast(
      state.pubsub,
      "spacetimedb:#{table_name}",
      {:spacetimedb, :delete, table_name, row}
    )

    {:ok, state}
  end

  @impl true
  def on_reducer_result(request_id, result, state) do
    Phoenix.PubSub.broadcast(
      state.pubsub,
      "spacetimedb:reducers",
      {:spacetimedb, :reducer_result, request_id, result}
    )

    {:ok, state}
  end
end
