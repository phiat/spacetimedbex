defmodule Spacetimedbex.Codegen do
  @moduledoc """
  Generates Elixir source code from a SpacetimeDB schema.

  Pure function: takes a `%Schema{}` and a base module name, returns a list of
  `{relative_path, source_string}` tuples ready to be written to disk.

  ## Generated modules

  - `BaseModule.Tables.TableName` — defstruct + `@type t` + `from_row/1` for each table
  - `BaseModule.Reducers` — typed functions that call `Client.call_reducer`
  - `BaseModule.Client` — `use Spacetimedbex.Client` skeleton with config and stub callbacks
  """

  alias Spacetimedbex.Schema

  @doc """
  Generate source files from a schema.

  Returns `[{relative_path, formatted_source}]`.
  """
  @spec generate(Schema.t(), String.t()) :: [{String.t(), String.t()}]
  def generate(%Schema{} = schema, base_module) do
    table_files =
      Enum.map(schema.tables, fn {table_name, table_def} ->
        module_name = "#{base_module}.Tables.#{to_pascal_case(table_name)}"
        path = module_to_path(module_name)
        source = generate_table_module(module_name, table_name, table_def)
        {path, source}
      end)

    reducer_file =
      if map_size(schema.reducers) > 0 do
        module_name = "#{base_module}.Reducers"
        path = module_to_path(module_name)
        source = generate_reducers_module(module_name, schema.reducers)
        [{path, source}]
      else
        []
      end

    client_file = [
      {module_to_path(base_module <> ".Client"),
       generate_client_module(base_module <> ".Client", schema)}
    ]

    table_files ++ reducer_file ++ client_file
  end

  # --- Table module ---

  defp generate_table_module(module_name, table_name, table_def) do
    fields = Enum.map(table_def.columns, & &1.name)
    types = Enum.map(table_def.columns, &type_to_typespec(&1.type))

    field_list = Enum.map_join(fields, ", ", &":#{&1}")

    type_fields =
      fields
      |> Enum.zip(types)
      |> Enum.map_join(",\n", fn {name, type} -> "          #{name}: #{type}" end)

    from_row_fields =
      Enum.map_join(fields, ",\n", fn name ->
        ~s|          #{name}: Map.get(row, "#{name}")|
      end)

    source = """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      Generated struct for the `#{table_name}` table.
      \"\"\"

      defstruct [#{field_list}]

      @type t :: %__MODULE__{
    #{type_fields}
          }

      @doc "Convert a row map (string keys) to a struct."
      def from_row(row) when is_map(row) do
        %__MODULE__{
    #{from_row_fields}
        }
      end
    end
    """

    format_source(source)
  end

  # --- Reducers module ---

  defp generate_reducers_module(module_name, reducers) do
    functions =
      Enum.map_join(reducers, "\n", fn {reducer_name, reducer_def} ->
        generate_reducer_function(reducer_name, reducer_def)
      end)

    source = """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      Generated reducer functions.
      \"\"\"

    #{functions}
    end
    """

    format_source(source)
  end

  defp generate_reducer_function(reducer_name, reducer_def) do
    func_name = to_snake_case(reducer_name)

    if reducer_def.params == [] do
      """
        @doc "Call the `#{reducer_name}` reducer."
        def #{func_name}(client) do
          Spacetimedbex.Client.call_reducer(client, "#{reducer_name}", %{})
        end
      """
    else
      param_names = Enum.map(reducer_def.params, & &1.name)
      param_list = Enum.join(param_names, ", ")

      args_map =
        Enum.map_join(param_names, ", ", fn name ->
          ~s|"#{name}" => #{to_snake_case(name)}|
        end)

      type_specs =
        Enum.map_join(reducer_def.params, ", ", fn p ->
          "#{to_snake_case(p.name)} :: #{type_to_typespec(p.type)}"
        end)

      """
        @doc "Call the `#{reducer_name}` reducer."
        @spec #{func_name}(GenServer.server(), #{type_specs}) :: :ok | {:error, term()}
        def #{func_name}(client, #{param_list}) do
          Spacetimedbex.Client.call_reducer(client, "#{reducer_name}", %{#{args_map}})
        end
      """
    end
  end

  # --- Client module ---

  defp generate_client_module(module_name, schema) do
    table_names = schema.tables |> Map.keys() |> Enum.sort()

    subscribe_list =
      Enum.map_join(table_names, ", ", fn name -> ~s|"SELECT * FROM #{name}"| end)

    source = """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      Generated SpacetimeDB client.

      Customize the callbacks below to handle events from your SpacetimeDB module.
      \"\"\"

      use Spacetimedbex.Client

      def config do
        %{
          host: System.get_env("SPACETIMEDB_HOST", "localhost:3000"),
          database: System.get_env("SPACETIMEDB_DATABASE", "my_database"),
          subscriptions: [#{subscribe_list}]
        }
      end

      # --- Callbacks (uncomment and customize as needed) ---

      # def on_connect(identity, connection_id, token, state) do
      #   {:ok, state}
      # end

      # def on_subscribe_applied(table_name, rows, state) do
      #   {:ok, state}
      # end

      # def on_insert(table_name, row, state) do
      #   {:ok, state}
      # end

      # def on_delete(table_name, row, state) do
      #   {:ok, state}
      # end

      # def on_transaction(changes, state) do
      #   {:ok, state}
      # end

      # def on_reducer_result(request_id, result, state) do
      #   {:ok, state}
      # end

      # def on_disconnect(reason, state) do
      #   {:ok, state}
      # end
    end
    """

    format_source(source)
  end

  # --- Type mapping ---

  @doc false
  def type_to_typespec(:bool), do: "boolean()"
  def type_to_typespec(:u8), do: "non_neg_integer()"
  def type_to_typespec(:i8), do: "integer()"
  def type_to_typespec(:u16), do: "non_neg_integer()"
  def type_to_typespec(:i16), do: "integer()"
  def type_to_typespec(:u32), do: "non_neg_integer()"
  def type_to_typespec(:i32), do: "integer()"
  def type_to_typespec(:u64), do: "non_neg_integer()"
  def type_to_typespec(:i64), do: "integer()"
  def type_to_typespec(:u128), do: "integer()"
  def type_to_typespec(:i128), do: "integer()"
  def type_to_typespec(:u256), do: "integer()"
  def type_to_typespec(:i256), do: "integer()"
  def type_to_typespec(:f32), do: "float()"
  def type_to_typespec(:f64), do: "float()"
  def type_to_typespec(:string), do: "String.t()"
  def type_to_typespec(:bytes), do: "binary()"
  def type_to_typespec({:array, inner}), do: "[#{type_to_typespec(inner)}]"
  def type_to_typespec({:option, inner}), do: "#{type_to_typespec(inner)} | nil"
  def type_to_typespec({:product, _}), do: "map()"
  def type_to_typespec({:sum, _}), do: "term()"
  def type_to_typespec(_), do: "term()"

  # --- Naming helpers ---

  @doc false
  def to_pascal_case(name) do
    name
    |> String.split(~r/[_\s-]+/)
    |> Enum.map_join(&String.capitalize/1)
  end

  defp to_snake_case(name) do
    name
    |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
    |> String.replace(~r/([a-z\d])([A-Z])/, "\\1_\\2")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "_")
  end

  defp module_to_path(module_name) do
    module_name
    |> String.replace(~r/^Elixir\./, "")
    |> String.split(".")
    |> Enum.map_join("/", &to_snake_case/1)
    |> Kernel.<>(".ex")
  end

  defp format_source(source) do
    Code.format_string!(source) |> IO.iodata_to_binary()
  end
end
