defmodule Spacetimedbex.ProtocolTest do
  use ExUnit.Case, async: true

  alias Spacetimedbex.BSATN.Encoder
  alias Spacetimedbex.Protocol.ClientMessage
  alias Spacetimedbex.Protocol.ClientMessage.{Subscribe, Unsubscribe, OneOffQuery, CallReducer}
  alias Spacetimedbex.Protocol.ServerMessage

  describe "ClientMessage encoding" do
    test "encode Subscribe" do
      msg = %Subscribe{
        request_id: 1,
        query_set_id: 100,
        query_strings: ["SELECT * FROM users"]
      }

      encoded = ClientMessage.encode(msg)
      # tag 0 + product(u32, u32, array(string))
      assert <<0, _::binary>> = encoded
    end

    test "encode Unsubscribe" do
      msg = %Unsubscribe{
        request_id: 2,
        query_set_id: 100,
        flags: :default
      }

      encoded = ClientMessage.encode(msg)
      assert <<1, _::binary>> = encoded
    end

    test "encode OneOffQuery" do
      msg = %OneOffQuery{
        request_id: 3,
        query_string: "SELECT * FROM users WHERE id = 1"
      }

      encoded = ClientMessage.encode(msg)
      assert <<2, _::binary>> = encoded
    end

    test "encode CallReducer" do
      args = Encoder.encode_product([Encoder.encode_string("hello")])

      msg = %CallReducer{
        request_id: 4,
        reducer: "say_hello",
        args: args
      }

      encoded = ClientMessage.encode(msg)
      assert <<3, _::binary>> = encoded
    end

    test "Subscribe encoding is valid BSATN" do
      msg = %Subscribe{
        request_id: 42,
        query_set_id: 7,
        query_strings: ["SELECT * FROM players", "SELECT * FROM scores"]
      }

      <<0, rest::binary>> = ClientMessage.encode(msg)

      # Decode the product fields
      alias Spacetimedbex.BSATN.Decoder
      assert {:ok, 42, rest} = Decoder.decode_u32(rest)
      assert {:ok, 7, rest} = Decoder.decode_u32(rest)

      assert {:ok, ["SELECT * FROM players", "SELECT * FROM scores"], <<>>} =
               Decoder.decode_array(rest, &Decoder.decode_string/1)
    end
  end

  describe "ServerMessage decompression" do
    test "no compression" do
      payload = <<1, 2, 3>>
      assert {:ok, ^payload} = ServerMessage.decompress(<<0x00, 1, 2, 3>>)
    end

    test "gzip decompression" do
      original = "hello world"
      compressed = :zlib.gzip(original)
      assert {:ok, ^original} = ServerMessage.decompress(<<0x02>> <> compressed)
    end

    test "brotli not supported" do
      assert {:error, :brotli_not_supported} = ServerMessage.decompress(<<0x01, 1, 2, 3>>)
    end

    test "unknown compression tag" do
      assert {:error, {:unknown_compression, 0xFF}} = ServerMessage.decompress(<<0xFF, 1>>)
    end
  end

  describe "ServerMessage decoding" do
    test "decode InitialConnection" do
      identity = :crypto.strong_rand_bytes(32)
      connection_id = :crypto.strong_rand_bytes(16)
      token = "eyJhbGciOiJFUzI1NiJ9.test.sig"

      encoded_token = Encoder.encode_string(token)
      bsatn = <<0>> <> identity <> connection_id <> encoded_token

      assert {:ok, %ServerMessage.InitialConnection{} = msg, <<>>} =
               ServerMessage.decode(bsatn)

      assert msg.identity == identity
      assert msg.connection_id == connection_id
      assert msg.token == token
    end

    test "decode SubscriptionError" do
      # tag 3, request_id=Some(5), query_set_id=10, error="bad query"
      request_id_some = <<0>> <> Encoder.encode_u32(5)
      query_set_id = Encoder.encode_u32(10)
      error_str = Encoder.encode_string("bad query")

      bsatn = <<3>> <> request_id_some <> query_set_id <> error_str

      assert {:ok, %ServerMessage.SubscriptionError{} = msg, <<>>} =
               ServerMessage.decode(bsatn)

      assert msg.request_id == 5
      assert msg.query_set_id == 10
      assert msg.error == "bad query"
    end

    test "decode ReducerResult with OkEmpty" do
      request_id = Encoder.encode_u32(99)
      timestamp = Encoder.encode_i64(1_700_000_000_000_000_000)
      outcome = <<1>>

      bsatn = <<6>> <> request_id <> timestamp <> outcome

      assert {:ok, %ServerMessage.ReducerResult{} = msg, <<>>} =
               ServerMessage.decode(bsatn)

      assert msg.request_id == 99
      assert msg.result == :ok_empty
    end

    test "decode ReducerResult with InternalError" do
      request_id = Encoder.encode_u32(7)
      timestamp = Encoder.encode_i64(0)
      outcome = <<3>> <> Encoder.encode_string("reducer panicked")

      bsatn = <<6>> <> request_id <> timestamp <> outcome

      assert {:ok, %ServerMessage.ReducerResult{} = msg, <<>>} =
               ServerMessage.decode(bsatn)

      assert msg.request_id == 7
      assert msg.result == {:internal_error, "reducer panicked"}
    end
  end
end
