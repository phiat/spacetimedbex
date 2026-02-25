defmodule Spacetimedbex.ClientTest do
  use ExUnit.Case, async: false

  alias Spacetimedbex.Client
  alias Spacetimedbex.ClientCache
  alias Spacetimedbex.TestSchema

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

    def on_update(table_name, old_row, new_row, state) do
      send(state.test_pid, {:callback, :on_update, table_name, old_row, new_row})
      {:ok, state}
    end

    def on_unsubscribe_applied(query_set_id, rows, state) do
      send(state.test_pid, {:callback, :on_unsubscribe_applied, query_set_id, rows})
      {:ok, state}
    end

    def on_query_result(request_id, result, state) do
      send(state.test_pid, {:callback, :on_query_result, request_id, result})
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

  # --- Helper to build a Client state struct for direct handle_info testing ---

  defp build_client_state(opts \\ []) do
    schema = TestSchema.person_schema()
    {:ok, cache_pid} = ClientCache.start_link(schema: schema)

    callback_module = Keyword.get(opts, :callback_module, RecordingClient)
    user_state = Keyword.get(opts, :user_state, %{test_pid: self()})

    %Client{
      callback_module: callback_module,
      user_state: user_state,
      cache_pid: cache_pid,
      conn_pid: self(),
      schema: schema,
      config: %{host: "localhost:3000", database: "testmodule", subscriptions: []}
    }
  end

  describe "Client module defines behaviour" do
    test "RecordingClient implements all callbacks" do
      assert function_exported?(RecordingClient, :config, 0)
      assert function_exported?(RecordingClient, :on_connect, 4)
      assert function_exported?(RecordingClient, :on_subscribe_applied, 3)
      assert function_exported?(RecordingClient, :on_insert, 3)
      assert function_exported?(RecordingClient, :on_delete, 3)
      assert function_exported?(RecordingClient, :on_update, 4)
      assert function_exported?(RecordingClient, :on_transaction, 2)
      assert function_exported?(RecordingClient, :on_reducer_result, 3)
      assert function_exported?(RecordingClient, :on_unsubscribe_applied, 3)
      assert function_exported?(RecordingClient, :on_query_result, 3)
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
      assert function_exported?(Client, :start_link, 3)
      assert function_exported?(Client, :call_reducer, 3)
      assert function_exported?(Client, :call_reducer_raw, 3)
      assert function_exported?(Client, :unsubscribe, 3)
      assert function_exported?(Client, :query, 2)
      assert function_exported?(Client, :get_all, 2)
      assert function_exported?(Client, :find, 3)
      assert function_exported?(Client, :count, 2)
      assert function_exported?(Client, :schema, 1)
    end
  end

  describe "synthetic message handling" do
    test "on_connect fires on identity message" do
      state = build_client_state()
      identity = <<1, 2, 3, 4>>
      conn_id = <<5, 6, 7, 8>>
      token = "test-token"

      {:noreply, _new_state} =
        Client.handle_info({:spacetimedb, {:identity, identity, conn_id, token}}, state)

      assert_receive {:callback, :on_connect, ^identity, ^conn_id, ^token}
    end

    test "subscribe_applied fires per-table callbacks" do
      state = build_client_state()
      row_list = TestSchema.person_row_list(1, "Alice", 30)

      table_rows = [%{table_name: "person", rows: row_list}]

      {:noreply, _new_state} =
        Client.handle_info({:spacetimedb, {:subscribe_applied, 0, table_rows}}, state)

      assert_receive {:callback, :on_subscribe_applied, "person", rows}
      assert [%{"id" => 1, "name" => "Alice", "age" => 30}] = rows
    end

    test "transaction_update fires insert callbacks" do
      state = build_client_state()
      row_list = TestSchema.person_row_list(2, "Bob", 25)

      query_sets = [
        %{
          tables: [
            %{
              table_name: "person",
              rows: [{:persistent, %{inserts: row_list, deletes: %{size_hint: {:fixed_size, 0}, rows_data: <<>>}}}]
            }
          ]
        }
      ]

      {:noreply, _new_state} =
        Client.handle_info({:spacetimedb, {:transaction_update, query_sets}}, state)

      assert_receive {:callback, :on_transaction, changes}
      assert [%{table_name: "person", inserts: [%{"id" => 2, "name" => "Bob"}], deletes: []}] = changes

      assert_receive {:callback, :on_insert, "person", %{"id" => 2, "name" => "Bob", "age" => 25}}
    end

    test "transaction_update fires delete callbacks" do
      state = build_client_state()
      row_list = TestSchema.person_row_list(3, "Carol", 40)

      query_sets = [
        %{
          tables: [
            %{
              table_name: "person",
              rows: [{:persistent, %{inserts: %{size_hint: {:fixed_size, 0}, rows_data: <<>>}, deletes: row_list}}]
            }
          ]
        }
      ]

      {:noreply, _new_state} =
        Client.handle_info({:spacetimedb, {:transaction_update, query_sets}}, state)

      assert_receive {:callback, :on_transaction, _changes}
      assert_receive {:callback, :on_delete, "person", %{"id" => 3, "name" => "Carol", "age" => 40}}
    end

    test "on_transaction with skip_row_callbacks suppresses per-row callbacks" do
      state = build_client_state(user_state: %{test_pid: self(), skip_row_callbacks: true})
      row_list = TestSchema.person_row_list(4, "Dave", 35)

      query_sets = [
        %{
          tables: [
            %{
              table_name: "person",
              rows: [{:persistent, %{inserts: row_list, deletes: %{size_hint: {:fixed_size, 0}, rows_data: <<>>}}}]
            }
          ]
        }
      ]

      {:noreply, _new_state} =
        Client.handle_info({:spacetimedb, {:transaction_update, query_sets}}, state)

      assert_receive {:callback, :on_transaction, _changes}
      refute_receive {:callback, :on_insert, _, _}, 50
    end

    test "reducer_result fires callback" do
      state = build_client_state()

      {:noreply, _new_state} =
        Client.handle_info({:spacetimedb, {:reducer_result, 42, 123_456, :ok_empty}}, state)

      assert_receive {:callback, :on_reducer_result, 42, :ok_empty}
    end

    test "disconnect fires callback" do
      state = build_client_state()

      {:noreply, _new_state} =
        Client.handle_info({:spacetimedb, {:disconnected, :normal, 0}}, state)

      assert_receive {:callback, :on_disconnect, :normal}
    end

    test "unsubscribe_applied fires callback" do
      state = build_client_state()

      {:noreply, _new_state} =
        Client.handle_info({:spacetimedb, {:unsubscribe_applied, 42, []}}, state)

      assert_receive {:callback, :on_unsubscribe_applied, 42, []}
    end

    test "one_off_query_result fires callback" do
      state = build_client_state()

      {:noreply, _new_state} =
        Client.handle_info({:spacetimedb, {:one_off_query_result, 7, {:ok, []}}}, state)

      assert_receive {:callback, :on_query_result, 7, {:ok, []}}
    end

    test "transaction with PK-matched delete+insert fires on_update" do
      state = build_client_state()
      old_row_list = TestSchema.person_row_list(1, "Alice", 30)
      new_row_list = TestSchema.person_row_list(1, "Alice", 31)

      # Combine into one rows_data for deletes and inserts
      query_sets = [
        %{
          tables: [
            %{
              table_name: "person",
              rows: [
                {:persistent, %{inserts: new_row_list, deletes: old_row_list}}
              ]
            }
          ]
        }
      ]

      {:noreply, _new_state} =
        Client.handle_info({:spacetimedb, {:transaction_update, query_sets}}, state)

      assert_receive {:callback, :on_transaction, _changes}

      # Should fire on_update, NOT separate on_delete + on_insert
      assert_receive {:callback, :on_update, "person", %{"id" => 1, "age" => 30},
                      %{"id" => 1, "age" => 31}}

      refute_receive {:callback, :on_insert, _, _}, 50
      refute_receive {:callback, :on_delete, _, _}, 50
    end

    test "transaction with non-matching PKs fires separate insert and delete" do
      state = build_client_state()
      delete_row = TestSchema.person_row_list(1, "Alice", 30)
      insert_row = TestSchema.person_row_list(2, "Bob", 25)

      query_sets = [
        %{
          tables: [
            %{
              table_name: "person",
              rows: [
                {:persistent, %{inserts: insert_row, deletes: delete_row}}
              ]
            }
          ]
        }
      ]

      {:noreply, _new_state} =
        Client.handle_info({:spacetimedb, {:transaction_update, query_sets}}, state)

      assert_receive {:callback, :on_transaction, _}
      assert_receive {:callback, :on_delete, "person", %{"id" => 1}}
      assert_receive {:callback, :on_insert, "person", %{"id" => 2}}
      refute_receive {:callback, :on_update, _, _, _}, 50
    end

    test "mixed transaction: some updates, some pure inserts/deletes" do
      state = build_client_state()

      # Use equal-length names so fixed_size row splitting works correctly
      # Delete id=1 (old), insert id=1 (new) → update
      # Delete id=2 → pure delete
      # Insert id=3 → pure insert
      delete_rows = TestSchema.person_row_list_multi([{1, "Alice", 30}, {2, "Berta", 25}])
      insert_rows = TestSchema.person_row_list_multi([{1, "Alice", 31}, {3, "Carol", 40}])

      query_sets = [
        %{
          tables: [
            %{
              table_name: "person",
              rows: [{:persistent, %{inserts: insert_rows, deletes: delete_rows}}]
            }
          ]
        }
      ]

      {:noreply, _new_state} =
        Client.handle_info({:spacetimedb, {:transaction_update, query_sets}}, state)

      assert_receive {:callback, :on_transaction, _}
      assert_receive {:callback, :on_delete, "person", %{"id" => 2, "name" => "Berta"}}

      assert_receive {:callback, :on_update, "person", %{"id" => 1, "age" => 30},
                      %{"id" => 1, "age" => 31}}

      assert_receive {:callback, :on_insert, "person", %{"id" => 3, "name" => "Carol"}}
    end

    test "unknown message does not crash" do
      state = build_client_state()

      {:noreply, new_state} =
        Client.handle_info({:spacetimedb, {:some_future_message, "data"}}, state)

      assert new_state == state
    end

    test "cache_event is ignored" do
      state = build_client_state()

      {:noreply, new_state} = Client.handle_info({:cache_event, :subscribe_applied}, state)
      assert new_state == state
    end

    test "minimal client handles messages without crashing" do
      schema = TestSchema.person_schema()
      {:ok, cache_pid} = ClientCache.start_link(schema: schema)

      state = %Client{
        callback_module: MinimalClient,
        user_state: %{},
        cache_pid: cache_pid,
        conn_pid: self(),
        schema: schema,
        config: %{host: "localhost:3000", database: "testmodule", subscriptions: []}
      }

      # These should not crash even though MinimalClient has no callbacks
      {:noreply, _} =
        Client.handle_info({:spacetimedb, {:identity, <<>>, <<>>, "tok"}}, state)

      row_list = TestSchema.person_row_list(1, "Test", 20)
      table_rows = [%{table_name: "person", rows: row_list}]

      {:noreply, _} =
        Client.handle_info({:spacetimedb, {:subscribe_applied, 0, table_rows}}, state)

      {:noreply, _} =
        Client.handle_info({:spacetimedb, {:disconnected, :normal, 0}}, state)
    end
  end

  describe "ClientCache with injected schema" do
    test "starts without HTTP fetch" do
      schema = TestSchema.person_schema()
      {:ok, cache} = ClientCache.start_link(schema: schema)
      assert ClientCache.schema(cache) == schema
    end

    test "insert and query via events" do
      schema = TestSchema.person_schema()
      {:ok, cache} = ClientCache.start_link(schema: schema)

      row_list = TestSchema.person_row_list(1, "Alice", 30)
      table_rows = [%{table_name: "person", rows: row_list}]
      ClientCache.handle_event(cache, {:subscribe_applied, 0, table_rows})

      # Give the cast time to process
      Process.sleep(20)

      rows = ClientCache.get_all(cache, "person")
      assert length(rows) == 1
      assert [%{"id" => 1, "name" => "Alice", "age" => 30}] = rows
    end

    test "find by primary key" do
      schema = TestSchema.person_schema()
      {:ok, cache} = ClientCache.start_link(schema: schema)

      row_list = TestSchema.person_row_list(42, "Bob", 25)
      ClientCache.handle_event(cache, {:subscribe_applied, 0, [%{table_name: "person", rows: row_list}]})
      Process.sleep(20)

      assert %{"id" => 42, "name" => "Bob"} = ClientCache.find(cache, "person", 42)
      assert ClientCache.find(cache, "person", 999) == nil
    end

    test "count rows" do
      schema = TestSchema.person_schema()
      {:ok, cache} = ClientCache.start_link(schema: schema)
      assert ClientCache.count(cache, "person") == 0

      row_list = TestSchema.person_row_list(1, "Alice", 30)
      ClientCache.handle_event(cache, {:subscribe_applied, 0, [%{table_name: "person", rows: row_list}]})
      Process.sleep(20)

      assert ClientCache.count(cache, "person") == 1
    end
  end

  describe "ValueEncoder integration via call_reducer" do
    @tag :integration
    test "call_reducer encodes args from schema" do
      # This would need a live SpacetimeDB, skip in unit tests
    end
  end
end
