defmodule Spacetimedbex.BSATN.ValueEncoder do
  @moduledoc """
  Schema-driven BSATN encoding. Inverse of `RowDecoder.decode_value/2`.

  Encodes Elixir values into BSATN binary using algebraic type information
  from the schema, so callers don't need to know the wire format.
  """

  alias Spacetimedbex.BSATN.Encoder

  @doc """
  Encode an Elixir value to BSATN binary given its algebraic type.

  ## Examples

      iex> encode_value(42, :u32)
      {:ok, <<42, 0, 0, 0>>}

      iex> encode_value("hello", :string)
      {:ok, <<5, 0, 0, 0, "hello">>}
  """
  @int_ranges %{
    u8: {0, 0xFF},
    i8: {-0x80, 0x7F},
    u16: {0, 0xFFFF},
    i16: {-0x8000, 0x7FFF},
    u32: {0, 0xFFFF_FFFF},
    i32: {-0x8000_0000, 0x7FFF_FFFF},
    u64: {0, 0xFFFF_FFFF_FFFF_FFFF},
    i64: {-0x8000_0000_0000_0000, 0x7FFF_FFFF_FFFF_FFFF},
    u128: {0, Bitwise.bsl(1, 128) - 1},
    i128: {-Bitwise.bsl(1, 127), Bitwise.bsl(1, 127) - 1},
    u256: {0, Bitwise.bsl(1, 256) - 1},
    i256: {-Bitwise.bsl(1, 255), Bitwise.bsl(1, 255) - 1}
  }

  def encode_value(val, :bool) when is_boolean(val), do: {:ok, Encoder.encode_bool(val)}

  for {type, {min, max}} <- @int_ranges do
    def encode_value(val, unquote(type)) when is_integer(val) do
      if val >= unquote(min) and val <= unquote(max) do
        {:ok, apply(Encoder, unquote(:"encode_#{type}"), [val])}
      else
        {:error, {:out_of_range, unquote(type), val}}
      end
    end
  end

  def encode_value(val, :f32) when is_float(val), do: {:ok, Encoder.encode_f32(val)}
  def encode_value(val, :f64) when is_float(val), do: {:ok, Encoder.encode_f64(val)}
  # Allow integers for float types (auto-convert)
  def encode_value(val, :f32) when is_integer(val), do: {:ok, Encoder.encode_f32(val / 1)}
  def encode_value(val, :f64) when is_integer(val), do: {:ok, Encoder.encode_f64(val / 1)}
  def encode_value(val, :string) when is_binary(val), do: {:ok, Encoder.encode_string(val)}
  def encode_value(val, :bytes) when is_binary(val), do: {:ok, Encoder.encode_bytes(val)}

  def encode_value(elements, {:array, inner_type}) when is_list(elements) do
    encode_array(elements, inner_type)
  end

  # Option: nil → None, {:some, val} → Some(val), bare val → Some(val) (ergonomic)
  def encode_value(nil, {:option, _inner_type}), do: {:ok, Encoder.encode_option(nil)}

  def encode_value({:some, val}, {:option, inner_type}) do
    with {:ok, encoded} <- encode_value(val, inner_type) do
      {:ok, Encoder.encode_option({:some, encoded})}
    end
  end

  def encode_value(val, {:option, inner_type}) do
    with {:ok, encoded} <- encode_value(val, inner_type) do
      {:ok, Encoder.encode_option({:some, encoded})}
    end
  end

  # Product: map of field names → values, encoded in column order
  def encode_value(val, {:product, columns}) when is_map(val) do
    encode_product(val, columns)
  end

  # Sum: `{variant_name, payload}` (name as string or atom). Unit variants may
  # also be given as a bare name, e.g. `"Active"` or `:Active`.
  def encode_value({name, payload}, {:sum, variants}) when is_binary(name) or is_atom(name) do
    with {:ok, tag, type} <- find_variant(variants, to_string(name)),
         {:ok, encoded} <- encode_value(payload, type) do
      {:ok, Encoder.encode_sum(tag, encoded)}
    end
  end

  def encode_value(name, {:sum, variants} = type)
      when is_binary(name) or (is_atom(name) and not is_nil(name) and not is_boolean(name)) do
    case find_variant(variants, to_string(name)) do
      {:ok, tag, {:product, []}} -> {:ok, Encoder.encode_sum(tag, <<>>)}
      {:ok, _tag, _type} -> {:error, {:type_mismatch, type, name}}
      error -> error
    end
  end

  def encode_value(val, {:map, key_type, value_type}) when is_map(val) do
    with {:ok, body} <- encode_all(val, &encode_pair(&1, key_type, value_type)) do
      {:ok, <<map_size(val)::little-unsigned-32, body::binary>>}
    end
  end

  def encode_value(val, type) do
    {:error, {:type_mismatch, type, val}}
  end

  @doc """
  Encode reducer arguments from a map of param names to values.

  Uses the reducer's param definitions (from schema) to encode each
  argument in the correct order as a BSATN product.

  ## Parameters
  - `args_map` - Map of `%{"param_name" => value}` or `%{param_name: value}`
  - `params` - List of `%{name: String.t(), type: algebraic_type()}` from schema
  """
  def encode_reducer_args(args_map, params) when is_map(args_map) and is_list(params) do
    encode_product(args_map, params)
  end

  # --- Internal ---

  defp find_variant(variants, name) do
    case Enum.find_index(variants, &(&1.name == name)) do
      nil -> {:error, {:unknown_variant, name}}
      tag -> {:ok, tag, Enum.at(variants, tag).type}
    end
  end

  defp encode_array(elements, inner_type) do
    with {:ok, body} <- encode_all(elements, &encode_value(&1, inner_type)) do
      {:ok, <<length(elements)::little-unsigned-32, body::binary>>}
    end
  end

  # Fields may be keyed by string or atom at any nesting level.
  defp encode_product(val_map, columns) do
    encode_all(columns, fn %{name: name, type: type} ->
      case fetch_field(val_map, name) do
        {:ok, val} -> encode_value(val, type)
        :error -> {:error, {:missing_field, name}}
      end
    end)
  end

  defp fetch_field(map, name) do
    case Map.fetch(map, name) do
      {:ok, _} = found -> found
      :error -> Enum.find_value(map, :error, &atom_key_match(&1, name))
    end
  end

  defp atom_key_match({k, v}, name) when is_atom(k) do
    if Atom.to_string(k) == name, do: {:ok, v}
  end

  defp atom_key_match(_, _name), do: nil

  defp encode_pair({k, v}, key_type, value_type) do
    with {:ok, ek} <- encode_value(k, key_type),
         {:ok, ev} <- encode_value(v, value_type) do
      {:ok, [ek, ev]}
    end
  end

  # Encodes each element with `fun`, stopping at the first error.
  defp encode_all(enumerable, fun) do
    enumerable
    |> Enum.reduce_while([], fn el, acc ->
      case fun.(el) do
        {:ok, bin} -> {:cont, [acc | bin]}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:error, _} = err -> err
      iodata -> {:ok, IO.iodata_to_binary(iodata)}
    end
  end
end
