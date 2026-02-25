defmodule Spacetimedbex.CodegenTest do
  use ExUnit.Case, async: true

  alias Spacetimedbex.Codegen
  alias Spacetimedbex.TestSchema

  @base_module "MyApp.SpacetimeDB"

  describe "generate/2" do
    test "returns list of {path, source} tuples" do
      files = Codegen.generate(TestSchema.person_schema(), @base_module)
      assert is_list(files)
      assert length(files) == 3

      paths = Enum.map(files, &elem(&1, 0))
      assert "my_app/spacetime_db/tables/person.ex" in paths
      assert "my_app/spacetime_db/reducers.ex" in paths
      assert "my_app/spacetime_db/client.ex" in paths
    end

    test "all generated sources are valid Elixir" do
      files = Codegen.generate(TestSchema.person_schema(), @base_module)

      for {path, source} <- files do
        assert {:ok, _} = Code.string_to_quoted(source),
               "Invalid Elixir in #{path}"
      end
    end
  end

  describe "table struct generation" do
    setup do
      files = Codegen.generate(TestSchema.person_schema(), @base_module)
      {_, source} = Enum.find(files, fn {path, _} -> path =~ "person.ex" end)
      {:ok, source: source}
    end

    test "generates defstruct with correct fields", %{source: source} do
      assert source =~ "defstruct"
      assert source =~ ":id"
      assert source =~ ":name"
      assert source =~ ":age"
    end

    test "generates @type t", %{source: source} do
      assert source =~ "@type t :: %__MODULE__{"
      assert source =~ "non_neg_integer()"
      assert source =~ "String.t()"
    end

    test "generates from_row/1 converter", %{source: source} do
      assert source =~ "def from_row(row)"
      assert source =~ ~s|Map.get(row, "id")|
      assert source =~ ~s|Map.get(row, "name")|
      assert source =~ ~s|Map.get(row, "age")|
    end
  end

  describe "reducer functions" do
    setup do
      files = Codegen.generate(TestSchema.person_schema(), @base_module)
      {_, source} = Enum.find(files, fn {path, _} -> path =~ "reducers.ex" end)
      {:ok, source: source}
    end

    test "generates function for each reducer", %{source: source} do
      assert source =~ "def add_person(client, name, age)"
    end

    test "generates @spec with typed params", %{source: source} do
      assert source =~ "@spec add_person"
      assert source =~ "String.t()"
      assert source =~ "non_neg_integer()"
    end

    test "calls Client.call_reducer with correct args", %{source: source} do
      assert source =~ ~s|Spacetimedbex.Client.call_reducer(client, "add_person"|
    end
  end

  describe "client module" do
    setup do
      files = Codegen.generate(TestSchema.person_schema(), @base_module)
      {_, source} = Enum.find(files, fn {path, _} -> path =~ "client.ex" end)
      {:ok, source: source}
    end

    test "uses Spacetimedbex.Client", %{source: source} do
      assert source =~ "use Spacetimedbex.Client"
    end

    test "generates config/0 with subscriptions", %{source: source} do
      assert source =~ "def config do"
      assert source =~ ~s|"SELECT * FROM person"|
    end

    test "includes commented callback stubs", %{source: source} do
      assert source =~ "# def on_connect"
      assert source =~ "# def on_insert"
    end
  end

  describe "type mapping" do
    test "primitive types" do
      assert Codegen.type_to_typespec(:bool) == "boolean()"
      assert Codegen.type_to_typespec(:u32) == "non_neg_integer()"
      assert Codegen.type_to_typespec(:i64) == "integer()"
      assert Codegen.type_to_typespec(:f64) == "float()"
      assert Codegen.type_to_typespec(:string) == "String.t()"
      assert Codegen.type_to_typespec(:bytes) == "binary()"
    end

    test "compound types" do
      assert Codegen.type_to_typespec({:array, :u32}) == "[non_neg_integer()]"
      assert Codegen.type_to_typespec({:option, :string}) == "String.t() | nil"
      assert Codegen.type_to_typespec({:product, []}) == "map()"
    end

    test "unknown types fall back to term()" do
      assert Codegen.type_to_typespec({:unknown, nil}) == "term()"
    end
  end

  describe "to_pascal_case" do
    test "converts snake_case to PascalCase" do
      assert Codegen.to_pascal_case("person") == "Person"
      assert Codegen.to_pascal_case("user_profile") == "UserProfile"
      assert Codegen.to_pascal_case("my_table_name") == "MyTableName"
    end
  end

  describe "multi-table schema" do
    test "generates a file per table" do
      schema = %Spacetimedbex.Schema{
        tables: %{
          "person" => %{
            name: "person",
            columns: [%{name: "id", type: :u64}],
            primary_key: [0]
          },
          "message" => %{
            name: "message",
            columns: [
              %{name: "id", type: :u64},
              %{name: "text", type: :string},
              %{name: "sender_id", type: :u64}
            ],
            primary_key: [0]
          }
        },
        reducers: %{},
        typespace: []
      }

      files = Codegen.generate(schema, "Chat")
      paths = Enum.map(files, &elem(&1, 0))

      # 2 tables + 1 client (no reducers module since empty)
      assert length(files) == 3
      assert Enum.any?(paths, &(&1 =~ "person.ex"))
      assert Enum.any?(paths, &(&1 =~ "message.ex"))
      assert Enum.any?(paths, &(&1 =~ "client.ex"))
    end
  end

  describe "schema with no reducers" do
    test "omits reducers module" do
      schema = %Spacetimedbex.Schema{
        tables: %{
          "item" => %{
            name: "item",
            columns: [%{name: "id", type: :u64}],
            primary_key: [0]
          }
        },
        reducers: %{},
        typespace: []
      }

      files = Codegen.generate(schema, "Game")
      paths = Enum.map(files, &elem(&1, 0))
      refute Enum.any?(paths, &(&1 =~ "reducers.ex"))
    end
  end
end
