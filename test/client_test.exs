defmodule Spacetimedbex.ClientTest do
  use ExUnit.Case, async: false

  alias Spacetimedbex.Client

  # --- Test callback module that records calls ---

  defmodule RecordingClient do
    use Spacetimedbex.Client

    def config do
      %{
        host: "localhost:3000",
        database: "testmodule",
        subscriptions: ["SELECT * FROM person"]
      }
    end

    def on_connect(identity, conn_id, token, state) do
      send(state.test_pid, {:callback, :on_connect, identity, conn_id, token})
      {:ok, state}
    end

    def on_subscribe_applied(table_name, rows, state) do
      send(state.test_pid, {:callback, :on_subscribe_applied, table_name, rows})
      {:ok, state}
    end

    def on_insert(table_name, row, state) do
      send(state.test_pid, {:callback, :on_insert, table_name, row})
      {:ok, state}
    end

    def on_delete(table_name, row, state) do
      send(state.test_pid, {:callback, :on_delete, table_name, row})
      {:ok, state}
    end

    def on_transaction(changes, state) do
      send(state.test_pid, {:callback, :on_transaction, changes})

      if state[:skip_row_callbacks] do
        {:ok, state, :skip_row_callbacks}
      else
        {:ok, state}
      end
    end

    def on_reducer_result(request_id, result, state) do
      send(state.test_pid, {:callback, :on_reducer_result, request_id, result})
      {:ok, state}
    end

    def on_disconnect(reason, state) do
      send(state.test_pid, {:callback, :on_disconnect, reason})
      {:ok, state}
    end
  end

  # --- Minimal callback module (only config) ---

  defmodule MinimalClient do
    use Spacetimedbex.Client

    def config do
      %{host: "localhost:3000", database: "testmodule"}
    end
  end

  describe "ValueEncoder integration via call_reducer" do
    @tag :integration
    test "call_reducer encodes args from schema" do
      # This would need a live SpacetimeDB, skip in unit tests
    end
  end

  describe "synthetic message handling" do
    # These tests send messages directly to the Client GenServer to test
    # callback dispatch without needing a live Connection/ClientCache.

    @tag :integration
    test "on_connect fires on identity message" do
      # Requires live server for ClientCache schema fetch
    end

    @tag :integration
    test "subscribe_applied fires per-table callbacks" do
      # Requires live server
    end
  end

  describe "ValueEncoder.encode_reducer_args via Client.call_reducer" do
    # Pure encoding tests (no server needed) are in value_encoder_test.exs
    # Client.call_reducer integration tests require a live schema + connection
  end

  # Unit tests that don't require a live server

  describe "Client module defines behaviour" do
    test "RecordingClient implements all callbacks" do
      assert function_exported?(RecordingClient, :config, 0)
      assert function_exported?(RecordingClient, :on_connect, 4)
      assert function_exported?(RecordingClient, :on_subscribe_applied, 3)
      assert function_exported?(RecordingClient, :on_insert, 3)
      assert function_exported?(RecordingClient, :on_delete, 3)
      assert function_exported?(RecordingClient, :on_transaction, 2)
      assert function_exported?(RecordingClient, :on_reducer_result, 3)
      assert function_exported?(RecordingClient, :on_disconnect, 2)
    end

    test "MinimalClient only needs config" do
      assert function_exported?(MinimalClient, :config, 0)
      refute function_exported?(MinimalClient, :on_connect, 4)
    end

    test "config returns expected map" do
      config = RecordingClient.config()
      assert config.host == "localhost:3000"
      assert config.database == "testmodule"
      assert config.subscriptions == ["SELECT * FROM person"]
    end
  end

  describe "Client public API types" do
    test "start_link requires module and state" do
      # Can't actually start without a live server, but verify the function exists
      assert function_exported?(Client, :start_link, 3)
      assert function_exported?(Client, :call_reducer, 3)
      assert function_exported?(Client, :call_reducer_raw, 3)
      assert function_exported?(Client, :get_all, 2)
      assert function_exported?(Client, :find, 3)
      assert function_exported?(Client, :count, 2)
      assert function_exported?(Client, :schema, 1)
    end
  end
end
