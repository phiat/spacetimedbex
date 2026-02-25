defmodule Spacetimedbex.ClientCacheIntegrationTest do
  @moduledoc """
  Integration test for ClientCache against live SpacetimeDB.
  Verifies schema fetch, row decoding, and cache population end-to-end.
  """
  use ExUnit.Case

  @moduletag :integration

  alias Spacetimedbex.{Connection, ClientCache, Schema}
  alias Spacetimedbex.BSATN.Encoder

  @host "localhost:3000"
  @database "testmodule"

  test "fetch schema from live server" do
    {:ok, schema} = Schema.fetch(@host, @database)

    assert Map.has_key?(schema.tables, "person")
    person = schema.tables["person"]
    assert person.primary_key == [0]

    col_names = Enum.map(person.columns, & &1.name)
    assert col_names == ["id", "name", "age"]

    col_types = Enum.map(person.columns, & &1.type)
    assert col_types == [:u64, :string, :u32]

    assert Map.has_key?(schema.reducers, "add_person")
    assert Map.has_key?(schema.reducers, "say_hello")
  end

  test "cache starts and creates ETS tables" do
    {:ok, cache} = ClientCache.start_link(host: @host, database: @database)

    schema = ClientCache.schema(cache)
    assert Map.has_key?(schema.tables, "person")

    assert ClientCache.count(cache, "person") == 0
    assert ClientCache.get_all(cache, "person") == []
    assert ClientCache.find(cache, "person", 1) == nil

    GenServer.stop(cache)
  end

  test "full flow: connect, subscribe, call reducer, cache populates" do
    {:ok, cache} = ClientCache.start_link(host: @host, database: @database, handler: self())

    # Start connection with a handler that feeds events to cache
    handler = spawn_link(fn -> event_forwarder(cache) end)

    {:ok, conn} =
      Connection.start_link(
        host: @host,
        database: @database,
        handler: handler,
        compression: :none
      )

    # Wait for identity
    Process.sleep(200)

    # Subscribe to person table
    Connection.subscribe(conn, ["SELECT * FROM person"])

    # Wait for subscribe_applied to be processed by cache
    assert_receive {:cache_event, :subscribe_applied}, 5_000

    # Insert a person via reducer
    name = "CacheTest_#{System.unique_integer([:positive])}"

    args =
      Encoder.encode_product([
        Encoder.encode_string(name),
        Encoder.encode_u32(99)
      ])

    Connection.call_reducer(conn, "add_person", args)

    # Wait for reducer result or transaction update to be processed by cache
    assert_receive {:cache_event, event}, 5_000
    assert event in [:transaction_update, :reducer_result]

    # Verify the person is in the cache
    all_persons = ClientCache.get_all(cache, "person")
    assert Enum.any?(all_persons, fn p -> p["name"] == name and p["age"] == 99 end)

    Process.exit(conn, :normal)
    GenServer.stop(cache)
  end

  # Forwards SpacetimeDB events to ClientCache
  defp event_forwarder(cache) do
    receive do
      {:spacetimedb, event} ->
        ClientCache.handle_event(cache, event)
        event_forwarder(cache)
    end
  end
end
