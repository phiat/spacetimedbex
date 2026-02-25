defmodule Spacetimedbex.BSATN.Decoder do
  @moduledoc """
  Decodes BSATN binary data into Elixir values.

  All functions return `{value, rest}` tuples where `rest` is the unconsumed binary,
  or `{:error, reason}` on failure.
  """

  @doc "Decode a boolean (1 byte)."
  def decode_bool(<<0, rest::binary>>), do: {:ok, false, rest}
  def decode_bool(<<1, rest::binary>>), do: {:ok, true, rest}
  def decode_bool(<<v, _::binary>>), do: {:error, {:invalid_bool, v}}
  def decode_bool(<<>>), do: {:error, :unexpected_eof}

  @doc "Decode an unsigned 8-bit integer."
  def decode_u8(<<val::8, rest::binary>>), do: {:ok, val, rest}
  def decode_u8(<<>>), do: {:error, :unexpected_eof}

  @doc "Decode a signed 8-bit integer."
  def decode_i8(<<val::signed-8, rest::binary>>), do: {:ok, val, rest}
  def decode_i8(<<>>), do: {:error, :unexpected_eof}

  @doc "Decode an unsigned 16-bit integer, little-endian."
  def decode_u16(<<val::little-unsigned-16, rest::binary>>), do: {:ok, val, rest}
  def decode_u16(_), do: {:error, :unexpected_eof}

  @doc "Decode a signed 16-bit integer, little-endian."
  def decode_i16(<<val::little-signed-16, rest::binary>>), do: {:ok, val, rest}
  def decode_i16(_), do: {:error, :unexpected_eof}

  @doc "Decode an unsigned 32-bit integer, little-endian."
  def decode_u32(<<val::little-unsigned-32, rest::binary>>), do: {:ok, val, rest}
  def decode_u32(_), do: {:error, :unexpected_eof}

  @doc "Decode a signed 32-bit integer, little-endian."
  def decode_i32(<<val::little-signed-32, rest::binary>>), do: {:ok, val, rest}
  def decode_i32(_), do: {:error, :unexpected_eof}

  @doc "Decode an unsigned 64-bit integer, little-endian."
  def decode_u64(<<val::little-unsigned-64, rest::binary>>), do: {:ok, val, rest}
  def decode_u64(_), do: {:error, :unexpected_eof}

  @doc "Decode a signed 64-bit integer, little-endian."
  def decode_i64(<<val::little-signed-64, rest::binary>>), do: {:ok, val, rest}
  def decode_i64(_), do: {:error, :unexpected_eof}

  @doc "Decode an unsigned 128-bit integer, little-endian."
  def decode_u128(<<val::little-unsigned-128, rest::binary>>), do: {:ok, val, rest}
  def decode_u128(_), do: {:error, :unexpected_eof}

  @doc "Decode a signed 128-bit integer, little-endian."
  def decode_i128(<<val::little-signed-128, rest::binary>>), do: {:ok, val, rest}
  def decode_i128(_), do: {:error, :unexpected_eof}

  @doc "Decode an unsigned 256-bit integer, little-endian."
  def decode_u256(<<val::little-unsigned-256, rest::binary>>), do: {:ok, val, rest}
  def decode_u256(_), do: {:error, :unexpected_eof}

  @doc "Decode a signed 256-bit integer, little-endian."
  def decode_i256(<<val::little-signed-256, rest::binary>>), do: {:ok, val, rest}
  def decode_i256(_), do: {:error, :unexpected_eof}

  @doc "Decode a 32-bit float, little-endian."
  def decode_f32(<<val::little-float-32, rest::binary>>), do: {:ok, val, rest}
  def decode_f32(_), do: {:error, :unexpected_eof}

  @doc "Decode a 64-bit float, little-endian."
  def decode_f64(<<val::little-float-64, rest::binary>>), do: {:ok, val, rest}
  def decode_f64(_), do: {:error, :unexpected_eof}

  @doc "Decode a length-prefixed UTF-8 string."
  def decode_string(<<len::little-unsigned-32, data::binary-size(len), rest::binary>>) do
    {:ok, data, rest}
  end

  def decode_string(<<_len::little-unsigned-32, _::binary>>), do: {:error, :unexpected_eof}
  def decode_string(_), do: {:error, :unexpected_eof}

  @doc "Decode length-prefixed raw bytes."
  def decode_bytes(<<len::little-unsigned-32, data::binary-size(len), rest::binary>>) do
    {:ok, data, rest}
  end

  def decode_bytes(<<_len::little-unsigned-32, _::binary>>), do: {:error, :unexpected_eof}
  def decode_bytes(_), do: {:error, :unexpected_eof}

  @doc """
  Decode an array: u32 count + repeated elements using the given decoder function.
  The decoder function receives binary and returns {:ok, value, rest}.
  """
  def decode_array(<<count::little-unsigned-32, rest::binary>>, decode_fn) do
    decode_array_elements(rest, count, decode_fn, [])
  end

  def decode_array(_, _decode_fn), do: {:error, :unexpected_eof}

  defp decode_array_elements(rest, 0, _decode_fn, acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp decode_array_elements(data, remaining, decode_fn, acc) do
    case decode_fn.(data) do
      {:ok, value, rest} ->
        decode_array_elements(rest, remaining - 1, decode_fn, [value | acc])

      {:error, _} = err ->
        err
    end
  end

  @doc "Decode a sum type tag (u8)."
  def decode_tag(<<tag::8, rest::binary>>), do: {:ok, tag, rest}
  def decode_tag(<<>>), do: {:error, :unexpected_eof}

  @doc """
  Decode an Option: tag 0 = Some(value), tag 1 = None.
  """
  def decode_option(<<0, rest::binary>>, decode_fn) do
    case decode_fn.(rest) do
      {:ok, value, rest2} -> {:ok, {:some, value}, rest2}
      {:error, _} = err -> err
    end
  end

  def decode_option(<<1, rest::binary>>, _decode_fn), do: {:ok, nil, rest}
  def decode_option(<<tag, _::binary>>, _), do: {:error, {:invalid_option_tag, tag}}
  def decode_option(<<>>, _), do: {:error, :unexpected_eof}
end
