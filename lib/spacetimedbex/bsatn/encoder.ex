defmodule Spacetimedbex.BSATN.Encoder do
  @moduledoc """
  Encodes Elixir values into BSATN (Binary SpacetimeDB Algebraic Type Notation).

  All integers are little-endian. Strings and arrays have u32 length prefixes.
  Structs (products) are unframed concatenated fields. Enums (sums) use a u8 tag.
  """

  @doc "Encode a boolean as 1 byte."
  def encode_bool(true), do: <<1>>
  def encode_bool(false), do: <<0>>

  @doc "Encode an unsigned 8-bit integer."
  def encode_u8(val) when val in 0..255, do: <<val::8>>

  @doc "Encode a signed 8-bit integer."
  def encode_i8(val) when val in -128..127, do: <<val::signed-8>>

  @doc "Encode an unsigned 16-bit integer, little-endian."
  def encode_u16(val), do: <<val::little-unsigned-16>>

  @doc "Encode a signed 16-bit integer, little-endian."
  def encode_i16(val), do: <<val::little-signed-16>>

  @doc "Encode an unsigned 32-bit integer, little-endian."
  def encode_u32(val), do: <<val::little-unsigned-32>>

  @doc "Encode a signed 32-bit integer, little-endian."
  def encode_i32(val), do: <<val::little-signed-32>>

  @doc "Encode an unsigned 64-bit integer, little-endian."
  def encode_u64(val), do: <<val::little-unsigned-64>>

  @doc "Encode a signed 64-bit integer, little-endian."
  def encode_i64(val), do: <<val::little-signed-64>>

  @doc "Encode an unsigned 128-bit integer, little-endian."
  def encode_u128(val), do: <<val::little-unsigned-128>>

  @doc "Encode a signed 128-bit integer, little-endian."
  def encode_i128(val), do: <<val::little-signed-128>>

  @doc "Encode an unsigned 256-bit integer, little-endian."
  def encode_u256(val), do: <<val::little-unsigned-256>>

  @doc "Encode a signed 256-bit integer, little-endian."
  def encode_i256(val), do: <<val::little-signed-256>>

  @doc "Encode a 32-bit float (IEEE 754), stored as u32 bits, little-endian."
  def encode_f32(val) when is_float(val), do: <<val::little-float-32>>

  @doc "Encode a 64-bit float (IEEE 754), stored as u64 bits, little-endian."
  def encode_f64(val) when is_float(val), do: <<val::little-float-64>>

  @doc "Encode a UTF-8 string: u32 length prefix + raw bytes."
  def encode_string(str) when is_binary(str) do
    len = byte_size(str)
    <<len::little-unsigned-32, str::binary>>
  end

  @doc "Encode raw bytes: u32 length prefix + data."
  def encode_bytes(data) when is_binary(data) do
    len = byte_size(data)
    <<len::little-unsigned-32, data::binary>>
  end

  @doc """
  Encode an array of elements using the given element encoder function.
  u32 count prefix + concatenated encoded elements.
  """
  def encode_array(elements, encode_fn) when is_list(elements) do
    count = length(elements)
    encoded = Enum.map(elements, encode_fn) |> IO.iodata_to_binary()
    <<count::little-unsigned-32, encoded::binary>>
  end

  @doc """
  Encode a sum type (enum variant): u8 tag + encoded payload.
  """
  def encode_sum(tag, payload_binary) when tag in 0..255 do
    <<tag::8, payload_binary::binary>>
  end

  @doc """
  Encode an Option: tag 0 = Some(value), tag 1 = None.
  Note: SpacetimeDB uses 0=Some, 1=None (opposite of Rust's convention).
  """
  def encode_option(nil), do: <<1>>
  def encode_option({:some, encoded_value}), do: <<0, encoded_value::binary>>

  @doc """
  Encode a product (struct): just concatenate all field binaries in order.
  """
  def encode_product(field_binaries) when is_list(field_binaries) do
    IO.iodata_to_binary(field_binaries)
  end
end
