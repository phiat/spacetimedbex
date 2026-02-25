defmodule Spacetimedbex.Protocol.ServerMessage do
  @moduledoc """
  V2 server-to-client messages. Received with a 1-byte compression envelope.

  ## Variants (u8 tag)
  - 0: InitialConnection
  - 1: SubscribeApplied
  - 2: UnsubscribeApplied
  - 3: SubscriptionError
  - 4: TransactionUpdate
  - 5: OneOffQueryResult
  - 6: ReducerResult
  - 7: ProcedureResult
  """

  alias Spacetimedbex.BSATN.Decoder

  # --- Structs ---

  defmodule InitialConnection do
    @moduledoc false
    defstruct [:identity, :connection_id, :token]

    @type t :: %__MODULE__{
            identity: binary(),
            connection_id: binary(),
            token: String.t()
          }
  end

  defmodule SubscribeApplied do
    @moduledoc false
    defstruct [:request_id, :query_set_id, :rows]

    @type t :: %__MODULE__{
            request_id: non_neg_integer(),
            query_set_id: non_neg_integer(),
            rows: [table_rows()]
          }

    @type table_rows :: %{table: String.t(), rows: Spacetimedbex.Protocol.BsatnRowList.t()}
  end

  defmodule UnsubscribeApplied do
    @moduledoc false
    defstruct [:request_id, :query_set_id, :rows]
  end

  defmodule SubscriptionError do
    @moduledoc false
    defstruct [:request_id, :query_set_id, :error]

    @type t :: %__MODULE__{
            request_id: non_neg_integer() | nil,
            query_set_id: non_neg_integer(),
            error: String.t()
          }
  end

  defmodule TransactionUpdate do
    @moduledoc false
    defstruct [:query_sets]

    @type t :: %__MODULE__{
            query_sets: [query_set_update()]
          }

    @type query_set_update :: %{
            query_set_id: non_neg_integer(),
            tables: [table_update()]
          }

    @type table_update :: %{
            table_name: String.t(),
            rows: [table_update_rows()]
          }

    @type table_update_rows ::
            {:persistent, %{inserts: binary(), deletes: binary()}}
            | {:event, binary()}
  end

  defmodule ReducerResult do
    @moduledoc false
    defstruct [:request_id, :timestamp, :result]

    @type t :: %__MODULE__{
            request_id: non_neg_integer(),
            timestamp: integer(),
            result: reducer_outcome()
          }

    @type reducer_outcome ::
            {:ok, binary(), TransactionUpdate.t()}
            | :ok_empty
            | {:error, binary()}
            | {:internal_error, String.t()}
  end

  defmodule OneOffQueryResult do
    @moduledoc false
    defstruct [:request_id, :result]
  end

  defmodule ProcedureResult do
    @moduledoc false
    defstruct [:status, :timestamp, :total_host_execution_duration, :request_id]
  end

  # --- Compression envelope ---

  @compression_none 0x00
  @compression_brotli 0x01
  @compression_gzip 0x02

  @doc "Unwrap the compression envelope from a server binary frame."
  def decompress(<<@compression_none, payload::binary>>), do: {:ok, payload}

  def decompress(<<@compression_gzip, payload::binary>>) do
    {:ok, :zlib.gunzip(payload)}
  rescue
    e -> {:error, {:decompression_failed, :gzip, e}}
  end

  def decompress(<<@compression_brotli, _payload::binary>>) do
    # Brotli requires a NIF or external library - defer for now
    {:error, :brotli_not_supported}
  end

  def decompress(<<tag, _::binary>>), do: {:error, {:unknown_compression, tag}}
  def decompress(<<>>), do: {:error, :empty_frame}

  # --- Decoding ---

  @doc "Decode a decompressed BSATN server message."
  def decode(data) do
    with {:ok, tag, rest} <- Decoder.decode_tag(data) do
      decode_variant(tag, rest)
    end
  end

  defp decode_variant(0, data) do
    with {:ok, identity, rest} <- decode_identity(data),
         {:ok, connection_id, rest} <- decode_connection_id(rest),
         {:ok, token, rest} <- Decoder.decode_string(rest) do
      {:ok,
       %InitialConnection{
         identity: identity,
         connection_id: connection_id,
         token: token
       }, rest}
    end
  end

  defp decode_variant(1, data) do
    with {:ok, request_id, rest} <- Decoder.decode_u32(data),
         {:ok, query_set_id, rest} <- Decoder.decode_u32(rest),
         {:ok, rows, rest} <- decode_query_rows(rest) do
      {:ok,
       %SubscribeApplied{
         request_id: request_id,
         query_set_id: query_set_id,
         rows: rows
       }, rest}
    end
  end

  defp decode_variant(2, data) do
    with {:ok, request_id, rest} <- Decoder.decode_u32(data),
         {:ok, query_set_id, rest} <- Decoder.decode_u32(rest),
         {:ok, rows, rest} <- Decoder.decode_option(rest, &decode_query_rows/1) do
      {:ok,
       %UnsubscribeApplied{
         request_id: request_id,
         query_set_id: query_set_id,
         rows: rows
       }, rest}
    end
  end

  defp decode_variant(3, data) do
    with {:ok, request_id, rest} <- Decoder.decode_option(data, &Decoder.decode_u32/1),
         {:ok, query_set_id, rest} <- Decoder.decode_u32(rest),
         {:ok, error, rest} <- Decoder.decode_string(rest) do
      req_id =
        case request_id do
          {:some, val} -> val
          nil -> nil
        end

      {:ok,
       %SubscriptionError{
         request_id: req_id,
         query_set_id: query_set_id,
         error: error
       }, rest}
    end
  end

  defp decode_variant(4, data) do
    with {:ok, query_sets, rest} <- decode_transaction_update(data) do
      {:ok, %TransactionUpdate{query_sets: query_sets}, rest}
    end
  end

  defp decode_variant(5, data) do
    # OneOffQueryResult - basic decode
    with {:ok, request_id, rest} <- Decoder.decode_u32(data) do
      {:ok, %OneOffQueryResult{request_id: request_id, result: rest}, <<>>}
    end
  end

  defp decode_variant(6, data) do
    with {:ok, request_id, rest} <- Decoder.decode_u32(data),
         {:ok, timestamp, rest} <- Decoder.decode_i64(rest),
         {:ok, result, rest} <- decode_reducer_outcome(rest) do
      {:ok,
       %ReducerResult{
         request_id: request_id,
         timestamp: timestamp,
         result: result
       }, rest}
    end
  end

  defp decode_variant(7, data) do
    with {:ok, status, rest} <- decode_procedure_status(data),
         {:ok, timestamp, rest} <- Decoder.decode_i64(rest),
         {:ok, duration, rest} <- Decoder.decode_i64(rest),
         {:ok, request_id, rest} <- Decoder.decode_u32(rest) do
      {:ok,
       %ProcedureResult{
         status: status,
         timestamp: timestamp,
         total_host_execution_duration: duration,
         request_id: request_id
       }, rest}
    end
  end

  defp decode_variant(tag, _), do: {:error, {:unknown_server_message_tag, tag}}

  # --- Helpers ---

  # Identity is a u256 (32 bytes)
  defp decode_identity(<<val::binary-size(32), rest::binary>>), do: {:ok, val, rest}
  defp decode_identity(_), do: {:error, :unexpected_eof}

  # ConnectionId is a u128 (16 bytes)
  defp decode_connection_id(<<val::binary-size(16), rest::binary>>), do: {:ok, val, rest}
  defp decode_connection_id(_), do: {:error, :unexpected_eof}

  # QueryRows = { tables: [SingleTableRows] }
  defp decode_query_rows(data) do
    Decoder.decode_array(data, &decode_single_table_rows/1)
  end

  # SingleTableRows = { table: string, rows: BsatnRowList }
  defp decode_single_table_rows(data) do
    with {:ok, table_name, rest} <- Decoder.decode_string(data),
         {:ok, row_list, rest} <- decode_bsatn_row_list(rest) do
      {:ok, %{table: table_name, rows: row_list}, rest}
    end
  end

  # BsatnRowList = { size_hint: RowSizeHint, rows_data: bytes }
  defp decode_bsatn_row_list(data) do
    with {:ok, size_hint, rest} <- decode_row_size_hint(data),
         {:ok, rows_data, rest} <- Decoder.decode_bytes(rest) do
      {:ok, %{size_hint: size_hint, rows_data: rows_data}, rest}
    end
  end

  # RowSizeHint: tag 0 = FixedSize(u16), tag 1 = RowOffsets([u64])
  defp decode_row_size_hint(<<0, rest::binary>>) do
    with {:ok, size, rest} <- Decoder.decode_u16(rest) do
      {:ok, {:fixed_size, size}, rest}
    end
  end

  defp decode_row_size_hint(<<1, rest::binary>>) do
    with {:ok, offsets, rest} <- Decoder.decode_array(rest, &Decoder.decode_u64/1) do
      {:ok, {:row_offsets, offsets}, rest}
    end
  end

  defp decode_row_size_hint(<<tag, _::binary>>), do: {:error, {:unknown_row_size_hint_tag, tag}}
  defp decode_row_size_hint(_), do: {:error, :unexpected_eof}

  # TransactionUpdate = { query_sets: [QuerySetUpdate] }
  defp decode_transaction_update(data) do
    Decoder.decode_array(data, &decode_query_set_update/1)
  end

  # QuerySetUpdate = { query_set_id: u32, tables: [TableUpdate] }
  defp decode_query_set_update(data) do
    with {:ok, query_set_id, rest} <- Decoder.decode_u32(data),
         {:ok, tables, rest} <- Decoder.decode_array(rest, &decode_table_update/1) do
      {:ok, %{query_set_id: query_set_id, tables: tables}, rest}
    end
  end

  # TableUpdate = { table_name: string, rows: [TableUpdateRows] }
  defp decode_table_update(data) do
    with {:ok, table_name, rest} <- Decoder.decode_string(data),
         {:ok, rows, rest} <- Decoder.decode_array(rest, &decode_table_update_rows/1) do
      {:ok, %{table_name: table_name, rows: rows}, rest}
    end
  end

  # TableUpdateRows: tag 0 = PersistentTable, tag 1 = EventTable
  defp decode_table_update_rows(<<0, rest::binary>>) do
    with {:ok, inserts, rest} <- decode_bsatn_row_list(rest),
         {:ok, deletes, rest} <- decode_bsatn_row_list(rest) do
      {:ok, {:persistent, %{inserts: inserts, deletes: deletes}}, rest}
    end
  end

  defp decode_table_update_rows(<<1, rest::binary>>) do
    with {:ok, events, rest} <- decode_bsatn_row_list(rest) do
      {:ok, {:event, events}, rest}
    end
  end

  defp decode_table_update_rows(<<tag, _::binary>>),
    do: {:error, {:unknown_table_update_rows_tag, tag}}

  defp decode_table_update_rows(_), do: {:error, :unexpected_eof}

  # ReducerOutcome: tag 0 = Ok, tag 1 = OkEmpty, tag 2 = Err, tag 3 = InternalError
  defp decode_reducer_outcome(<<0, rest::binary>>) do
    with {:ok, ret_value, rest} <- Decoder.decode_bytes(rest),
         {:ok, query_sets, rest} <- decode_transaction_update(rest) do
      {:ok, {:ok, ret_value, %TransactionUpdate{query_sets: query_sets}}, rest}
    end
  end

  defp decode_reducer_outcome(<<1, rest::binary>>), do: {:ok, :ok_empty, rest}

  defp decode_reducer_outcome(<<2, rest::binary>>) do
    with {:ok, err_bytes, rest} <- Decoder.decode_bytes(rest) do
      {:ok, {:error, err_bytes}, rest}
    end
  end

  defp decode_reducer_outcome(<<3, rest::binary>>) do
    with {:ok, msg, rest} <- Decoder.decode_string(rest) do
      {:ok, {:internal_error, msg}, rest}
    end
  end

  defp decode_reducer_outcome(<<tag, _::binary>>),
    do: {:error, {:unknown_reducer_outcome_tag, tag}}

  defp decode_reducer_outcome(_), do: {:error, :unexpected_eof}

  # ProcedureStatus: tag 0 = Returned(bytes), tag 1 = InternalError(string)
  defp decode_procedure_status(<<0, rest::binary>>) do
    with {:ok, val, rest} <- Decoder.decode_bytes(rest) do
      {:ok, {:returned, val}, rest}
    end
  end

  defp decode_procedure_status(<<1, rest::binary>>) do
    with {:ok, msg, rest} <- Decoder.decode_string(rest) do
      {:ok, {:internal_error, msg}, rest}
    end
  end

  defp decode_procedure_status(<<tag, _::binary>>),
    do: {:error, {:unknown_procedure_status_tag, tag}}

  defp decode_procedure_status(_), do: {:error, :unexpected_eof}
end
