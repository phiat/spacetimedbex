defmodule Spacetimedbex.ClientCache.RowDecoder do
  @moduledoc """
  Decodes BSATN row data into Elixir maps using table schema.

  Takes a `BsatnRowList` (as returned in SubscribeApplied / TransactionUpdate)
  and a list of column definitions, and produces a list of row maps.
  """

  alias Spacetimedbex.BSATN.Decoder
  alias Spacetimedbex.Schema

  @typedoc "Decoded row changes for one table within a transaction."
  @type table_changes :: %{
          table_name: String.t(),
          inserts: [map()],
          deletes: [map()],
          events: [map()]
        }

  @doc """
  Decode per-table row lists (from SubscribeApplied, UnsubscribeApplied or
  OneOffQueryResult) into `[{table_name, rows}]`. Unknown tables yield `[]`.
  """
  @spec decode_table_rows(Schema.t(), [%{table_name: String.t(), rows: map()}]) ::
          [{String.t(), [map()]}]
  def decode_table_rows(schema, table_rows) do
    Enum.map(table_rows, fn %{table_name: table_name, rows: row_list} ->
      {table_name, decode_for_table(schema, table_name, row_list)}
    end)
  end

  @doc """
  Decode the query sets of a TransactionUpdate into per-table changes.

  Event-table rows are returned under `:events`; they are never persisted.
  """
  @spec decode_query_sets(Schema.t(), [map()]) :: [table_changes()]
  def decode_query_sets(schema, query_sets) do
    for %{tables: tables} <- query_sets,
        %{table_name: table_name, rows: update_rows} <- tables do
      empty = %{table_name: table_name, inserts: [], deletes: [], events: []}

      Enum.reduce(update_rows, empty, fn
        {:persistent, %{inserts: ins, deletes: del}}, acc ->
          %{
            acc
            | inserts: acc.inserts ++ decode_for_table(schema, table_name, ins),
              deletes: acc.deletes ++ decode_for_table(schema, table_name, del)
          }

        {:event, events}, acc ->
          %{acc | events: acc.events ++ decode_for_table(schema, table_name, events)}
      end)
    end
  end

  defp decode_for_table(schema, table_name, row_list) do
    case Schema.columns_for(schema, table_name) do
      {:ok, columns} -> decode_row_list(row_list, columns)
      {:error, _} -> []
    end
  end

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
    Enum.reduce_while(columns, {:ok, %{}, data}, fn col, {:ok, acc, rest} ->
      case decode_value(rest, col.type) do
        {:ok, value, rest2} -> {:cont, {:ok, Map.put(acc, col.name, value), rest2}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Sum (enum) values decode to `{variant_name, payload}`. Unit variants carry
  # an empty product, so their payload is `%{}`.
  def decode_value(<<tag, rest::binary>>, {:sum, variants}) do
    case Enum.at(variants, tag) do
      nil ->
        {:error, {:invalid_sum_tag, tag}}

      %{name: name, type: type} ->
        with {:ok, value, rest2} <- decode_value(rest, type) do
          {:ok, {name, value}, rest2}
        end
    end
  end

  def decode_value(<<>>, {:sum, _}), do: {:error, :unexpected_eof}

  def decode_value(data, {:map, key_type, value_type}) do
    with {:ok, pairs, rest} <-
           Decoder.decode_array(data, &decode_pair(&1, key_type, value_type)) do
      {:ok, Map.new(pairs), rest}
    end
  end

  def decode_value(_data, {:unknown, _}), do: {:error, :unknown_type}

  defp decode_pair(data, key_type, value_type) do
    with {:ok, k, rest} <- decode_value(data, key_type),
         {:ok, v, rest} <- decode_value(rest, value_type) do
      {:ok, {k, v}, rest}
    end
  end

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
    <<row::binary-size(^size), rest::binary>> = data
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
