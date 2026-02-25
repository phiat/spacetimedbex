defmodule Spacetimedbex.Schema do
  @moduledoc """
  Fetches and parses SpacetimeDB module schema.

  The schema describes tables (columns, types, primary keys), reducers (params),
  and the typespace (algebraic type definitions). Used by the ClientCache to
  decode BSATN row data into Elixir maps.
  """

  @schema_version "9"

  defstruct [:tables, :reducers, :typespace]

  @type algebraic_type ::
          :bool
          | :u8
          | :i8
          | :u16
          | :i16
          | :u32
          | :i32
          | :u64
          | :i64
          | :u128
          | :i128
          | :u256
          | :i256
          | :f32
          | :f64
          | :string
          | :bytes
          | {:array, algebraic_type()}
          | {:option, algebraic_type()}
          | {:product, [column()]}
          | {:ref, non_neg_integer()}

  @type column :: %{name: String.t(), type: algebraic_type()}

  @type table_def :: %{
          name: String.t(),
          columns: [column()],
          primary_key: [non_neg_integer()]
        }

  @type reducer_def :: %{
          name: String.t(),
          params: [column()]
        }

  @type t :: %__MODULE__{
          tables: %{String.t() => table_def()},
          reducers: %{String.t() => reducer_def()},
          typespace: [term()]
        }

  @doc "Fetch and parse schema from a SpacetimeDB instance."
  def fetch(host, database) do
    url = "http://#{host}/v1/database/#{database}/schema?version=#{@schema_version}"

    case Req.get(url) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, parse(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Parse a raw schema JSON map into a structured Schema."
  def parse(raw) when is_map(raw) do
    typespace = parse_typespace(raw["typespace"])
    tables = parse_tables(raw["tables"], typespace)
    reducers = parse_reducers(raw["reducers"])

    %__MODULE__{
      tables: tables,
      reducers: reducers,
      typespace: typespace
    }
  end

  @doc "Get column definitions for a table."
  def columns_for(%__MODULE__{tables: tables}, table_name) do
    case Map.get(tables, table_name) do
      nil -> {:error, {:unknown_table, table_name}}
      table_def -> {:ok, table_def.columns}
    end
  end

  @doc "Get primary key column indices for a table."
  def primary_key_for(%__MODULE__{tables: tables}, table_name) do
    case Map.get(tables, table_name) do
      nil -> {:error, {:unknown_table, table_name}}
      table_def -> {:ok, table_def.primary_key}
    end
  end

  # --- Parsing internals ---

  defp parse_typespace(%{"types" => types}) do
    Enum.map(types, &parse_type_def/1)
  end

  defp parse_typespace(_), do: []

  defp parse_type_def(%{"Product" => %{"elements" => elements}}) do
    {:product, Enum.map(elements, &parse_element/1)}
  end

  defp parse_type_def(%{"Sum" => %{"variants" => variants}}) do
    {:sum, Enum.map(variants, &parse_element/1)}
  end

  defp parse_type_def(other), do: {:unknown, other}

  defp parse_element(%{"name" => name_wrap, "algebraic_type" => at}) do
    name = unwrap_option(name_wrap)
    %{name: name, type: parse_algebraic_type(at)}
  end

  defp parse_tables(tables, typespace) when is_list(tables) do
    Map.new(tables, fn t ->
      type_ref = t["product_type_ref"]
      columns = resolve_columns(type_ref, typespace)
      # Eagerly resolve all {:ref, N} in column types so downstream decoders
      # never encounter unresolved refs
      columns = Enum.map(columns, fn col -> %{col | type: resolve_refs(col.type, typespace)} end)
      primary_key = t["primary_key"] || []

      {t["name"],
       %{
         name: t["name"],
         columns: columns,
         primary_key: primary_key
       }}
    end)
  end

  defp parse_tables(_, _), do: %{}

  defp resolve_columns(type_ref, typespace) when is_integer(type_ref) do
    case Enum.at(typespace, type_ref) do
      {:product, columns} -> columns
      _ -> []
    end
  end

  defp resolve_columns(_, _), do: []

  defp parse_reducers(reducers) when is_list(reducers) do
    Map.new(reducers, fn r ->
      params =
        case r["params"] do
          %{"elements" => elements} -> Enum.map(elements, &parse_element/1)
          _ -> []
        end

      {r["name"], %{name: r["name"], params: params}}
    end)
  end

  defp parse_reducers(_), do: %{}

  defp parse_algebraic_type(%{"Bool" => _}), do: :bool
  defp parse_algebraic_type(%{"U8" => _}), do: :u8
  defp parse_algebraic_type(%{"I8" => _}), do: :i8
  defp parse_algebraic_type(%{"U16" => _}), do: :u16
  defp parse_algebraic_type(%{"I16" => _}), do: :i16
  defp parse_algebraic_type(%{"U32" => _}), do: :u32
  defp parse_algebraic_type(%{"I32" => _}), do: :i32
  defp parse_algebraic_type(%{"U64" => _}), do: :u64
  defp parse_algebraic_type(%{"I64" => _}), do: :i64
  defp parse_algebraic_type(%{"U128" => _}), do: :u128
  defp parse_algebraic_type(%{"I128" => _}), do: :i128
  defp parse_algebraic_type(%{"U256" => _}), do: :u256
  defp parse_algebraic_type(%{"I256" => _}), do: :i256
  defp parse_algebraic_type(%{"F32" => _}), do: :f32
  defp parse_algebraic_type(%{"F64" => _}), do: :f64
  defp parse_algebraic_type(%{"String" => _}), do: :string
  defp parse_algebraic_type(%{"Bytes" => _}), do: :bytes

  defp parse_algebraic_type(%{"Array" => inner}) do
    {:array, parse_algebraic_type(inner)}
  end

  defp parse_algebraic_type(%{"Map" => %{"key" => k, "value" => v}}) do
    {:map, parse_algebraic_type(k), parse_algebraic_type(v)}
  end

  defp parse_algebraic_type(%{"Ref" => ref}) when is_integer(ref) do
    {:ref, ref}
  end

  # Option is encoded as a Sum with two variants: some(T) and none
  defp parse_algebraic_type(%{"Sum" => %{"variants" => variants}}) when length(variants) == 2 do
    case variants do
      [%{"name" => %{"some" => "some"}, "algebraic_type" => inner}, %{"name" => %{"some" => "none"}}] ->
        {:option, parse_algebraic_type(inner)}

      _ ->
        {:sum, Enum.map(variants, &parse_element/1)}
    end
  end

  defp parse_algebraic_type(%{"Product" => %{"elements" => elements}}) do
    {:product, Enum.map(elements, &parse_element/1)}
  end

  defp parse_algebraic_type(other), do: {:unknown, other}

  # Recursively resolve {:ref, N} types by inlining from the typespace.
  defp resolve_refs({:ref, idx}, typespace) do
    case Enum.at(typespace, idx) do
      {:product, cols} ->
        {:product, Enum.map(cols, fn c -> %{c | type: resolve_refs(c.type, typespace)} end)}

      {:sum, variants} ->
        {:sum, Enum.map(variants, fn v -> %{v | type: resolve_refs(v.type, typespace)} end)}

      other ->
        other
    end
  end

  defp resolve_refs({:array, inner}, typespace), do: {:array, resolve_refs(inner, typespace)}
  defp resolve_refs({:option, inner}, typespace), do: {:option, resolve_refs(inner, typespace)}

  defp resolve_refs({:product, cols}, typespace) do
    {:product, Enum.map(cols, fn c -> %{c | type: resolve_refs(c.type, typespace)} end)}
  end

  defp resolve_refs(primitive, _typespace), do: primitive

  defp unwrap_option(%{"some" => val}), do: val
  defp unwrap_option(%{"none" => _}), do: nil
  defp unwrap_option(val), do: val
end
