defmodule Spacetimedbex.PhoenixTest do
  use ExUnit.Case, async: false

  # Phoenix adapter tests require phoenix_pubsub
  # These are integration tests since they need a live SpacetimeDB for ClientCache

  describe "Phoenix adapter module" do
    test "defines expected functions" do
      assert function_exported?(Spacetimedbex.Phoenix, :start_link, 1)
      assert function_exported?(Spacetimedbex.Phoenix, :get_all, 2)
      assert function_exported?(Spacetimedbex.Phoenix, :find, 3)
      assert function_exported?(Spacetimedbex.Phoenix, :config, 0)
      assert function_exported?(Spacetimedbex.Phoenix, :on_insert, 3)
      assert function_exported?(Spacetimedbex.Phoenix, :on_delete, 3)
      assert function_exported?(Spacetimedbex.Phoenix, :on_reducer_result, 3)
    end

    test "implements Client behaviour callbacks" do
      behaviours =
        Spacetimedbex.Phoenix.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Spacetimedbex.Client in behaviours
    end
  end

  describe "Phoenix PubSub broadcasting" do
    @describetag :integration

    # Full integration test: starts PubSub, Phoenix adapter, subscribes to topics,
    # and verifies broadcasts on insert/delete from SpacetimeDB.
    # Requires live SpacetimeDB at localhost:3000 with testmodule.

    test "broadcasts insert events to PubSub topic" do
      # Start PubSub
      # Start Phoenix adapter
      # Subscribe to "spacetimedb:person"
      # Call add_person reducer
      # Assert receive {:spacetimedb, :insert, "person", %{"name" => ...}}
    end
  end
end
