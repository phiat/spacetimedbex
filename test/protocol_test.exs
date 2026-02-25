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
      alias Spacetimedbex.BSATN.Decoder

      msg = %Unsubscribe{
        request_id: 2,
        query_set_id: 100,
        flags: :default
      }

      encoded = ClientMessage.encode(msg)
      assert <<1, rest::binary>> = encoded
      assert {:ok, 2, rest} = Decoder.decode_u32(rest)
      assert {:ok, 100, rest} = Decoder.decode_u32(rest)
      assert {:ok, 0, <<>>} = Decoder.decode_u8(rest)
    end

    test "encode OneOffQuery" do
      alias Spacetimedbex.BSATN.Decoder

      msg = %OneOffQuery{
        request_id: 3,
        query_string: "SELECT * FROM users WHERE id = 1"
      }

      encoded = ClientMessage.encode(msg)
      assert <<2, rest::binary>> = encoded
      assert {:ok, 3, rest} = Decoder.decode_u32(rest)
      assert {:ok, "SELECT * FROM users WHERE id = 1", <<>>} = Decoder.decode_string(rest)
    end

    test "encode CallReducer" do
      alias Spacetimedbex.BSATN.Decoder

      args = Encoder.encode_product([Encoder.encode_string("hello")])

      msg = %CallReducer{
        request_id: 4,
        reducer: "say_hello",
        args: args
      }

      encoded = ClientMessage.encode(msg)
      assert <<3, rest::binary>> = encoded
      assert {:ok, 4, rest} = Decoder.decode_u32(rest)
      # flags byte
      assert {:ok, 0, rest} = Decoder.decode_u8(rest)
      assert {:ok, "say_hello", rest} = Decoder.decode_string(rest)
      assert {:ok, ^args, <<>>} = Decoder.decode_bytes(rest)
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

    test "empty frame" do
      assert {:error, :empty_frame} = ServerMessage.decompress(<<>>)
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

    test "decode OneOffQueryResult with Ok result" do
      request_id = Encoder.encode_u32(42)
      # Result tag 0 = Ok, then QueryRows = array of SingleTableRows
      # 1 table: table_name "users", rows = BsatnRowList
      table_name = Encoder.encode_string("users")
      # BsatnRowList: size_hint = FixedSize(8), rows_data = one 8-byte row
      size_hint = <<0>> <> Encoder.encode_u16(8)
      row_data = <<1, 0, 0, 0, 0, 0, 0, 0>>
      rows_data = Encoder.encode_bytes(row_data)
      # Array of 1 SingleTableRows
      tables = Encoder.encode_u32(1) <> table_name <> size_hint <> rows_data
      result = <<0>> <> tables

      bsatn = <<5>> <> request_id <> result

      assert {:ok, %ServerMessage.OneOffQueryResult{} = msg, <<>>} =
               ServerMessage.decode(bsatn)

      assert msg.request_id == 42
      assert {:ok, [%{table_name: "users", rows: %{size_hint: {:fixed_size, 8}}}]} = msg.result
    end

    test "decode SubscribeApplied" do
      request_id = Encoder.encode_u32(10)
      query_set_id = Encoder.encode_u32(20)
      # Build one SingleTableRows: table_name + BsatnRowList
      table_name = Encoder.encode_string("players")
      # BsatnRowList: size_hint = FixedSize(4), rows_data = one 4-byte row
      size_hint = <<0>> <> Encoder.encode_u16(4)
      row_data = Encoder.encode_u32(99)
      rows_data = Encoder.encode_bytes(row_data)
      # Array of 1 SingleTableRows
      query_rows = Encoder.encode_u32(1) <> table_name <> size_hint <> rows_data

      bsatn = <<1>> <> request_id <> query_set_id <> query_rows

      assert {:ok, %ServerMessage.SubscribeApplied{} = msg, <<>>} =
               ServerMessage.decode(bsatn)

      assert msg.request_id == 10
      assert msg.query_set_id == 20
      assert [%{table_name: "players", rows: %{size_hint: {:fixed_size, 4}, rows_data: ^row_data}}] = msg.rows
    end

    test "decode TransactionUpdate" do
      # TransactionUpdate = array of QuerySetUpdate
      # QuerySetUpdate = query_set_id(u32) + array of TableUpdate
      # TableUpdate = table_name(string) + array of TableUpdateRows
      # TableUpdateRows tag 0 = PersistentTable(inserts BsatnRowList + deletes BsatnRowList)
      insert_data = <<1, 2, 3, 4>>
      delete_data = <<5, 6, 7, 8>>

      # BsatnRowList for inserts: FixedSize(4) + bytes
      inserts_row_list = <<0>> <> Encoder.encode_u16(4) <> Encoder.encode_bytes(insert_data)
      # BsatnRowList for deletes: FixedSize(4) + bytes
      deletes_row_list = <<0>> <> Encoder.encode_u16(4) <> Encoder.encode_bytes(delete_data)

      # TableUpdateRows: tag 0 (PersistentTable) + inserts + deletes
      table_update_rows = <<0>> <> inserts_row_list <> deletes_row_list
      # Array of 1 TableUpdateRows
      table_update_rows_array = Encoder.encode_u32(1) <> table_update_rows

      # TableUpdate: table_name + rows array
      table_update = Encoder.encode_string("scores") <> table_update_rows_array
      # Array of 1 TableUpdate
      tables_array = Encoder.encode_u32(1) <> table_update

      # QuerySetUpdate: query_set_id + tables array
      query_set_update = Encoder.encode_u32(55) <> tables_array
      # Array of 1 QuerySetUpdate
      query_sets_array = Encoder.encode_u32(1) <> query_set_update

      bsatn = <<4>> <> query_sets_array

      assert {:ok, %ServerMessage.TransactionUpdate{} = msg, <<>>} =
               ServerMessage.decode(bsatn)

      assert [%{query_set_id: 55, tables: [table]}] = msg.query_sets
      assert table.table_name == "scores"

      assert [{:persistent, %{inserts: inserts, deletes: deletes}}] = table.rows
      assert inserts.size_hint == {:fixed_size, 4}
      assert inserts.rows_data == insert_data
      assert deletes.size_hint == {:fixed_size, 4}
      assert deletes.rows_data == delete_data
    end

    test "decode OneOffQueryResult with Err result" do
      request_id = Encoder.encode_u32(43)
      error_msg = Encoder.encode_string("table not found")
      result = <<1>> <> error_msg

      bsatn = <<5>> <> request_id <> result

      assert {:ok, %ServerMessage.OneOffQueryResult{} = msg, <<>>} =
               ServerMessage.decode(bsatn)

      assert msg.request_id == 43
      assert msg.result == {:error, "table not found"}
    end
  end
end
