defmodule Spacetimedbex.ConnectionTest do
  use ExUnit.Case, async: true

  alias Spacetimedbex.Connection

  describe "build_url (via struct inspection)" do
    test "state struct has correct defaults" do
      state = %Connection{
        host: "localhost:3000",
        database: "test_db",
        handler: self()
      }

      assert state.next_request_id == 1
      assert state.next_query_set_id == 1
      assert state.pending_requests == %{}
      assert state.connected == false
      assert state.identity == nil
      assert state.token == nil
    end
  end

  describe "server message handling via handle_frame" do
    test "decodes InitialConnection and updates state" do
      alias Spacetimedbex.BSATN.Encoder

      identity = :crypto.strong_rand_bytes(32)
      connection_id = :crypto.strong_rand_bytes(16)
      token = "test-jwt-token"

      bsatn = <<0>> <> identity <> connection_id <> Encoder.encode_string(token)
      # Add compression envelope (none)
      frame = <<0x00>> <> bsatn

      state = %Connection{
        host: "localhost:3000",
        database: "test_db",
        handler: self(),
        connected: true
      }

      assert {:ok, new_state} = Connection.handle_frame({:binary, frame}, state)
      assert new_state.identity == identity
      assert new_state.connection_id == connection_id
      assert new_state.token == token

      assert_receive {:spacetimedb, {:identity, ^identity, ^connection_id, ^token}}
    end

    test "decodes ReducerResult OkEmpty and notifies handler" do
      alias Spacetimedbex.BSATN.Encoder

      request_id = 42
      timestamp = 1_700_000_000_000_000_000

      bsatn =
        <<6>> <>
          Encoder.encode_u32(request_id) <>
          Encoder.encode_i64(timestamp) <>
          <<1>>

      frame = <<0x00>> <> bsatn

      state = %Connection{
        host: "localhost:3000",
        database: "test_db",
        handler: self(),
        connected: true,
        pending_requests: %{42 => {:call_reducer, "test_reducer"}}
      }

      assert {:ok, new_state} = Connection.handle_frame({:binary, frame}, state)
      assert new_state.pending_requests == %{}

      assert_receive {:spacetimedb, {:reducer_result, 42, ^timestamp, :ok_empty}}
    end

    test "handles gzip-compressed frames" do
      alias Spacetimedbex.BSATN.Encoder

      identity = :crypto.strong_rand_bytes(32)
      connection_id = :crypto.strong_rand_bytes(16)
      token = "compressed-token"

      bsatn = <<0>> <> identity <> connection_id <> Encoder.encode_string(token)
      compressed = :zlib.gzip(bsatn)
      frame = <<0x02>> <> compressed

      state = %Connection{
        host: "localhost:3000",
        database: "test_db",
        handler: self(),
        connected: true
      }

      assert {:ok, new_state} = Connection.handle_frame({:binary, frame}, state)
      assert new_state.token == token
      assert_receive {:spacetimedb, {:identity, _, _, ^token}}
    end

    test "handles SubscriptionError with optional request_id" do
      alias Spacetimedbex.BSATN.Encoder

      # Option::Some(5)
      request_id_some = <<0>> <> Encoder.encode_u32(5)
      query_set_id = Encoder.encode_u32(10)
      error = Encoder.encode_string("invalid SQL")

      bsatn = <<3>> <> request_id_some <> query_set_id <> error
      frame = <<0x00>> <> bsatn

      state = %Connection{
        host: "localhost:3000",
        database: "test_db",
        handler: self(),
        connected: true,
        pending_requests: %{5 => {:subscribe, 10, ["bad query"]}}
      }

      assert {:ok, new_state} = Connection.handle_frame({:binary, frame}, state)
      assert new_state.pending_requests == %{}
      assert_receive {:spacetimedb, {:subscription_error, 10, "invalid SQL"}}
    end

    test "warns on decompression failure" do
      frame = <<0xFF, 1, 2, 3>>

      state = %Connection{
        host: "localhost:3000",
        database: "test_db",
        handler: self(),
        connected: true
      }

      assert {:ok, ^state} = Connection.handle_frame({:binary, frame}, state)
    end
  end

  describe "client message encoding via handle_cast" do
    test "subscribe generates binary frame with incrementing IDs" do
      state = %Connection{
        host: "localhost:3000",
        database: "test_db",
        handler: self(),
        connected: true
      }

      assert {:reply, {:binary, data}, new_state} =
               Connection.handle_cast({:subscribe, ["SELECT * FROM t"]}, state)

      # Should be tag 0 (Subscribe)
      assert <<0, _::binary>> = data
      assert new_state.next_request_id == 2
      assert new_state.next_query_set_id == 2
      assert Map.has_key?(new_state.pending_requests, 1)

      assert_receive {:spacetimedb, {:subscribe_sent, 1, 1}}
    end

    test "call_reducer generates binary frame" do
      state = %Connection{
        host: "localhost:3000",
        database: "test_db",
        handler: self(),
        connected: true,
        next_request_id: 10
      }

      assert {:reply, {:binary, data}, new_state} =
               Connection.handle_cast({:call_reducer, "do_thing", <<>>}, state)

      # Should be tag 3 (CallReducer)
      assert <<3, _::binary>> = data
      assert new_state.next_request_id == 11
      assert Map.has_key?(new_state.pending_requests, 10)
    end

    test "one_off_query generates binary frame" do
      state = %Connection{
        host: "localhost:3000",
        database: "test_db",
        handler: self(),
        connected: true
      }

      assert {:reply, {:binary, data}, new_state} =
               Connection.handle_cast({:one_off_query, "SELECT 1"}, state)

      assert <<2, _::binary>> = data
      assert new_state.next_request_id == 2
    end

    test "unsubscribe generates binary frame" do
      state = %Connection{
        host: "localhost:3000",
        database: "test_db",
        handler: self(),
        connected: true
      }

      assert {:reply, {:binary, data}, new_state} =
               Connection.handle_cast({:unsubscribe, 5, :default}, state)

      assert <<1, _::binary>> = data
      assert new_state.next_request_id == 2
    end

    test "get_state sends sanitized state to caller" do
      state = %Connection{
        host: "localhost:3000",
        database: "test_db",
        handler: self(),
        connected: true,
        token: "secret-token",
        identity: <<1::256>>,
        connection_id: <<2::128>>
      }

      ref = make_ref()
      assert {:ok, ^state} = Connection.handle_cast({:get_state, self(), ref}, state)

      assert_receive {:spacetimedb_state, ^ref, info}
      assert info.host == "localhost:3000"
      assert info.connected == true
      # Token should not be in sanitized state
      refute Map.has_key?(info, :token)
    end
  end
end
