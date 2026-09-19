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

      identity_int = 0xDEAD_BEEF
      connection_id_int = 0x42
      identity = <<identity_int::little-256>>
      connection_id = <<connection_id_int::little-128>>
      identity_hex = Spacetimedbex.Types.identity_from_int(identity_int)
      connection_id_hex = Spacetimedbex.Types.connection_id_from_int(connection_id_int)
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
      assert new_state.identity == identity_hex
      assert String.ends_with?(identity_hex, "deadbeef")
      assert new_state.connection_id == connection_id_hex
      assert new_state.token == token

      assert_receive {:spacetimedb, {:identity, ^identity_hex, ^connection_id_hex, ^token}}
    end

    test "decodes ReducerResult OkEmpty and notifies handler" do
      alias Spacetimedbex.BSATN.Encoder

      request_id = 42
      # Timestamps are microseconds since the Unix epoch
      timestamp_us = 1_700_000_000_000_000
      timestamp = DateTime.from_unix!(timestamp_us, :microsecond)

      bsatn =
        <<6>> <>
          Encoder.encode_u32(request_id) <>
          Encoder.encode_i64(timestamp_us) <>
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
               Connection.handle_cast({:subscribe, ["SELECT * FROM t"], []}, state)

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
               Connection.handle_cast({:call_reducer, "do_thing", <<>>, []}, state)

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
               Connection.handle_cast({:one_off_query, "SELECT 1", []}, state)

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
               Connection.handle_cast({:unsubscribe, 5, []}, state)

      assert <<1, _::binary>> = data
      assert new_state.next_request_id == 2
    end

    test "caller-supplied ids are used as-is and leave the counters alone" do
      state = %Connection{host: "localhost:3000", database: "test_db", handler: self()}

      assert {:reply, {:binary, data}, new_state} =
               Connection.handle_cast(
                 {:subscribe, ["SELECT * FROM t"], [request_id: 40, query_set_id: 7]},
                 state
               )

      # tag 0, request_id 40, query_set_id 7
      assert <<0, 40::little-32, 7::little-32, _::binary>> = data
      assert new_state.next_request_id == 1
      assert new_state.next_query_set_id == 1

      assert {:reply, {:binary, data}, _} =
               Connection.handle_cast(
                 {:unsubscribe, 7, [request_id: 41, send_dropped_rows: true]},
                 state
               )

      # tag 1, request_id 41, query_set_id 7, flags SendDroppedRows (1)
      assert <<1, 41::little-32, 7::little-32, 1>> = data
    end

    test "sanitize_state omits the token" do
      state = %Connection{
        host: "localhost:3000",
        database: "test_db",
        handler: self(),
        connected: true,
        token: "secret-token",
        identity: <<1::256>>,
        connection_id: <<2::128>>
      }

      info = Connection.sanitize_state(state)
      assert info.host == "localhost:3000"
      assert info.connected == true
      # Token should not be in sanitized state
      refute Map.has_key?(info, :token)
    end

    test "handle_disconnect respects configurable max_reconnect_attempts" do
      state = %Connection{
        host: "localhost:3000",
        database: "test_db",
        handler: self(),
        connected: true,
        max_reconnect_attempts: 2,
        base_backoff_ms: 10,
        max_backoff_ms: 50
      }

      # Attempt 1 (< 2) should reconnect
      assert {:reconnect, _conn, new_state} =
               Connection.handle_disconnect(
                 %{reason: :remote, attempt_number: 1, conn: %WebSockex.Conn{}},
                 state
               )

      assert new_state.connected == false
      assert new_state.pending_requests == %{}

      # Attempt 2 (>= 2) should give up
      assert {:ok, _state} =
               Connection.handle_disconnect(
                 %{reason: :remote, attempt_number: 2, conn: %WebSockex.Conn{}},
                 state
               )
    end

    test "handle_disconnect gives up when attempt equals max (strict less-than boundary)" do
      # This test distinguishes `<` from `<=` in the reconnect guard.
      # With attempt_number: 1 and max_reconnect_attempts: 1, the condition
      # `1 < 1` is false, so it should give up. If someone changed `<` to `<=`,
      # this test would fail because `1 <= 1` is true (would reconnect instead).
      state = %Connection{
        host: "localhost:3000",
        database: "test_db",
        handler: self(),
        connected: true,
        max_reconnect_attempts: 1,
        base_backoff_ms: 10,
        max_backoff_ms: 50
      }

      assert {:ok, _state} =
               Connection.handle_disconnect(
                 %{reason: :remote, attempt_number: 1, conn: %WebSockex.Conn{}},
                 state
               )

      assert_receive {:spacetimedb, {:disconnected, :remote, 1}}
      assert_receive {:spacetimedb, :connection_failed}
    end

    test "reconnect presents the latest server-issued token" do
      state = %Connection{
        host: "localhost:3000",
        database: "test_db",
        handler: self(),
        token: "server-issued",
        base_backoff_ms: 0
      }

      old_conn = %WebSockex.Conn{
        extra_headers: [{"Sec-WebSocket-Protocol", "v2.bsatn.spacetimedb"}]
      }

      assert {:reconnect, conn, _state} =
               Connection.handle_disconnect(
                 %{reason: :remote, attempt_number: 1, conn: old_conn},
                 state
               )

      assert {"Authorization", "Bearer server-issued"} in conn.extra_headers
    end

    test "start_link rejects unsupported compression" do
      assert {:error, {:unsupported_compression, :brotli}} =
               Connection.start_link(
                 host: "localhost:1",
                 database: "db",
                 handler: self(),
                 compression: :brotli
               )
    end
  end

  describe "handle_frame edge cases" do
    test "text frame returns {:ok, state} unchanged" do
      state = %Connection{
        host: "localhost:3000",
        database: "test_db",
        handler: self(),
        connected: true
      }

      assert {:ok, ^state} = Connection.handle_frame({:text, "hello"}, state)
    end

    test "binary frame with valid compression but invalid message tag returns {:ok, state}" do
      # Compression byte 0x00 (none) followed by 0xFF (invalid server message tag).
      # decompress succeeds, but decode fails — should log warning and return {:ok, state}.
      state = %Connection{
        host: "localhost:3000",
        database: "test_db",
        handler: self(),
        connected: true
      }

      assert {:ok, ^state} = Connection.handle_frame({:binary, <<0x00, 0xFF>>}, state)
    end
  end
end
