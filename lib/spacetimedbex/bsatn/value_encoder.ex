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
  def encode_value(val, :bool) when is_boolean(val), do: {:ok, Encoder.encode_bool(val)}
  def encode_value(val, :u8) when is_integer(val), do: {:ok, Encoder.encode_u8(val)}
  def encode_value(val, :i8) when is_integer(val), do: {:ok, Encoder.encode_i8(val)}
  def encode_value(val, :u16) when is_integer(val), do: {:ok, Encoder.encode_u16(val)}
  def encode_value(val, :i16) when is_integer(val), do: {:ok, Encoder.encode_i16(val)}
  def encode_value(val, :u32) when is_integer(val), do: {:ok, Encoder.encode_u32(val)}
  def encode_value(val, :i32) when is_integer(val), do: {:ok, Encoder.encode_i32(val)}
  def encode_value(val, :u64) when is_integer(val), do: {:ok, Encoder.encode_u64(val)}
  def encode_value(val, :i64) when is_integer(val), do: {:ok, Encoder.encode_i64(val)}
  def encode_value(val, :u128) when is_integer(val), do: {:ok, Encoder.encode_u128(val)}
  def encode_value(val, :i128) when is_integer(val), do: {:ok, Encoder.encode_i128(val)}
  def encode_value(val, :u256) when is_integer(val), do: {:ok, Encoder.encode_u256(val)}
  def encode_value(val, :i256) when is_integer(val), do: {:ok, Encoder.encode_i256(val)}
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
    # Normalize keys to strings
    normalized =
      Map.new(args_map, fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        {k, v} when is_binary(k) -> {k, v}
      end)

    encode_product(normalized, params)
  end

  # --- Internal ---

  defp encode_array(elements, inner_type) do
    results = Enum.map(elements, &encode_value(&1, inner_type))

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        encoded_elements = Enum.map(results, fn {:ok, bin} -> bin end)
        count = length(encoded_elements)
        body = IO.iodata_to_binary(encoded_elements)
        {:ok, <<count::little-unsigned-32, body::binary>>}

      error ->
        error
    end
  end

  defp encode_product(val_map, columns) do
    results =
      Enum.map(columns, fn %{name: name, type: type} ->
        case Map.fetch(val_map, name) do
          {:ok, val} -> encode_value(val, type)
          :error -> {:error, {:missing_field, name}}
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        binaries = Enum.map(results, fn {:ok, bin} -> bin end)
        {:ok, IO.iodata_to_binary(binaries)}

      error ->
        error
    end
  end
end
