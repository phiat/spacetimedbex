defmodule Spacetimedbex.Types do
  @moduledoc """
  Elixir representations of SpacetimeDB's special types.

  SpacetimeDB encodes these as single-field products on the wire. Schema
  parsing recognizes them (as `:identity`, `:connection_id`, `:timestamp`,
  `:time_duration` and `:uuid`), and decoding produces:

  | SpacetimeDB    | Wire          | Elixir                                                  |
  |----------------|---------------|---------------------------------------------------------|
  | `Identity`     | u256          | 64-char lowercase hex string (same as the CLI/HTTP API) |
  | `ConnectionId` | u128          | 32-char lowercase hex string                            |
  | `Timestamp`    | i64 µs        | `DateTime` (UTC, microsecond precision)                 |
  | `TimeDuration` | i64 µs        | `Duration` (in microseconds)                            |
  | `Uuid`         | u128          | `"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"` lowercase      |

  Hex strings are big-endian, matching SpacetimeDB's canonical `to_hex`.
  A timestamp outside `DateTime`'s range decodes to its raw microsecond integer.

  Encoding accepts these forms, plus raw integers and the legacy
  `%{"__identity__" => int}`-style maps.
  """

  @max_u128 Bitwise.bsl(1, 128) - 1
  @max_u256 Bitwise.bsl(1, 256) - 1

  # Wire-level marker for each special type: {field name, field type}.
  @markers %{
    {"__identity__", :u256} => :identity,
    {"__connection_id__", :u128} => :connection_id,
    {"__timestamp_micros_since_unix_epoch__", :i64} => :timestamp,
    {"__time_duration_micros__", :i64} => :time_duration,
    {"__uuid__", :u128} => :uuid
  }

  @doc false
  def special_type(field_name, field_type), do: Map.get(@markers, {field_name, field_type})

  @doc false
  def marker(type) do
    Enum.find_value(@markers, fn {{name, _}, t} -> if t == type, do: name end)
  end

  # --- Identity / ConnectionId ---

  @doc "Convert a u256 identity to its hex string."
  def identity_from_int(int), do: Base.encode16(<<int::unsigned-big-256>>, case: :lower)

  @doc "Convert an identity hex string (or integer) to its u256 value."
  def identity_to_int(value), do: hex_to_int(value, 64, @max_u256)

  @doc "Convert a u128 connection id to its hex string."
  def connection_id_from_int(int), do: Base.encode16(<<int::unsigned-big-128>>, case: :lower)

  @doc "Convert a connection id hex string (or integer) to its u128 value."
  def connection_id_to_int(value), do: hex_to_int(value, 32, @max_u128)

  # --- Timestamp / TimeDuration ---

  @doc "Convert microseconds since the Unix epoch to a `DateTime`."
  def timestamp_from_micros(micros) do
    case DateTime.from_unix(micros, :microsecond) do
      {:ok, dt} -> dt
      {:error, _} -> micros
    end
  end

  @doc "Convert a `DateTime` (or integer microseconds) to microseconds since the Unix epoch."
  def timestamp_to_micros(%DateTime{} = dt), do: {:ok, DateTime.to_unix(dt, :microsecond)}
  def timestamp_to_micros(micros) when is_integer(micros), do: {:ok, micros}
  def timestamp_to_micros(_), do: :error

  @doc "Convert microseconds to a `Duration`."
  def duration_from_micros(micros), do: Duration.new!(microsecond: {micros, 6})

  @doc """
  Convert a `Duration` (or integer microseconds) to microseconds.
  Durations with years or months are rejected (their length is calendar-dependent).
  """
  def duration_to_micros(%Duration{year: 0, month: 0} = d) do
    {us, _precision} = d.microsecond

    {:ok,
     us +
       1_000_000 *
         (d.second + 60 * (d.minute + 60 * (d.hour + 24 * (d.day + 7 * d.week))))}
  end

  def duration_to_micros(micros) when is_integer(micros), do: {:ok, micros}
  def duration_to_micros(_), do: :error

  # --- Uuid ---

  @doc "Convert a u128 to a UUID string."
  def uuid_from_int(int) do
    <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> =
      Base.encode16(<<int::unsigned-big-128>>, case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end

  @doc "Convert a UUID string (with or without dashes) or integer to its u128 value."
  def uuid_to_int(value) when is_binary(value),
    do: hex_to_int(String.replace(value, "-", ""), 32, @max_u128)

  def uuid_to_int(value), do: hex_to_int(value, 32, @max_u128)

  defp hex_to_int(int, _len, max) when is_integer(int) and int >= 0 and int <= max, do: {:ok, int}

  defp hex_to_int(hex, len, _max) when is_binary(hex) and byte_size(hex) == len do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> {:ok, :binary.decode_unsigned(bytes, :big)}
      :error -> :error
    end
  end

  defp hex_to_int(_, _, _), do: :error
end
