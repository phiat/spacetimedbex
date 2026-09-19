defmodule Spacetimedbex.ClientCache.RowDecoderTest do
  use ExUnit.Case, async: true

  alias Spacetimedbex.BSATN.Encoder
  alias Spacetimedbex.ClientCache.RowDecoder

  @person_columns [
    %{name: "id", type: :u64},
    %{name: "name", type: :string},
    %{name: "age", type: :u32}
  ]

  defp encode_person(id, name, age) do
    Encoder.encode_product([
      Encoder.encode_u64(id),
      Encoder.encode_string(name),
      Encoder.encode_u32(age)
    ])
  end

  describe "decode_row/2" do
    test "decodes a single person row" do
      data = encode_person(1, "Alice", 30)
      row = RowDecoder.decode_row(data, @person_columns)

      assert row == %{"id" => 1, "name" => "Alice", "age" => 30}
    end

    test "decodes row with empty string" do
      data = encode_person(0, "", 0)
      row = RowDecoder.decode_row(data, @person_columns)

      assert row == %{"id" => 0, "name" => "", "age" => 0}
    end

    test "decodes row with unicode" do
      data = encode_person(42, "日本語", 25)
      row = RowDecoder.decode_row(data, @person_columns)

      assert row["name"] == "日本語"
    end
  end

  describe "decode_row_list/2 with fixed_size" do
    test "decodes multiple fixed-size rows" do
      # Simple fixed-size: two u32 columns, each row is 8 bytes
      columns = [%{name: "x", type: :u32}, %{name: "y", type: :u32}]

      row1 = Encoder.encode_product([Encoder.encode_u32(1), Encoder.encode_u32(2)])
      row2 = Encoder.encode_product([Encoder.encode_u32(3), Encoder.encode_u32(4)])

      row_list = %{
        size_hint: {:fixed_size, 8},
        rows_data: row1 <> row2
      }

      rows = RowDecoder.decode_row_list(row_list, columns)
      assert length(rows) == 2
      assert Enum.at(rows, 0) == %{"x" => 1, "y" => 2}
      assert Enum.at(rows, 1) == %{"x" => 3, "y" => 4}
    end

    test "empty rows_data returns empty list" do
      row_list = %{size_hint: {:fixed_size, 8}, rows_data: <<>>}
      assert RowDecoder.decode_row_list(row_list, []) == []
    end
  end

  describe "decode_row_list/2 with row_offsets" do
    test "decodes variable-size rows" do
      row1 = encode_person(1, "Al", 20)
      row2 = encode_person(2, "Bob", 30)
      row3 = encode_person(3, "Charlie", 40)

      offset1 = 0
      offset2 = byte_size(row1)
      offset3 = offset2 + byte_size(row2)

      row_list = %{
        size_hint: {:row_offsets, [offset1, offset2, offset3]},
        rows_data: row1 <> row2 <> row3
      }

      rows = RowDecoder.decode_row_list(row_list, @person_columns)
      assert length(rows) == 3
      assert Enum.at(rows, 0)["name"] == "Al"
      assert Enum.at(rows, 1)["name"] == "Bob"
      assert Enum.at(rows, 2)["name"] == "Charlie"
    end
  end

  describe "decode_row/2 error handling" do
    test "decode_row with truncated data produces decode_error values" do
      columns = [
        %{name: "id", type: :u32},
        %{name: "name", type: :string},
        %{name: "age", type: :u32}
      ]

      # Only provide enough data for the first field (4 bytes for u32), then truncate
      truncated = <<42, 0, 0, 0>>

      row = RowDecoder.decode_row(truncated, columns)
      assert row["id"] == 42
      assert {:decode_error, _reason} = row["name"]
      assert {:decode_error, _reason} = row["age"]
    end
  end

  describe "decode_row_list/2 edge cases" do
    test "decode_row_list with empty row_offsets returns empty list" do
      row_list = %{
        size_hint: {:row_offsets, []},
        rows_data: <<1, 2, 3, 4>>
      }

      assert RowDecoder.decode_row_list(row_list, @person_columns) == []
    end

    test "decode_row_list with non-binary rows_data returns empty list" do
      assert RowDecoder.decode_row_list(%{size_hint: {:fixed_size, 8}, rows_data: nil}, []) == []
    end

    test "split_by_offsets with out-of-bounds offset raises ArgumentError" do
      row_list = %{
        size_hint: {:row_offsets, [0, 100]},
        rows_data: <<1, 2, 3, 4>>
      }

      assert_raise ArgumentError, fn ->
        RowDecoder.decode_row_list(row_list, [%{name: "x", type: :u32}])
      end
    end
  end

  describe "decode_value/2 for complex types" do
    test "decodes option some" do
      data = <<0>> <> Encoder.encode_u32(42)
      assert {:ok, {:some, 42}, <<>>} = RowDecoder.decode_value(data, {:option, :u32})
    end

    test "decodes option none" do
      assert {:ok, nil, <<>>} = RowDecoder.decode_value(<<1>>, {:option, :u32})
    end

    test "decodes array" do
      data = Encoder.encode_array([10, 20, 30], &Encoder.encode_u32/1)
      assert {:ok, [10, 20, 30], <<>>} = RowDecoder.decode_value(data, {:array, :u32})
    end

    test "decodes nested product" do
      inner_columns = [%{name: "a", type: :u8}, %{name: "b", type: :u8}]
      data = <<5, 10>>

      assert {:ok, %{"a" => 5, "b" => 10}, <<>>} =
               RowDecoder.decode_value(data, {:product, inner_columns})
    end
  end

  describe "sum and map types" do
    @shape {:sum,
            [
              %{name: "Circle", type: {:product, [%{name: "r", type: :u32}]}},
              %{name: "Empty", type: {:product, []}}
            ]}

    test "decodes a sum variant with payload" do
      assert {:ok, {"Circle", %{"r" => 7}}, <<>>} =
               RowDecoder.decode_value(<<0, 7::little-32>>, @shape)
    end

    test "decodes a unit variant" do
      assert {:ok, {"Empty", %{}}, <<>>} = RowDecoder.decode_value(<<1>>, @shape)
    end

    test "rejects an out-of-range variant tag" do
      assert {:error, {:invalid_sum_tag, 5}} = RowDecoder.decode_value(<<5>>, @shape)
    end

    test "decodes a ScheduleAt-shaped column inside a row" do
      schedule_at =
        {:sum,
         [
           %{
             name: "Interval",
             type: {:product, [%{name: "__time_duration_micros__", type: :i64}]}
           },
           %{
             name: "Time",
             type: {:product, [%{name: "__timestamp_micros_since_unix_epoch__", type: :i64}]}
           }
         ]}

      columns = [%{name: "id", type: :u64}, %{name: "at", type: schedule_at}]

      assert %{"id" => 1, "at" => {"Time", %{"__timestamp_micros_since_unix_epoch__" => 99}}} =
               RowDecoder.decode_row(<<1::little-64, 1, 99::little-signed-64>>, columns)
    end

    test "decodes a map" do
      data = <<2::little-32, 1, 10::little-32, 2, 20::little-32>>
      assert {:ok, %{1 => 10, 2 => 20}, <<>>} = RowDecoder.decode_value(data, {:map, :u8, :u32})
    end
  end
end
