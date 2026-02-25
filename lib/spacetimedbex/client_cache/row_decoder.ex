defmodule Spacetimedbex.ClientCache.RowDecoder do
  @moduledoc """
  Decodes BSATN row data into Elixir maps using table schema.

  Takes a `BsatnRowList` (as returned in SubscribeApplied / TransactionUpdate)
  and a list of column definitions, and produces a list of row maps.
  """

  alias Spacetimedbex.BSATN.Decoder

  @doc """
  Decode a BsatnRowList into a list of row maps.

  ## Parameters
  - `row_list` - Map with `:size_hint` and `:rows_data` (from ServerMessage decoding)
  - `columns` - List of `%{name: String.t(), type: algebraic_type()}` from Schema
  """
  def decode_row_list(%{size_hint: size_hint, rows_data: rows_data}, columns)
      when is_binary(rows_data) do
    row_binaries = split_rows(size_hint, rows_data)
    Enum.map(row_binaries, &decode_row(&1, columns))
  end

  def decode_row_list(_, _), do: []

  @doc """
  Decode a single BSATN row binary into a map using column definitions.
  """
  def decode_row(data, columns) when is_binary(data) and is_list(columns) do
    {row_map, _rest} =
      Enum.reduce(columns, {%{}, data}, fn col, {acc, rest} ->
        case decode_value(rest, col.type) do
          {:ok, value, rest2} ->
            {Map.put(acc, col.name, value), rest2}

          {:error, reason} ->
            {Map.put(acc, col.name, {:decode_error, reason}), <<>>}
        end
      end)

    row_map
  end

  @doc """
  Decode a BSATN value of the given algebraic type.
  """
  def decode_value(data, :bool), do: Decoder.decode_bool(data)
  def decode_value(data, :u8), do: Decoder.decode_u8(data)
  def decode_value(data, :i8), do: Decoder.decode_i8(data)
  def decode_value(data, :u16), do: Decoder.decode_u16(data)
  def decode_value(data, :i16), do: Decoder.decode_i16(data)
  def decode_value(data, :u32), do: Decoder.decode_u32(data)
  def decode_value(data, :i32), do: Decoder.decode_i32(data)
  def decode_value(data, :u64), do: Decoder.decode_u64(data)
  def decode_value(data, :i64), do: Decoder.decode_i64(data)
  def decode_value(data, :u128), do: Decoder.decode_u128(data)
  def decode_value(data, :i128), do: Decoder.decode_i128(data)
  def decode_value(data, :u256), do: Decoder.decode_u256(data)
  def decode_value(data, :i256), do: Decoder.decode_i256(data)
  def decode_value(data, :f32), do: Decoder.decode_f32(data)
  def decode_value(data, :f64), do: Decoder.decode_f64(data)
  def decode_value(data, :string), do: Decoder.decode_string(data)
  def decode_value(data, :bytes), do: Decoder.decode_bytes(data)

  def decode_value(data, {:array, inner_type}) do
    Decoder.decode_array(data, &decode_value(&1, inner_type))
  end

  def decode_value(data, {:option, inner_type}) do
    Decoder.decode_option(data, &decode_value(&1, inner_type))
  end

  def decode_value(data, {:product, columns}) do
    {row, rest} =
      Enum.reduce(columns, {%{}, data}, fn col, {acc, rest} ->
        case decode_value(rest, col.type) do
          {:ok, value, rest2} -> {Map.put(acc, col.name, value), rest2}
          {:error, _} = err -> throw(err)
        end
      end)

    {:ok, row, rest}
  catch
    {:error, _} = err -> err
  end

  def decode_value(_data, {:unknown, _}), do: {:error, :unknown_type}

  # --- Row splitting ---

  defp split_rows({:fixed_size, size}, data) when size > 0 do
    split_fixed(data, size, [])
  end

  defp split_rows({:fixed_size, 0}, _data), do: []

  defp split_rows({:row_offsets, offsets}, data) do
    split_by_offsets(data, offsets)
  end

  defp split_fixed(<<>>, _size, acc), do: Enum.reverse(acc)

  defp split_fixed(data, size, acc) when byte_size(data) >= size do
    <<row::binary-size(size), rest::binary>> = data
    split_fixed(rest, size, [row | acc])
  end

  defp split_fixed(_data, _size, acc), do: Enum.reverse(acc)

  defp split_by_offsets(_data, []), do: []

  defp split_by_offsets(data, offsets) when is_list(offsets) do
    total = byte_size(data)
    ends = tl(offsets) ++ [total]

    Enum.zip(offsets, ends)
    |> Enum.map(fn {start, stop} ->
      len = stop - start
      :binary.part(data, start, len)
    end)
  end
end
