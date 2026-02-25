defmodule Spacetimedbex.Protocol do
  @moduledoc """
  SpacetimeDB v2 WebSocket protocol message types and encoding/decoding.

  Client messages are raw BSATN. Server messages have a 1-byte compression
  prefix (0x00=none, 0x01=brotli, 0x02=gzip) followed by BSATN payload.
  """
end
