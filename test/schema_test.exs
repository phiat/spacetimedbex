defmodule Spacetimedbex.SchemaTest do
  use ExUnit.Case, async: true

  alias Spacetimedbex.Schema

  @raw_schema %{
    "typespace" => %{
      "types" => [
        %{
          "Product" => %{
            "elements" => [
              %{"name" => %{"some" => "id"}, "algebraic_type" => %{"U64" => []}},
              %{"name" => %{"some" => "name"}, "algebraic_type" => %{"String" => []}},
              %{"name" => %{"some" => "age"}, "algebraic_type" => %{"U32" => []}}
            ]
          }
        }
      ]
    },
    "tables" => [
      %{
        "name" => "person",
        "product_type_ref" => 0,
        "primary_key" => [0],
        "indexes" => [],
        "constraints" => [],
        "sequences" => [],
        "schedule" => %{"none" => []},
        "table_type" => %{"User" => []},
        "table_access" => %{"Public" => []}
      }
    ],
    "reducers" => [
      %{
        "name" => "add_person",
        "params" => %{
          "elements" => [
            %{"name" => %{"some" => "name"}, "algebraic_type" => %{"String" => []}},
            %{"name" => %{"some" => "age"}, "algebraic_type" => %{"U32" => []}}
          ]
        },
        "lifecycle" => %{"none" => []}
      },
      %{
        "name" => "say_hello",
        "params" => %{"elements" => []},
        "lifecycle" => %{"none" => []}
      }
    ],
    "types" => [],
    "misc_exports" => []
  }

  describe "parse/1" do
    test "parses tables with columns and primary key" do
      schema = Schema.parse(@raw_schema)

      assert Map.has_key?(schema.tables, "person")
      person = schema.tables["person"]
      assert person.name == "person"
      assert person.primary_key == [0]
      assert length(person.columns) == 3

      [id_col, name_col, age_col] = person.columns
      assert id_col == %{name: "id", type: :u64}
      assert name_col == %{name: "name", type: :string}
      assert age_col == %{name: "age", type: :u32}
    end

    test "parses reducers with params" do
      schema = Schema.parse(@raw_schema)

      assert Map.has_key?(schema.reducers, "add_person")
      add_person = schema.reducers["add_person"]
      assert length(add_person.params) == 2
      assert Enum.at(add_person.params, 0) == %{name: "name", type: :string}
      assert Enum.at(add_person.params, 1) == %{name: "age", type: :u32}

      say_hello = schema.reducers["say_hello"]
      assert say_hello.params == []
    end

    test "columns_for returns columns" do
      schema = Schema.parse(@raw_schema)
      assert {:ok, columns} = Schema.columns_for(schema, "person")
      assert length(columns) == 3
    end

    test "columns_for unknown table returns error" do
      schema = Schema.parse(@raw_schema)
      assert {:error, {:unknown_table, "nope"}} = Schema.columns_for(schema, "nope")
    end

    test "primary_key_for returns indices" do
      schema = Schema.parse(@raw_schema)
      assert {:ok, [0]} = Schema.primary_key_for(schema, "person")
    end
  end

  describe "ref type resolution" do
    test "Ref type in a column is resolved to the referenced product type" do
      raw = %{
        "typespace" => %{
          "types" => [
            %{
              "Product" => %{
                "elements" => [
                  %{"name" => %{"some" => "x"}, "algebraic_type" => %{"U32" => %{}}},
                  %{"name" => %{"some" => "y"}, "algebraic_type" => %{"U32" => %{}}}
                ]
              }
            },
            %{
              "Product" => %{
                "elements" => [
                  %{"name" => %{"some" => "id"}, "algebraic_type" => %{"U64" => %{}}},
                  %{"name" => %{"some" => "coords"}, "algebraic_type" => %{"Ref" => 0}}
                ]
              }
            }
          ]
        },
        "tables" => [
          %{
            "name" => "points",
            "product_type_ref" => 0,
            "primary_key" => [0]
          },
          %{
            "name" => "objects",
            "product_type_ref" => 1,
            "primary_key" => [0]
          }
        ],
        "reducers" => []
      }

      schema = Schema.parse(raw)

      # The "points" table columns should be plain u32 types
      {:ok, point_cols} = Schema.columns_for(schema, "points")
      assert point_cols == [%{name: "x", type: :u32}, %{name: "y", type: :u32}]

      # The "objects" table has a Ref=>0 column that should be resolved
      {:ok, obj_cols} = Schema.columns_for(schema, "objects")
      [id_col, coords_col] = obj_cols
      assert id_col == %{name: "id", type: :u64}

      # The ref should be resolved to the product type, not left as {:ref, 0}
      assert coords_col.name == "coords"
      assert coords_col.type == {:product, [%{name: "x", type: :u32}, %{name: "y", type: :u32}]}
    end
  end

  describe "algebraic type parsing" do
    test "parses all primitive types" do
      for {json_key, expected} <- [
            {"Bool", :bool},
            {"U8", :u8},
            {"I8", :i8},
            {"U16", :u16},
            {"I16", :i16},
            {"U32", :u32},
            {"I32", :i32},
            {"U64", :u64},
            {"I64", :i64},
            {"U128", :u128},
            {"I128", :i128},
            {"U256", :u256},
            {"I256", :i256},
            {"F32", :f32},
            {"F64", :f64},
            {"String", :string},
            {"Bytes", :bytes}
          ] do
        raw = %{
          "typespace" => %{
            "types" => [
              %{
                "Product" => %{
                  "elements" => [
                    %{"name" => %{"some" => "x"}, "algebraic_type" => %{json_key => []}}
                  ]
                }
              }
            ]
          },
          "tables" => [%{"name" => "t", "product_type_ref" => 0, "primary_key" => [0]}],
          "reducers" => []
        }

        schema = Schema.parse(raw)
        {:ok, [col]} = Schema.columns_for(schema, "t")
        assert col.type == expected, "Failed for #{json_key}: got #{inspect(col.type)}"
      end
    end
  end

  describe "sum types and reducer refs" do
    @enum_schema %{
      "typespace" => %{
        "types" => [
          %{
            "Product" => %{
              "elements" => [
                %{"name" => %{"some" => "id"}, "algebraic_type" => %{"U32" => []}},
                %{
                  "name" => %{"some" => "shape"},
                  "algebraic_type" => %{
                    "Sum" => %{
                      "variants" => [
                        %{
                          "name" => %{"some" => "A"},
                          "algebraic_type" => %{"Product" => %{"elements" => []}}
                        },
                        %{
                          "name" => %{"some" => "B"},
                          "algebraic_type" => %{"Product" => %{"elements" => []}}
                        },
                        %{
                          "name" => %{"some" => "C"},
                          "algebraic_type" => %{"Product" => %{"elements" => []}}
                        }
                      ]
                    }
                  }
                }
              ]
            }
          },
          %{
            "Product" => %{
              "elements" => [%{"name" => %{"some" => "x"}, "algebraic_type" => %{"I32" => []}}]
            }
          }
        ]
      },
      "tables" => [%{"name" => "log", "product_type_ref" => 0, "primary_key" => []}],
      "reducers" => [
        %{
          "name" => "move",
          "params" => %{
            "elements" => [%{"name" => %{"some" => "to"}, "algebraic_type" => %{"Ref" => 1}}]
          }
        }
      ]
    }

    test "inline sums with more than two variants parse as :sum" do
      schema = Schema.parse(@enum_schema)
      {:ok, [_id, shape]} = Schema.columns_for(schema, "log")
      assert {:sum, [%{name: "A"}, %{name: "B"}, %{name: "C"}]} = shape.type
    end

    test "reducer params resolve typespace refs" do
      schema = Schema.parse(@enum_schema)

      assert [%{name: "to", type: {:product, [%{name: "x", type: :i32}]}}] =
               schema.reducers["move"].params
    end

    test "primary_key_names is empty for tables without a primary key" do
      assert {:ok, []} = Schema.primary_key_names(Schema.parse(@enum_schema), "log")
    end
  end
end
