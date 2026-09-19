defmodule Spacetimedbex.IntegrationTest do
  @moduledoc """
  Integration tests against a live SpacetimeDB instance.

  Requires:
  - spacetimedb-standalone running on localhost:3000
  - testmodule database published (see test_module/)

  Run with: mix test test/integration_test.exs
  Skip with: mix test --exclude integration
  """
  use ExUnit.Case

  @moduletag :integration

  alias Spacetimedbex.BSATN.Encoder
  alias Spacetimedbex.Connection

  @host System.get_env("SPACETIMEDB_HOST", "localhost:3000")
  @database "testmodule"

  test "connect and receive identity" do
    {:ok, conn} =
      Connection.start_link(
        host: @host,
        database: @database,
        handler: self(),
        compression: :none
      )

    assert_receive {:spacetimedb, {:identity, identity, connection_id, token}}, 5_000

    assert identity =~ ~r/^[0-9a-f]{64}$/
    assert connection_id =~ ~r/^[0-9a-f]{32}$/
    assert is_binary(token)
    assert String.length(token) > 0

    state = Connection.get_state(conn)
    assert state.connected == true
    refute Map.has_key?(state, :token)

    Process.exit(conn, :normal)
  end

  test "WebSocket identity matches the hex identity from the HTTP API" do
    {:ok, %{"identity" => http_identity, "token" => token}} =
      Spacetimedbex.Http.create_identity(@host)

    {:ok, conn} =
      Connection.start_link(host: @host, database: @database, handler: self(), token: token)

    assert_receive {:spacetimedb, {:identity, ws_identity, _, _}}, 5_000
    assert ws_identity == http_identity

    Process.exit(conn, :normal)
  end

  test "subscribe to person table" do
    {:ok, conn} =
      Connection.start_link(
        host: @host,
        database: @database,
        handler: self(),
        compression: :none
      )

    assert_receive {:spacetimedb, {:identity, _, _, _}}, 5_000

    Connection.subscribe(conn, ["SELECT * FROM person"])
    assert_receive {:spacetimedb, {:subscribe_sent, query_set_id, _request_id}}, 1_000

    assert_receive {:spacetimedb, {:subscribe_applied, ^query_set_id, _rows}}, 5_000

    Process.exit(conn, :normal)
  end

  test "call reducer and observe transaction update" do
    {:ok, conn} =
      Connection.start_link(
        host: @host,
        database: @database,
        handler: self(),
        compression: :none
      )

    assert_receive {:spacetimedb, {:identity, _, _, _}}, 5_000

    # Subscribe first so we get transaction updates
    Connection.subscribe(conn, ["SELECT * FROM person"])
    assert_receive {:spacetimedb, {:subscribe_sent, _qsid, _rid}}, 1_000
    assert_receive {:spacetimedb, {:subscribe_applied, _, _}}, 5_000

    # Call add_person reducer with BSATN-encoded args: (name: String, age: u32)
    args =
      Encoder.encode_product([
        Encoder.encode_string("Alice"),
        Encoder.encode_u32(30)
      ])

    Connection.call_reducer(conn, "add_person", args)

    # Should get a reducer result — may be :ok_empty or {:ok, ret_value, tx_update}
    # Also may get a separate transaction_update for subscription deltas
    assert_receive {:spacetimedb, msg}, 5_000

    # Collect all messages that arrive within a short window
    messages = collect_messages(500)
    all_messages = [msg | messages]

    # At least one message should be reducer-related or a transaction update
    has_reducer_result =
      Enum.any?(all_messages, fn
        {:reducer_result, _, _, _} -> true
        _ -> false
      end)

    has_tx_update =
      Enum.any?(all_messages, fn
        {:transaction_update, _} -> true
        {:reducer_result, _, _, {:ok, _, %{query_sets: _}}} -> true
        {:reducer_result, _, _, :ok_empty} -> true
        _ -> false
      end)

    assert has_reducer_result or has_tx_update,
           "Expected reducer_result or transaction_update, got: #{inspect(all_messages)}"

    # Reducer timestamps decode to a DateTime close to now
    timestamps = for {:reducer_result, _, ts, _} <- all_messages, do: ts
    assert [%DateTime{} = ts | _] = timestamps
    assert abs(DateTime.diff(ts, DateTime.utc_now())) < 60

    Process.exit(conn, :normal)
  end

  test "reconnect with saved token" do
    {:ok, conn1} =
      Connection.start_link(
        host: @host,
        database: @database,
        handler: self(),
        compression: :none
      )

    assert_receive {:spacetimedb, {:identity, identity1, _, token}}, 5_000
    Process.exit(conn1, :normal)
    Process.sleep(100)

    # Reconnect with the saved token — should get same identity
    {:ok, conn2} =
      Connection.start_link(
        host: @host,
        database: @database,
        handler: self(),
        token: token,
        compression: :none
      )

    assert_receive {:spacetimedb, {:identity, identity2, _, _}}, 5_000
    assert identity1 == identity2

    Process.exit(conn2, :normal)
  end

  defp collect_messages(timeout_ms) do
    collect_messages(timeout_ms, [])
  end

  defp collect_messages(timeout_ms, acc) do
    receive do
      {:spacetimedb, msg} -> collect_messages(timeout_ms, [msg | acc])
    after
      timeout_ms -> Enum.reverse(acc)
    end
  end
end
