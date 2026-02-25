defmodule Mix.Tasks.Spacetimedb.Gen do
  @moduledoc """
  Generates Elixir modules from a SpacetimeDB schema.

      mix spacetimedb.gen --host localhost:3000 --database mydb --module MyApp.SpacetimeDB

  ## Options

  - `--host` — SpacetimeDB host (required)
  - `--database` — database name (required)
  - `--module` — base module name for generated code (required)
  - `--output` — output directory (default: "lib")
  """

  use Mix.Task

  @shortdoc "Generate Elixir modules from SpacetimeDB schema"

  @switches [host: :string, database: :string, module: :string, output: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    host = opts[:host] || Mix.raise("--host is required")
    database = opts[:database] || Mix.raise("--database is required")
    base_module = opts[:module] || Mix.raise("--module is required")
    output_dir = opts[:output] || "lib"

    # Ensure HTTP client is started
    Mix.Task.run("app.start", ["--no-start"])
    Application.ensure_all_started(:req)

    Mix.shell().info("Fetching schema from #{host}/#{database}...")

    case Spacetimedbex.Schema.fetch(host, database) do
      {:ok, schema} ->
        files = Spacetimedbex.Codegen.generate(schema, base_module, database: database)

        Enum.each(files, fn {relative_path, content} ->
          full_path = Path.join(output_dir, relative_path)
          File.mkdir_p!(Path.dirname(full_path))
          File.write!(full_path, content)
          Mix.shell().info("  * creating #{full_path}")
        end)

        Mix.shell().info(
          "Generated #{length(files)} file(s) for #{map_size(schema.tables)} table(s) and #{map_size(schema.reducers)} reducer(s)."
        )

      {:error, reason} ->
        Mix.raise("Failed to fetch schema: #{inspect(reason)}")
    end
  end
end
