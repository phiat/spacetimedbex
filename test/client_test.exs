defmodule Spacetimedbex.ClientTest do
  use ExUnit.Case, async: false

  alias Spacetimedbex.BSATN.Encoder
  alias Spacetimedbex.Client
  alias Spacetimedbex.ClientCache
  alias Spacetimedbex.ClientCache.{RowDecoder, Store}
  alias Spacetimedbex.Schema
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

    def on_subscription_error(query_set_id, error, state) do
      send(state.test_pid, {:callback, :on_subscription_error, query_set_id, error})
      {:ok, state}
    end
  end

  # --- Callback module without on_update ---

  defmodule InsertDeleteOnlyClient do
    use Spacetimedbex.Client

    def config, do: %{host: "localhost:3000", database: "testmodule"}

    def on_insert(table, row, state) do
      send(state.test_pid, {:callback, :on_insert, table, row})
      {:ok, state}
    end

    def on_delete(table, row, state) do
      send(state.test_pid, {:callback, :on_delete, table, row})
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
    callback_module = Keyword.get(opts, :callback_module, RecordingClient)
    user_state = Keyword.get(opts, :user_state, %{test_pid: self()})

    %Client{
      callback_module: callback_module,
      user_state: user_state,
      store: Store.new(schema),
      conn_pid: self(),
      schema: schema,
      config: %{host: "localhost:3000", database: "testmodule", subscriptions: []},
      connected: Keyword.get(opts, :connected, true)
    }
  end

  # A real server only deletes rows the client already holds, so put a
  # transaction's delete rows into the cache first.
  defp seed(state, query_sets) do
    changes =
      state.schema
      |> RowDecoder.decode_query_sets(query_sets)
      |> Enum.map(&%{&1 | inserts: &1.deletes, deletes: []})

    Store.apply_changes(state.store, changes)
    state
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
              rows: [
                {:persistent,
                 %{inserts: row_list, deletes: %{size_hint: {:fixed_size, 0}, rows_data: <<>>}}}
              ]
            }
          ]
        }
      ]

      {:noreply, _new_state} =
        Client.handle_info(
          {:spacetimedb, {:transaction_update, query_sets}},
          seed(state, query_sets)
        )

      assert_receive {:callback, :on_transaction, changes}

      assert [%{table_name: "person", inserts: [%{"id" => 2, "name" => "Bob"}], deletes: []}] =
               changes

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
              rows: [
                {:persistent,
                 %{inserts: %{size_hint: {:fixed_size, 0}, rows_data: <<>>}, deletes: row_list}}
              ]
            }
          ]
        }
      ]

      {:noreply, _new_state} =
        Client.handle_info(
          {:spacetimedb, {:transaction_update, query_sets}},
          seed(state, query_sets)
        )

      assert_receive {:callback, :on_transaction, _changes}

      assert_receive {:callback, :on_delete, "person",
                      %{"id" => 3, "name" => "Carol", "age" => 40}}
    end

    test "on_transaction with skip_row_callbacks suppresses per-row callbacks" do
      state = build_client_state(user_state: %{test_pid: self(), skip_row_callbacks: true})
      row_list = TestSchema.person_row_list(4, "Dave", 35)

      query_sets = [
        %{
          tables: [
            %{
              table_name: "person",
              rows: [
                {:persistent,
                 %{inserts: row_list, deletes: %{size_hint: {:fixed_size, 0}, rows_data: <<>>}}}
              ]
            }
          ]
        }
      ]

      {:noreply, _new_state} =
        Client.handle_info(
          {:spacetimedb, {:transaction_update, query_sets}},
          seed(state, query_sets)
        )

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
        Client.handle_info({:spacetimedb, {:unsubscribe_applied, 42, nil}}, state)

      assert_receive {:callback, :on_unsubscribe_applied, 42, []}
    end

    test "unsubscribe_applied with dropped rows removes them from the cache" do
      state = build_client_state()
      row_list = TestSchema.person_row_list(1, "Alice", 30)
      table_rows = [%{table_name: "person", rows: row_list}]

      {:noreply, state} =
        Client.handle_info({:spacetimedb, {:subscribe_applied, 1, table_rows}}, state)

      assert Store.count(state.store, "person") == 1

      {:noreply, state} =
        Client.handle_info({:spacetimedb, {:unsubscribe_applied, 1, {:some, table_rows}}}, state)

      assert_receive {:callback, :on_unsubscribe_applied, 1,
                      [%{table_name: "person", rows: [%{"id" => 1}]}]}

      assert Store.count(state.store, "person") == 0
    end

    test "event-table rows fire on_insert and are not cached" do
      state = build_client_state()

      query_sets = [
        %{
          tables: [
            %{table_name: "person", rows: [{:event, TestSchema.person_row_list(9, "Evt", 1)}]}
          ]
        }
      ]

      {:noreply, state} =
        Client.handle_info(
          {:spacetimedb, {:transaction_update, query_sets}},
          seed(state, query_sets)
        )

      assert_receive {:callback, :on_insert, "person", %{"id" => 9}}
      assert Store.count(state.store, "person") == 0
    end

    test "PK update falls back to on_delete + on_insert when on_update is not implemented" do
      state = build_client_state(callback_module: InsertDeleteOnlyClient)

      query_sets = [
        %{
          tables: [
            %{
              table_name: "person",
              rows: [
                {:persistent,
                 %{
                   inserts: TestSchema.person_row_list(1, "Alice", 31),
                   deletes: TestSchema.person_row_list(1, "Alice", 30)
                 }}
              ]
            }
          ]
        }
      ]

      {:noreply, _state} =
        Client.handle_info(
          {:spacetimedb, {:transaction_update, query_sets}},
          seed(state, query_sets)
        )

      assert_receive {:callback, :on_delete, "person", %{"age" => 30}}
      assert_receive {:callback, :on_insert, "person", %{"age" => 31}}
    end

    test "disconnect clears the cache" do
      state = build_client_state()
      table_rows = [%{table_name: "person", rows: TestSchema.person_row_list(1, "Alice", 30)}]

      {:noreply, state} =
        Client.handle_info({:spacetimedb, {:subscribe_applied, 1, table_rows}}, state)

      assert Store.count(state.store, "person") == 1

      {:noreply, state} =
        Client.handle_info({:spacetimedb, {:disconnected, :remote, 1}}, state)

      assert Store.count(state.store, "person") == 0
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
        Client.handle_info(
          {:spacetimedb, {:transaction_update, query_sets}},
          seed(state, query_sets)
        )

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
        Client.handle_info(
          {:spacetimedb, {:transaction_update, query_sets}},
          seed(state, query_sets)
        )

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
        Client.handle_info(
          {:spacetimedb, {:transaction_update, query_sets}},
          seed(state, query_sets)
        )

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

    test "minimal client handles messages without crashing" do
      schema = TestSchema.person_schema()

      state = %Client{
        callback_module: MinimalClient,
        user_state: %{},
        store: Store.new(schema),
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
    test "tables without a primary key keep every distinct row" do
      schema = %Schema{
        tables: %{
          "log" => %{name: "log", columns: [%{name: "msg", type: :string}], primary_key: []}
        },
        reducers: %{},
        typespace: []
      }

      {:ok, cache} = ClientCache.start_link(schema: schema)
      enc = &Encoder.encode_string/1
      rows_data = enc.("a") <> enc.("b") <> enc.("c")
      row_list = %{size_hint: {:row_offsets, [0, 5, 10]}, rows_data: rows_data}

      ClientCache.handle_event(
        cache,
        {:subscribe_applied, 1, [%{table_name: "log", rows: row_list}]}
      )

      assert ClientCache.count(cache, "log") == 3

      ClientCache.apply_changes(cache, [
        %{table_name: "log", inserts: [], deletes: [%{"msg" => "b"}]}
      ])

      assert Enum.sort(ClientCache.get_all(cache, "log")) == [%{"msg" => "a"}, %{"msg" => "c"}]
    end

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

      ClientCache.handle_event(
        cache,
        {:subscribe_applied, 0, [%{table_name: "person", rows: row_list}]}
      )

      Process.sleep(20)

      assert %{"id" => 42, "name" => "Bob"} = ClientCache.find(cache, "person", 42)
      assert ClientCache.find(cache, "person", 999) == nil
    end

    test "count rows" do
      schema = TestSchema.person_schema()
      {:ok, cache} = ClientCache.start_link(schema: schema)
      assert ClientCache.count(cache, "person") == 0

      row_list = TestSchema.person_row_list(1, "Alice", 30)

      ClientCache.handle_event(
        cache,
        {:subscribe_applied, 0, [%{table_name: "person", rows: row_list}]}
      )

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

  describe "request ids and subscriptions" do
    defp call(state, request) do
      {:reply, reply, state} = Client.handle_call(request, {self(), make_ref()}, state)
      {reply, state}
    end

    defp person(id, name, age), do: TestSchema.person_row_list(id, name, age)

    test "call_reducer returns sequential request ids and passes them to the connection" do
      state = build_client_state()

      {{:ok, 1}, state} = call(state, {:call_reducer, "add_person", %{name: "A", age: 1}})
      assert_receive {:"$websockex_cast", {:call_reducer, "add_person", _bsatn, [request_id: 1]}}

      {{:ok, 2}, state} = call(state, {:call_reducer_raw, "add_person", <<>>})
      {{:ok, 3}, state} = call(state, {:one_off_query, "SELECT * FROM person"})
      {{:ok, 4}, _state} = call(state, {:call_procedure_raw, "proc", <<>>})
      assert_receive {:"$websockex_cast", {:one_off_query, _, [request_id: 3]}}
    end

    test "failed encoding does not consume a request id" do
      state = build_client_state()

      {{:error, {:unknown_reducer, "nope"}}, state} = call(state, {:call_reducer, "nope", %{}})

      {{:error, {:out_of_range, :u32, -1}}, state} =
        call(state, {:call_reducer, "add_person", %{name: "A", age: -1}})

      {{:ok, 1}, _} = call(state, {:call_reducer_raw, "add_person", <<>>})
    end

    test "request ids wrap within u32" do
      state = %{build_client_state() | next_request_id: 0xFFFF_FFFF}
      {{:ok, 0xFFFF_FFFF}, state} = call(state, {:call_reducer_raw, "x", <<>>})
      {{:ok, 1}, _} = call(state, {:call_reducer_raw, "x", <<>>})
    end

    test "subscribe while connected sends immediately with the returned query set id" do
      state = build_client_state()
      {{:ok, 1}, state} = call(state, {:subscribe, ["SELECT * FROM person"]})

      assert_receive {:"$websockex_cast",
                      {:subscribe, ["SELECT * FROM person"], [query_set_id: 1, request_id: 1]}}

      assert state.subscriptions == %{1 => ["SELECT * FROM person"]}
    end

    test "subscriptions made while disconnected are sent on connect, and resent after reconnect" do
      state = build_client_state(connected: false)
      {{:ok, 1}, state} = call(state, {:subscribe, ["SELECT * FROM person"]})
      {{:ok, 2}, state} = call(state, {:subscribe, ["SELECT * FROM person WHERE age > 30"]})
      refute_receive {:"$websockex_cast", _}, 20

      {:noreply, state} = Client.handle_info({:spacetimedb, {:identity, "id", "cid", "t"}}, state)
      assert_receive {:"$websockex_cast", {:subscribe, _, [query_set_id: 1, request_id: _]}}
      assert_receive {:"$websockex_cast", {:subscribe, _, [query_set_id: 2, request_id: _]}}

      {:noreply, state} = Client.handle_info({:spacetimedb, {:disconnected, :remote, 1}}, state)
      refute state.connected

      {:noreply, _} = Client.handle_info({:spacetimedb, {:identity, "id", "cid", "t"}}, state)
      assert_receive {:"$websockex_cast", {:subscribe, _, [query_set_id: 1, request_id: _]}}
      assert_receive {:"$websockex_cast", {:subscribe, _, [query_set_id: 2, request_id: _]}}
    end

    test "unsubscribe validates the query set and requests dropped rows" do
      state = build_client_state()

      {{:error, :unknown_query_set}, state} =
        call(state, {:unsubscribe, 9, [send_dropped_rows: true]})

      {{:ok, qs}, state} = call(state, {:subscribe, ["SELECT * FROM person"]})
      {:ok, state} = call(state, {:unsubscribe, qs, [send_dropped_rows: true]})
      assert state.subscriptions == %{}

      assert_receive {:"$websockex_cast",
                      {:unsubscribe, ^qs, [request_id: _, send_dropped_rows: true]}}
    end

    test "subscription_error deactivates the query set and fires the callback" do
      state = build_client_state()
      {{:ok, qs}, state} = call(state, {:subscribe, ["SELECT * FROM nope"]})

      {:noreply, state} =
        Client.handle_info({:spacetimedb, {:subscription_error, qs, "no such table"}}, state)

      assert_receive {:callback, :on_subscription_error, ^qs, "no such table"}
      assert state.subscriptions == %{}
    end

    test "rows shared by overlapping query sets are ref-counted" do
      state = build_client_state()
      alice = person(1, "Alice", 30)

      {:noreply, state} =
        Client.handle_info(
          {:spacetimedb, {:subscribe_applied, 1, [%{table_name: "person", rows: alice}]}},
          state
        )

      {:noreply, state} =
        Client.handle_info(
          {:spacetimedb, {:subscribe_applied, 2, [%{table_name: "person", rows: alice}]}},
          state
        )

      assert Store.count(state.store, "person") == 1

      # The same insert reported by both query sets fires on_insert once.
      bob = person(2, "Bob", 40)
      empty = %{size_hint: {:fixed_size, 0}, rows_data: <<>>}
      insert_bob = {:persistent, %{inserts: bob, deletes: empty}}

      both = fn rows ->
        for qs <- [1, 2], do: %{query_set_id: qs, tables: [%{table_name: "person", rows: [rows]}]}
      end

      {:noreply, state} =
        Client.handle_info({:spacetimedb, {:transaction_update, both.(insert_bob)}}, state)

      assert_receive {:callback, :on_insert, "person", %{"id" => 2}}
      refute_receive {:callback, :on_insert, "person", %{"id" => 2}}, 20

      # Dropping one overlapping query set keeps shared rows cached.
      dropped = {:some, [%{table_name: "person", rows: person(1, "Alice", 30)}]}

      {:noreply, state} =
        Client.handle_info({:spacetimedb, {:unsubscribe_applied, 1, dropped}}, state)

      assert Store.find(state.store, "person", 1)["name"] == "Alice"

      {:noreply, state} =
        Client.handle_info({:spacetimedb, {:unsubscribe_applied, 2, dropped}}, state)

      assert Store.find(state.store, "person", 1) == nil
      assert Store.count(state.store, "person") == 1
    end

    test "primary-key index follows updates" do
      state = build_client_state()

      {:noreply, state} =
        Client.handle_info(
          {:spacetimedb,
           {:subscribe_applied, 1, [%{table_name: "person", rows: person(1, "Alice", 30)}]}},
          state
        )

      update = [
        %{
          query_set_id: 1,
          tables: [
            %{
              table_name: "person",
              rows: [
                {:persistent, %{inserts: person(1, "Alice", 31), deletes: person(1, "Alice", 30)}}
              ]
            }
          ]
        }
      ]

      {:noreply, state} = Client.handle_info({:spacetimedb, {:transaction_update, update}}, state)
      assert_receive {:callback, :on_update, "person", %{"age" => 30}, %{"age" => 31}}
      assert %{"age" => 31} = Store.find(state.store, "person", 1)
      assert Store.count(state.store, "person") == 1
    end
  end
end
