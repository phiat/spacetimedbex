defmodule Spacetimedbex.BSATN.ValueEncoderTest do
  use ExUnit.Case, async: true

  alias Spacetimedbex.BSATN.ValueEncoder
  alias Spacetimedbex.ClientCache.RowDecoder

  describe "encode_value/2 roundtrips with decode_value/2" do
    test "bool" do
      assert_roundtrip(true, :bool)
      assert_roundtrip(false, :bool)
    end

    test "u8" do
      assert_roundtrip(0, :u8)
      assert_roundtrip(255, :u8)
    end

    test "i8" do
      assert_roundtrip(-128, :i8)
      assert_roundtrip(127, :i8)
    end

    test "u16" do
      assert_roundtrip(0, :u16)
      assert_roundtrip(65_535, :u16)
    end

    test "i16" do
      assert_roundtrip(-32_768, :i16)
      assert_roundtrip(32_767, :i16)
    end

    test "u32" do
      assert_roundtrip(0, :u32)
      assert_roundtrip(4_294_967_295, :u32)
    end

    test "i32" do
      assert_roundtrip(-2_147_483_648, :i32)
      assert_roundtrip(2_147_483_647, :i32)
    end

    test "u64" do
      assert_roundtrip(0, :u64)
      assert_roundtrip(18_446_744_073_709_551_615, :u64)
    end

    test "i64" do
      assert_roundtrip(-9_223_372_036_854_775_808, :i64)
      assert_roundtrip(9_223_372_036_854_775_807, :i64)
    end

    test "u128" do
      assert_roundtrip(0, :u128)
      assert_roundtrip(340_282_366_920_938_463_463_374_607_431_768_211_455, :u128)
    end

    test "i128" do
      assert_roundtrip(0, :i128)
      assert_roundtrip(-1, :i128)
    end

    test "u256" do
      assert_roundtrip(0, :u256)
      assert_roundtrip(1, :u256)
    end

    test "i256" do
      assert_roundtrip(0, :i256)
      assert_roundtrip(-1, :i256)
    end

    test "f32" do
      assert_roundtrip(3.140000104904175, :f32)
      assert_roundtrip(0.0, :f32)
    end

    test "f64" do
      assert_roundtrip(3.141592653589793, :f64)
      assert_roundtrip(0.0, :f64)
    end

    test "string" do
      assert_roundtrip("hello", :string)
      assert_roundtrip("", :string)
      assert_roundtrip("unicode: 日本語", :string)
    end

    test "bytes" do
      assert_roundtrip(<<1, 2, 3>>, :bytes)
      assert_roundtrip(<<>>, :bytes)
    end

    test "array of u32" do
      assert_roundtrip([1, 2, 3], {:array, :u32})
      assert_roundtrip([], {:array, :u32})
    end

    test "array of strings" do
      assert_roundtrip(["hello", "world"], {:array, :string})
    end

    test "option some" do
      {:ok, encoded} = ValueEncoder.encode_value({:some, 42}, {:option, :u32})
      {:ok, decoded, <<>>} = RowDecoder.decode_value(encoded, {:option, :u32})
      assert decoded == {:some, 42}
    end

    test "option none" do
      {:ok, encoded} = ValueEncoder.encode_value(nil, {:option, :u32})
      {:ok, decoded, <<>>} = RowDecoder.decode_value(encoded, {:option, :u32})
      assert decoded == nil
    end

    test "bare value auto-wraps as some for option" do
      {:ok, encoded} = ValueEncoder.encode_value(42, {:option, :u32})
      {:ok, decoded, <<>>} = RowDecoder.decode_value(encoded, {:option, :u32})
      assert decoded == {:some, 42}
    end

    test "product" do
      columns = [
        %{name: "name", type: :string},
        %{name: "age", type: :u32}
      ]

      val = %{"name" => "Alice", "age" => 30}
      {:ok, encoded} = ValueEncoder.encode_value(val, {:product, columns})
      {:ok, decoded, <<>>} = RowDecoder.decode_value(encoded, {:product, columns})
      assert decoded == val
    end

    test "nested product" do
      inner_cols = [%{name: "x", type: :i32}, %{name: "y", type: :i32}]

      columns = [
        %{name: "label", type: :string},
        %{name: "point", type: {:product, inner_cols}}
      ]

      val = %{"label" => "origin", "point" => %{"x" => 0, "y" => 0}}
      {:ok, encoded} = ValueEncoder.encode_value(val, {:product, columns})
      {:ok, decoded, <<>>} = RowDecoder.decode_value(encoded, {:product, columns})
      assert decoded == val
    end

    test "integer auto-converts to float for f32" do
      {:ok, encoded} = ValueEncoder.encode_value(5, :f32)
      {:ok, decoded, <<>>} = RowDecoder.decode_value(encoded, :f32)
      assert decoded == 5.0
    end

    test "integer auto-converts to float for f64" do
      {:ok, encoded} = ValueEncoder.encode_value(5, :f64)
      {:ok, decoded, <<>>} = RowDecoder.decode_value(encoded, :f64)
      assert decoded == 5.0
    end
  end

  describe "encode_value/2 errors" do
    test "type mismatch" do
      assert {:error, {:type_mismatch, :u32, "not a number"}} =
               ValueEncoder.encode_value("not a number", :u32)
    end

    test "missing product field" do
      columns = [%{name: "x", type: :u32}, %{name: "y", type: :u32}]
      assert {:error, {:missing_field, "y"}} = ValueEncoder.encode_value(%{"x" => 1}, {:product, columns})
    end
  end

  describe "encode_reducer_args/2" do
    test "encodes args in param order" do
      params = [
        %{name: "name", type: :string},
        %{name: "age", type: :u32}
      ]

      {:ok, encoded} = ValueEncoder.encode_reducer_args(%{"name" => "Bob", "age" => 25}, params)

      # Decode as product to verify
      {:ok, decoded, <<>>} = RowDecoder.decode_value(encoded, {:product, params})
      assert decoded == %{"name" => "Bob", "age" => 25}
    end

    test "accepts atom keys" do
      params = [%{name: "value", type: :u32}]
      {:ok, encoded} = ValueEncoder.encode_reducer_args(%{value: 42}, params)
      {:ok, decoded, <<>>} = RowDecoder.decode_value(encoded, {:product, params})
      assert decoded == %{"value" => 42}
    end

    test "returns error for missing param" do
      params = [%{name: "x", type: :u32}, %{name: "y", type: :u32}]
      assert {:error, {:missing_field, "y"}} = ValueEncoder.encode_reducer_args(%{"x" => 1}, params)
    end
  end

  defp assert_roundtrip(value, type) do
    {:ok, encoded} = ValueEncoder.encode_value(value, type)
    {:ok, decoded, <<>>} = RowDecoder.decode_value(encoded, type)
    assert decoded == value
  end
end
