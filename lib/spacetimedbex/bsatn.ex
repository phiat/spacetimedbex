defmodule Spacetimedbex.BSATN do
  @moduledoc """
  BSATN (Binary SpacetimeDB Algebraic Type Notation) codec.

  Convenience module that delegates to Encoder and Decoder, plus provides
  the `Encodable` protocol for custom types.
  """

  alias Spacetimedbex.BSATN.{Encoder, Decoder}

  defdelegate encode_bool(val), to: Encoder
  defdelegate encode_u8(val), to: Encoder
  defdelegate encode_i8(val), to: Encoder
  defdelegate encode_u16(val), to: Encoder
  defdelegate encode_i16(val), to: Encoder
  defdelegate encode_u32(val), to: Encoder
  defdelegate encode_i32(val), to: Encoder
  defdelegate encode_u64(val), to: Encoder
  defdelegate encode_i64(val), to: Encoder
  defdelegate encode_u128(val), to: Encoder
  defdelegate encode_i128(val), to: Encoder
  defdelegate encode_u256(val), to: Encoder
  defdelegate encode_i256(val), to: Encoder
  defdelegate encode_f32(val), to: Encoder
  defdelegate encode_f64(val), to: Encoder
  defdelegate encode_string(val), to: Encoder
  defdelegate encode_bytes(val), to: Encoder
  defdelegate encode_array(elements, encode_fn), to: Encoder
  defdelegate encode_sum(tag, payload), to: Encoder
  defdelegate encode_option(val), to: Encoder
  defdelegate encode_product(fields), to: Encoder

  defdelegate decode_bool(data), to: Decoder
  defdelegate decode_u8(data), to: Decoder
  defdelegate decode_i8(data), to: Decoder
  defdelegate decode_u16(data), to: Decoder
  defdelegate decode_i16(data), to: Decoder
  defdelegate decode_u32(data), to: Decoder
  defdelegate decode_i32(data), to: Decoder
  defdelegate decode_u64(data), to: Decoder
  defdelegate decode_i64(data), to: Decoder
  defdelegate decode_u128(data), to: Decoder
  defdelegate decode_i128(data), to: Decoder
  defdelegate decode_u256(data), to: Decoder
  defdelegate decode_i256(data), to: Decoder
  defdelegate decode_f32(data), to: Decoder
  defdelegate decode_f64(data), to: Decoder
  defdelegate decode_string(data), to: Decoder
  defdelegate decode_bytes(data), to: Decoder
  defdelegate decode_array(data, decode_fn), to: Decoder
  defdelegate decode_tag(data), to: Decoder
  defdelegate decode_option(data, decode_fn), to: Decoder
end
