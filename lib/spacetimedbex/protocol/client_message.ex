defmodule Spacetimedbex.Protocol.ClientMessage do
  @moduledoc """
  V2 client-to-server messages. Encoded as raw BSATN (no compression envelope).

  ## Variants (u8 tag)
  - 0: Subscribe
  - 1: Unsubscribe
  - 2: OneOffQuery
  - 3: CallReducer
  - 4: CallProcedure
  """

  alias Spacetimedbex.BSATN.Encoder

  # --- Structs ---

  defmodule Subscribe do
    @moduledoc false
    defstruct [:request_id, :query_set_id, :query_strings]

    @type t :: %__MODULE__{
            request_id: non_neg_integer(),
            query_set_id: non_neg_integer(),
            query_strings: [String.t()]
          }
  end

  defmodule Unsubscribe do
    @moduledoc false
    @unsubscribe_default 0
    @unsubscribe_send_dropped_rows 1

    defstruct [:request_id, :query_set_id, flags: :default]

    @type t :: %__MODULE__{
            request_id: non_neg_integer(),
            query_set_id: non_neg_integer(),
            flags: :default | :send_dropped_rows
          }

    def flags_to_u8(:default), do: @unsubscribe_default
    def flags_to_u8(:send_dropped_rows), do: @unsubscribe_send_dropped_rows
  end

  defmodule OneOffQuery do
    @moduledoc false
    defstruct [:request_id, :query_string]

    @type t :: %__MODULE__{
            request_id: non_neg_integer(),
            query_string: String.t()
          }
  end

  defmodule CallReducer do
    @moduledoc false
    defstruct [:request_id, :reducer, :args, flags: :default]

    @type t :: %__MODULE__{
            request_id: non_neg_integer(),
            flags: :default,
            reducer: String.t(),
            args: binary()
          }
  end

  defmodule CallProcedure do
    @moduledoc false
    defstruct [:request_id, :procedure, :args, flags: :default]

    @type t :: %__MODULE__{
            request_id: non_neg_integer(),
            flags: :default,
            procedure: String.t(),
            args: binary()
          }
  end

  # --- Encoding ---

  @doc "Encode a client message to raw BSATN binary."
  def encode(%Subscribe{} = msg) do
    payload =
      Encoder.encode_product([
        Encoder.encode_u32(msg.request_id),
        Encoder.encode_u32(msg.query_set_id),
        Encoder.encode_array(msg.query_strings, &Encoder.encode_string/1)
      ])

    Encoder.encode_sum(0, payload)
  end

  def encode(%Unsubscribe{} = msg) do
    payload =
      Encoder.encode_product([
        Encoder.encode_u32(msg.request_id),
        Encoder.encode_u32(msg.query_set_id),
        Encoder.encode_u8(Unsubscribe.flags_to_u8(msg.flags))
      ])

    Encoder.encode_sum(1, payload)
  end

  def encode(%OneOffQuery{} = msg) do
    payload =
      Encoder.encode_product([
        Encoder.encode_u32(msg.request_id),
        Encoder.encode_string(msg.query_string)
      ])

    Encoder.encode_sum(2, payload)
  end

  def encode(%CallReducer{} = msg) do
    payload =
      Encoder.encode_product([
        Encoder.encode_u32(msg.request_id),
        Encoder.encode_u8(0),
        Encoder.encode_string(msg.reducer),
        Encoder.encode_bytes(msg.args)
      ])

    Encoder.encode_sum(3, payload)
  end

  def encode(%CallProcedure{} = msg) do
    payload =
      Encoder.encode_product([
        Encoder.encode_u32(msg.request_id),
        Encoder.encode_u8(0),
        Encoder.encode_string(msg.procedure),
        Encoder.encode_bytes(msg.args)
      ])

    Encoder.encode_sum(4, payload)
  end
end
