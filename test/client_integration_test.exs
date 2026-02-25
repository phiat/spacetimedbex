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
        host: "localhost:3000",
        database: "testmodule",
        subscriptions: ["SELECT * FROM person"]
      }
    end

    def on_connect(_identity, _conn_id, token, state) do
      send(state.test_pid, {:connected, token})
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
    assert_receive {:connected, token}, 10_000
    assert is_binary(token)

    # Should receive subscription with initial rows
    assert_receive {:subscribed, "person", rows}, 10_000
    assert is_list(rows)

    # Call add_person reducer
    :ok = Spacetimedbex.Client.call_reducer(pid, "add_person", %{"name" => "IntegTestUser", "age" => 99})

    # Should receive reducer result
    assert_receive {:reducer_result, _req_id, _result}, 10_000

    # Should receive insert callback for the new person
    assert_receive {:insert, "person", row}, 10_000
    assert row["name"] == "IntegTestUser"
    assert row["age"] == 99

    # Verify cache has the row
    all = Spacetimedbex.Client.get_all(pid, "person")
    assert Enum.any?(all, fn r -> r["name"] == "IntegTestUser" end)

    GenServer.stop(pid)
  end
end
