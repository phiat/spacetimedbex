defmodule Spacetimedbex.ClientCache.Store do
  @moduledoc false

  # ETS-backed row storage shared by `Spacetimedbex.ClientCache` and
  # `Spacetimedbex.Client`. The tables are owned by (and only writable from)
  # the process that calls `new/1`.
  #
  # Rows are ref-counted like the official SDKs: a row matched by several
  # queries or query sets is stored once, and an insert/delete only takes
  # effect on a 0 <-> 1 transition. `apply_changes/2` returns those effective
  # changes so callbacks fire exactly once per row.
  #
  # Per table: `rows` holds `{row, ref_count}`; `pk` (primary-key tables only)
  # indexes `{pk_value, row}` for `find/3`.

  require Logger

  alias Spacetimedbex.Schema

  defstruct tables: %{}

  @type table :: %{rows: :ets.table(), pk: :ets.table() | nil, pk_names: [String.t()]}
  @type t :: %__MODULE__{tables: %{String.t() => table()}}

  @doc false
  def new(%Schema{} = schema) do
    tables =
      Map.new(schema.tables, fn {name, _def} ->
        {:ok, pk_names} = Schema.primary_key_names(schema, name)
        rows = :ets.new(:spacetimedbex_rows, [:set, :protected])
        pk = if pk_names != [], do: :ets.new(:spacetimedbex_pk, [:set, :protected])
        {name, %{rows: rows, pk: pk, pk_names: pk_names}}
      end)

    %__MODULE__{tables: tables}
  end

  @doc false
  # `changes` is a list of `%{table_name, inserts, deletes}` (optionally
  # `events`). Entries for the same table are merged, deletes are applied
  # before inserts, and only tables with effective changes or events are
  # returned. Event rows pass through untouched and are never stored.
  def apply_changes(%__MODULE__{} = store, changes) do
    changes
    |> merge_by_table()
    |> Enum.flat_map(&apply_table_change(store, &1))
  end

  @doc false
  def get_all(store, table_name) do
    case Map.get(store.tables, table_name) do
      nil -> []
      %{rows: rows} -> :ets.select(rows, [{{:"$1", :_}, [], [:"$1"]}])
    end
  end

  @doc false
  # Primary-key tables look up by key (a tuple for composite keys); tables
  # without a primary key are keyed by the full row.
  def find(store, table_name, key) do
    case Map.get(store.tables, table_name) do
      nil -> nil
      %{pk: nil, rows: rows} -> if :ets.member(rows, key), do: key
      %{pk: pk} -> lookup_row(pk, key)
    end
  end

  @doc false
  def count(store, table_name) do
    case Map.get(store.tables, table_name) do
      nil -> 0
      %{rows: rows} -> :ets.info(rows, :size)
    end
  end

  @doc false
  def clear(store) do
    Enum.each(store.tables, fn {_name, table} ->
      :ets.delete_all_objects(table.rows)
      if table.pk, do: :ets.delete_all_objects(table.pk)
    end)
  end

  @doc false
  def pk_names(store, table_name) do
    case Map.get(store.tables, table_name) do
      nil -> []
      %{pk_names: names} -> names
    end
  end

  @doc false
  def row_key(row, []), do: row
  def row_key(row, [single_pk]), do: Map.get(row, single_pk)
  def row_key(row, pk_names), do: List.to_tuple(Enum.map(pk_names, &Map.get(row, &1)))

  # --- Internal ---

  defp apply_table_change(store, %{table_name: name} = change) do
    case Map.get(store.tables, name) do
      nil ->
        Logger.warning("Spacetimedbex: no table #{name} in schema; ignoring rows")
        []

      table ->
        deletes = Enum.filter(change.deletes, &remove_row(table, &1))
        inserts = Enum.filter(change.inserts, &add_row(table, &1))

        if deletes == [] and inserts == [] and change.events == [],
          do: [],
          else: [%{change | deletes: deletes, inserts: inserts}]
    end
  end

  defp add_row(%{rows: rows} = table, row) do
    case :ets.update_counter(rows, row, {2, 1}, {row, 0}) do
      1 ->
        if table.pk, do: :ets.insert(table.pk, {row_key(row, table.pk_names), row})
        true

      _ ->
        false
    end
  end

  defp remove_row(%{rows: rows} = table, row) do
    case :ets.lookup(rows, row) do
      [{_, 1}] ->
        :ets.delete(rows, row)
        if table.pk, do: :ets.delete_object(table.pk, {row_key(row, table.pk_names), row})
        true

      [{_, _}] ->
        :ets.update_counter(rows, row, {2, -1})
        false

      [] ->
        false
    end
  end

  defp lookup_row(tid, key) do
    case :ets.lookup(tid, key) do
      [{_key, row}] -> row
      [] -> nil
    end
  end

  defp merge_by_table(changes) do
    {order, by_table} =
      Enum.reduce(changes, {[], %{}}, fn %{table_name: name} = change, {order, acc} ->
        change = Map.put_new(change, :events, [])

        case acc do
          %{^name => prev} ->
            merged = %{
              prev
              | inserts: prev.inserts ++ change.inserts,
                deletes: prev.deletes ++ change.deletes,
                events: prev.events ++ change.events
            }

            {order, Map.put(acc, name, merged)}

          _ ->
            {[name | order], Map.put(acc, name, change)}
        end
      end)

    order |> Enum.reverse() |> Enum.map(&Map.fetch!(by_table, &1))
  end
end
