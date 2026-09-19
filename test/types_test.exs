defmodule Spacetimedbex.TypesTest do
  use ExUnit.Case, async: true

  alias Spacetimedbex.BSATN.ValueEncoder
  alias Spacetimedbex.ClientCache.RowDecoder
  alias Spacetimedbex.Schema
  alias Spacetimedbex.Types

  describe "conversions" do
    test "identity hex is big-endian, matching SpacetimeDB's to_hex" do
      assert Types.identity_from_int(1) == String.duplicate("0", 63) <> "1"
      hex = "c200056267b63cd6cd45b5b85a9182f10db211afd72b82f2ff35809cc7d59adc"
      assert {:ok, int} = Types.identity_to_int(hex)
      assert Types.identity_from_int(int) == hex
      assert {:ok, ^int} = Types.identity_to_int(String.upcase(hex))
      assert Types.identity_to_int("xyz") == :error
    end

    test "uuid formatting matches the uuid crate's from_u128" do
      int = 0x0102_0304_0506_0708_090A_0B0C_0D0E_0F10
      assert Types.uuid_from_int(int) == "01020304-0506-0708-090a-0b0c0d0e0f10"
      assert {:ok, ^int} = Types.uuid_to_int("01020304-0506-0708-090a-0b0c0d0e0f10")
      assert {:ok, ^int} = Types.uuid_to_int("0102030405060708090a0b0c0d0e0f10")
    end

    test "timestamps and durations" do
      assert Types.timestamp_from_micros(0) == ~U[1970-01-01 00:00:00.000000Z]
      assert {:ok, 1_500_000} = Types.timestamp_to_micros(~U[1970-01-01 00:00:01.500000Z])
      # Outside DateTime's range: raw microseconds
      assert Types.timestamp_from_micros(9_223_372_036_854_775_807) == 9_223_372_036_854_775_807

      assert {:ok, 90_000_001} =
               Types.duration_to_micros(Duration.new!(minute: 1, second: 30, microsecond: {1, 6}))

      assert Types.duration_to_micros(Duration.new!(month: 1)) == :error
      assert %Duration{microsecond: {5, 6}} = Types.duration_from_micros(5)
    end
  end

  describe "schema" do
    defp element(name, type), do: %{"name" => %{"some" => name}, "algebraic_type" => type}
    defp product(elements), do: %{"Product" => %{"elements" => elements}}

    test "single-field marker products parse as special types" do
      raw = %{
        "typespace" => %{
          "types" => [
            product([
              element("owner", product([element("__identity__", %{"U256" => []})])),
              element("conn", product([element("__connection_id__", %{"U128" => []})])),
              element("id", product([element("__uuid__", %{"U128" => []})])),
              element(
                "at",
                %{
                  "Sum" => %{
                    "variants" => [
                      element(
                        "Interval",
                        product([element("__time_duration_micros__", %{"I64" => []})])
                      ),
                      element(
                        "Time",
                        product([
                          element("__timestamp_micros_since_unix_epoch__", %{"I64" => []})
                        ])
                      )
                    ]
                  }
                }
              )
            ])
          ]
        },
        "tables" => [%{"name" => "t", "product_type_ref" => 0, "primary_key" => []}],
        "reducers" => []
      }

      {:ok, columns} = raw |> Schema.parse() |> Schema.columns_for("t")

      assert [
               %{name: "owner", type: :identity},
               %{name: "conn", type: :connection_id},
               %{name: "id", type: :uuid},
               %{
                 name: "at",
                 type:
                   {:sum,
                    [%{name: "Interval", type: :time_duration}, %{name: "Time", type: :timestamp}]}
               }
             ] = columns
    end
  end

  describe "decode and encode" do
    test "identity decodes from little-endian wire bytes to big-endian hex" do
      wire = <<0xAB>> <> :binary.copy(<<0>>, 30) <> <<0x01>>
      expected = "01" <> String.duplicate("00", 30) <> "ab"
      assert {:ok, ^expected, <<>>} = RowDecoder.decode_value(wire, :identity)
      assert {:ok, ^wire} = ValueEncoder.encode_value(expected, :identity)
    end

    test "special types roundtrip" do
      for {value, type} <- [
            {"0000000000000000000000000000002a", :connection_id},
            {"01020304-0506-0708-090a-0b0c0d0e0f10", :uuid},
            {~U[2026-09-19 12:00:00.123456Z], :timestamp},
            {Duration.new!(microsecond: {2_500_000, 6}), :time_duration}
          ] do
        {:ok, bin} = ValueEncoder.encode_value(value, type)
        assert {:ok, ^value, <<>>} = RowDecoder.decode_value(bin, type)
      end
    end

    test "encoding accepts raw integers and legacy marker maps" do
      {:ok, from_hex} = ValueEncoder.encode_value(Types.identity_from_int(42), :identity)
      assert {:ok, ^from_hex} = ValueEncoder.encode_value(42, :identity)
      assert {:ok, ^from_hex} = ValueEncoder.encode_value(%{"__identity__" => 42}, :identity)

      assert {:ok, <<7::little-signed-64>>} =
               ValueEncoder.encode_value(%{__timestamp_micros_since_unix_epoch__: 7}, :timestamp)
    end

    test "invalid special values are type mismatches" do
      assert {:error, {:type_mismatch, :identity, "nope"}} =
               ValueEncoder.encode_value("nope", :identity)

      assert {:error, {:type_mismatch, :time_duration, _}} =
               ValueEncoder.encode_value(Duration.new!(year: 1), :time_duration)
    end
  end
end
