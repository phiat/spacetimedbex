defmodule Spacetimedbex.TestSchema do
  @moduledoc """
  Shared test schema fixture matching the testmodule:
  - person table (id: u64, name: string, age: u32), primary key: [0]
  - add_person reducer (name: string, age: u32)
  """

  alias Spacetimedbex.Schema

  def person_schema do
    %Schema{
      tables: %{
        "person" => %{
          name: "person",
          columns: [
            %{name: "id", type: :u64},
            %{name: "name", type: :string},
            %{name: "age", type: :u32}
          ],
          primary_key: [0]
        }
      },
      reducers: %{
        "add_person" => %{
          name: "add_person",
          params: [
            %{name: "name", type: :string},
            %{name: "age", type: :u32}
          ]
        }
      },
      typespace: []
    }
  end

  @doc "Build a BSATN-encoded person row binary (id:u64, name:string, age:u32)."
  def encode_person(id, name, age) do
    name_bytes = name |> :binary.bin_to_list() |> length()

    <<id::little-unsigned-64>> <>
      <<name_bytes::little-unsigned-32>> <>
      name <>
      <<age::little-unsigned-32>>
  end

  @doc "Build a BsatnRowList for a single person row."
  def person_row_list(id, name, age) do
    data = encode_person(id, name, age)
    %{size_hint: {:fixed_size, byte_size(data)}, rows_data: data}
  end

  @doc "Build a BsatnRowList for multiple person rows."
  def person_row_list_multi(persons) do
    rows = Enum.map(persons, fn {id, name, age} -> encode_person(id, name, age) end)

    case rows do
      [] ->
        %{size_hint: {:fixed_size, 0}, rows_data: <<>>}

      [first | _] ->
        size = byte_size(first)
        %{size_hint: {:fixed_size, size}, rows_data: IO.iodata_to_binary(rows)}
    end
  end
end
