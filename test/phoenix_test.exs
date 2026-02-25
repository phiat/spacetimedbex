defmodule Spacetimedbex.PhoenixTest do
  use ExUnit.Case, async: false

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
    setup do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})
      {:ok, pubsub: pubsub_name}
    end

    test "on_insert broadcasts to table topic", %{pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, "spacetimedb:person")

      state = %{pubsub: pubsub}
      row = %{"id" => 1, "name" => "Alice", "age" => 30}

      {:ok, ^state} = Spacetimedbex.Phoenix.on_insert("person", row, state)

      assert_receive {:spacetimedb, :insert, "person", ^row}
    end

    test "on_delete broadcasts to table topic", %{pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, "spacetimedb:person")

      state = %{pubsub: pubsub}
      row = %{"id" => 2, "name" => "Bob", "age" => 25}

      {:ok, ^state} = Spacetimedbex.Phoenix.on_delete("person", row, state)

      assert_receive {:spacetimedb, :delete, "person", ^row}
    end

    test "on_reducer_result broadcasts to reducers topic", %{pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, "spacetimedb:reducers")

      state = %{pubsub: pubsub}

      {:ok, ^state} = Spacetimedbex.Phoenix.on_reducer_result(42, :ok_empty, state)

      assert_receive {:spacetimedb, :reducer_result, 42, :ok_empty}
    end
  end
end
