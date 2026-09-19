defmodule Spacetimedbex.ClientIntegrationTest do
  @moduledoc """
  Full-flow integration test for the Client behaviour against a live SpacetimeDB.

  Requires: SpacetimeDB running at localhost:3000 with the test_module published.
  Run with: mix test --include integration
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  defmodule TestClient do
    use Spacetimedbex.Client

    def config do
      %{
        host: System.get_env("SPACETIMEDB_HOST", "localhost:3000"),
        database: "testmodule",
        subscriptions: ["SELECT * FROM person"]
      }
    end

    def on_connect(identity, _conn_id, token, state) do
      send(state.test_pid, {:connected, identity, token})
      {:ok, state}
    end

    def on_subscribe_applied(table_name, rows, state) do
      send(state.test_pid, {:subscribed, table_name, rows})
      {:ok, state}
    end

    def on_insert(table_name, row, state) do
      send(state.test_pid, {:insert, table_name, row})
      {:ok, state}
    end

    def on_delete(table_name, row, state) do
      send(state.test_pid, {:delete, table_name, row})
      {:ok, state}
    end

    def on_reducer_result(request_id, result, state) do
      send(state.test_pid, {:reducer_result, request_id, result})
      {:ok, state}
    end

    def on_unsubscribe_applied(query_set_id, rows, state) do
      send(state.test_pid, {:unsubscribe_applied, query_set_id, rows})
      {:ok, state}
    end
  end

  test "full client lifecycle: connect, subscribe, call reducer, observe insert" do
    name = :"test_client_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Spacetimedbex.Client.start_link(
        TestClient,
        %{test_pid: self()},
        name: name
      )

    # Should receive connection callback
    assert_receive {:connected, identity, token}, 10_000
    assert identity =~ ~r/^[0-9a-f]{64}$/
    assert is_binary(token)

    # Should receive subscription with initial rows
    assert_receive {:subscribed, "person", rows}, 10_000
    assert is_list(rows)

    # Call add_person reducer
    {:ok, request_id} =
      Spacetimedbex.Client.call_reducer(pid, "add_person", %{
        "name" => "IntegTestUser",
        "age" => 99
      })

    # Should receive the reducer result for this request
    assert_receive {:reducer_result, ^request_id, {:ok, _, _}}, 10_000

    # Should receive insert callback for the new person
    assert_receive {:insert, "person", row}, 10_000
    assert row["name"] == "IntegTestUser"
    assert row["age"] == 99

    # Verify cache has the row
    all = Spacetimedbex.Client.get_all(pid, "person")
    assert Enum.any?(all, fn r -> r["name"] == "IntegTestUser" end)
    total = Spacetimedbex.Client.count(pid, "person")

    # An overlapping query set is ref-counted: no duplicate rows...
    {:ok, qs} = Spacetimedbex.Client.subscribe(pid, ["SELECT * FROM person WHERE age > 50"])
    assert_receive {:subscribed, "person", overlap}, 10_000
    assert Enum.any?(overlap, &(&1["name"] == "IntegTestUser"))
    assert Spacetimedbex.Client.count(pid, "person") == total

    # ...and dropping it keeps rows the first query set still covers.
    :ok = Spacetimedbex.Client.unsubscribe(pid, qs)
    assert_receive {:unsubscribe_applied, ^qs, [%{table_name: "person", rows: dropped}]}, 10_000
    assert dropped != []
    assert Spacetimedbex.Client.count(pid, "person") == total

    # Dropping the original query set (id 1, from config) empties the cache.
    :ok = Spacetimedbex.Client.unsubscribe(pid, 1)
    assert_receive {:unsubscribe_applied, 1, _}, 10_000
    assert Spacetimedbex.Client.count(pid, "person") == 0
    assert Spacetimedbex.Client.subscriptions(pid) == %{}

    GenServer.stop(pid)
  end
end
