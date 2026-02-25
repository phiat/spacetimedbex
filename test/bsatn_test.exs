defmodule Spacetimedbex.BSATNTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Spacetimedbex.BSATN
  alias Spacetimedbex.BSATN.{Encoder, Decoder}

  describe "bool" do
    test "roundtrip true" do
      encoded = Encoder.encode_bool(true)
      assert encoded == <<1>>
      assert {:ok, true, <<>>} = Decoder.decode_bool(encoded)
    end

    test "roundtrip false" do
      encoded = Encoder.encode_bool(false)
      assert encoded == <<0>>
      assert {:ok, false, <<>>} = Decoder.decode_bool(encoded)
    end

    test "invalid bool byte" do
      assert {:error, {:invalid_bool, 2}} = Decoder.decode_bool(<<2>>)
    end
  end

  describe "integers" do
    test "u8 roundtrip" do
      encoded = Encoder.encode_u8(42)
      assert {:ok, 42, <<>>} = Decoder.decode_u8(encoded)
    end

    test "i8 roundtrip negative" do
      encoded = Encoder.encode_i8(-100)
      assert {:ok, -100, <<>>} = Decoder.decode_i8(encoded)
    end

    test "u16 little-endian" do
      encoded = Encoder.encode_u16(0x0102)
      assert encoded == <<0x02, 0x01>>
      assert {:ok, 0x0102, <<>>} = Decoder.decode_u16(encoded)
    end

    test "u32 roundtrip" do
      encoded = Encoder.encode_u32(123_456)
      assert {:ok, 123_456, <<>>} = Decoder.decode_u32(encoded)
    end

    test "i32 negative roundtrip" do
      encoded = Encoder.encode_i32(-999)
      assert {:ok, -999, <<>>} = Decoder.decode_i32(encoded)
    end

    test "u64 roundtrip" do
      val = 0xDEAD_BEEF_CAFE_BABE
      encoded = Encoder.encode_u64(val)
      assert {:ok, ^val, <<>>} = Decoder.decode_u64(encoded)
    end

    test "i64 roundtrip" do
      encoded = Encoder.encode_i64(-1_000_000_000_000)
      assert {:ok, -1_000_000_000_000, <<>>} = Decoder.decode_i64(encoded)
    end

    test "u128 roundtrip" do
      val = 0xFFFF_FFFF_FFFF_FFFF_0000_0000_0000_0001
      encoded = Encoder.encode_u128(val)
      assert {:ok, ^val, <<>>} = Decoder.decode_u128(encoded)
    end

    test "u256 roundtrip" do
      val = 1 <<< 200
      encoded = Encoder.encode_u256(val)
      assert {:ok, ^val, <<>>} = Decoder.decode_u256(encoded)
    end
  end

  describe "floats" do
    test "f32 roundtrip" do
      encoded = Encoder.encode_f32(3.140000104904175)
      assert {:ok, decoded, <<>>} = Decoder.decode_f32(encoded)
      assert_in_delta decoded, 3.14, 0.01
    end

    test "f64 roundtrip" do
      encoded = Encoder.encode_f64(3.141592653589793)
      assert {:ok, 3.141592653589793, <<>>} = Decoder.decode_f64(encoded)
    end
  end

  describe "string" do
    test "roundtrip" do
      encoded = Encoder.encode_string("hello")
      assert encoded == <<5, 0, 0, 0, "hello">>
      assert {:ok, "hello", <<>>} = Decoder.decode_string(encoded)
    end

    test "empty string" do
      encoded = Encoder.encode_string("")
      assert encoded == <<0, 0, 0, 0>>
      assert {:ok, "", <<>>} = Decoder.decode_string(encoded)
    end

    test "unicode string" do
      str = "héllo 世界"
      encoded = Encoder.encode_string(str)
      assert {:ok, ^str, <<>>} = Decoder.decode_string(encoded)
    end

    test "invalid UTF-8 returns error" do
      # 3-byte "string" with invalid UTF-8 sequence
      invalid = <<3, 0, 0, 0, 0xFF, 0xFE, 0xFD>>
      assert {:error, {:invalid_utf8, 3}} = Decoder.decode_string(invalid)
    end
  end

  describe "bytes" do
    test "roundtrip" do
      data = <<1, 2, 3, 4, 5>>
      encoded = Encoder.encode_bytes(data)
      assert {:ok, ^data, <<>>} = Decoder.decode_bytes(encoded)
    end
  end

  describe "array" do
    test "array of u32" do
      encoded = Encoder.encode_array([1, 2, 3], &Encoder.encode_u32/1)
      assert {:ok, [1, 2, 3], <<>>} = Decoder.decode_array(encoded, &Decoder.decode_u32/1)
    end

    test "empty array" do
      encoded = Encoder.encode_array([], &Encoder.encode_u32/1)
      assert encoded == <<0, 0, 0, 0>>
      assert {:ok, [], <<>>} = Decoder.decode_array(encoded, &Decoder.decode_u32/1)
    end

    test "array of strings" do
      strings = ["foo", "bar", "baz"]
      encoded = Encoder.encode_array(strings, &Encoder.encode_string/1)
      assert {:ok, ^strings, <<>>} = Decoder.decode_array(encoded, &Decoder.decode_string/1)
    end
  end

  describe "sum (enum)" do
    test "encode sum with tag" do
      payload = Encoder.encode_u32(42)
      encoded = Encoder.encode_sum(3, payload)
      assert encoded == <<3>> <> payload
      assert {:ok, 3, rest} = Decoder.decode_tag(encoded)
      assert {:ok, 42, <<>>} = Decoder.decode_u32(rest)
    end
  end

  describe "option" do
    test "encode/decode None" do
      encoded = Encoder.encode_option(nil)
      assert encoded == <<1>>
      assert {:ok, nil, <<>>} = Decoder.decode_option(encoded, &Decoder.decode_u32/1)
    end

    test "encode/decode Some" do
      val_binary = Encoder.encode_u32(42)
      encoded = Encoder.encode_option({:some, val_binary})
      assert {:ok, {:some, 42}, <<>>} = Decoder.decode_option(encoded, &Decoder.decode_u32/1)
    end
  end

  describe "product (struct)" do
    test "encode concatenates fields" do
      encoded =
        Encoder.encode_product([
          Encoder.encode_u32(1),
          Encoder.encode_string("test"),
          Encoder.encode_bool(true)
        ])

      # Decode the product manually
      assert {:ok, 1, rest} = Decoder.decode_u32(encoded)
      assert {:ok, "test", rest} = Decoder.decode_string(rest)
      assert {:ok, true, <<>>} = Decoder.decode_bool(rest)
    end
  end

  describe "preserves trailing data" do
    test "decoder returns unconsumed bytes" do
      data = <<42, 99>>
      assert {:ok, 42, <<99>>} = Decoder.decode_u8(data)
    end
  end

  describe "error handling" do
    test "unexpected eof on all types" do
      assert {:error, :unexpected_eof} = Decoder.decode_bool(<<>>)
      assert {:error, :unexpected_eof} = Decoder.decode_u8(<<>>)
      assert {:error, :unexpected_eof} = Decoder.decode_u32(<<1>>)
      assert {:error, :unexpected_eof} = Decoder.decode_u64(<<1, 2, 3>>)
      assert {:error, :unexpected_eof} = Decoder.decode_string(<<>>)
    end
  end

  describe "BSATN delegate module" do
    test "delegates encode/decode" do
      assert {:ok, 42, <<>>} = BSATN.decode_u32(BSATN.encode_u32(42))
      assert {:ok, "hi", <<>>} = BSATN.decode_string(BSATN.encode_string("hi"))
    end
  end
end
