defmodule Spacetimedbex.Http do
  @moduledoc """
  HTTP client for the SpacetimeDB REST API (v1).

  All functions take `host` (e.g. `"localhost:3000"`, or
  `"https://maincloud.spacetimedb.com"` for TLS) as the first argument and
  return `{:ok, result} | {:error, reason}` tuples. Authentication is handled
  via explicit `token` parameters — no global state. A `nil` token sends no
  `Authorization` header (the server treats the request as anonymous).

  Non-2xx responses return `{:error, {:http_error, status, body}}`.

  Uses `Req` for HTTP, consistent with `Spacetimedbex.Schema.fetch/2`.
  """

  alias Spacetimedbex.Url

  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------

  @doc "Create a new identity and token."
  def create_identity(host) do
    request(host, :post, "/identity")
  end

  @doc "List databases owned by `identity`."
  def get_databases(host, identity) do
    request(host, :get, "/identity/#{Url.segment(identity)}/databases")
  end

  @doc "Verify that `token` belongs to `identity`. Returns `:ok` on 204."
  def verify_identity(host, identity, token) do
    case request(host, :get, "/identity/#{Url.segment(identity)}/verify", token: token) do
      {:ok, _} -> :ok
      {:error, {:http_error, 400, _}} -> {:error, :identity_mismatch}
      {:error, {:http_error, 401, _}} -> {:error, :unauthorized}
      error -> error
    end
  end

  @doc "Get a short-lived (60s) websocket token."
  def get_websocket_token(host, token) do
    request(host, :post, "/identity/websocket-token", token: token)
  end

  @doc "Get the public key for verifying tokens (PEM format)."
  def get_public_key(host) do
    request(host, :get, "/identity/public-key")
  end

  # ---------------------------------------------------------------------------
  # Database management
  # ---------------------------------------------------------------------------

  @doc "Get database metadata."
  def get_database(host, name_or_identity) do
    request(host, :get, "/database/#{Url.segment(name_or_identity)}")
  end

  @doc """
  Publish a WASM module to a database.

  Options:
    * `:clear` - clear existing data on update (boolean)
  """
  def publish_database(host, name_or_identity, wasm_binary, token, opts \\ []) do
    params = if opts[:clear], do: [clear: true], else: []

    request(host, :put, "/database/#{Url.segment(name_or_identity)}",
      token: token,
      params: params,
      body: wasm_binary,
      headers: [{"content-type", "application/wasm"}]
    )
  end

  @doc "Delete a database."
  def delete_database(host, name_or_identity, token) do
    host
    |> request(:delete, "/database/#{Url.segment(name_or_identity)}", token: token)
    |> to_ok()
  end

  @doc "Get database identity hex string."
  def get_database_identity(host, name_or_identity) do
    request(host, :get, "/database/#{Url.segment(name_or_identity)}/identity")
  end

  @doc "List all names for a database."
  def get_database_names(host, name_or_identity) do
    request(host, :get, "/database/#{Url.segment(name_or_identity)}/names")
  end

  @doc "Add a name to a database."
  def add_database_name(host, name_or_identity, new_name, token) do
    request(host, :post, "/database/#{Url.segment(name_or_identity)}/names",
      token: token,
      body: new_name
    )
  end

  @doc "Replace the full name list for a database."
  def set_database_names(host, name_or_identity, names, token) when is_list(names) do
    host
    |> request(:put, "/database/#{Url.segment(name_or_identity)}/names",
      token: token,
      json: names
    )
    |> to_ok()
  end

  # ---------------------------------------------------------------------------
  # Operations
  # ---------------------------------------------------------------------------

  @doc """
  Call a reducer on a database. `args` is a JSON array of positional arguments.

  Returns `:ok` on success. A reducer that fails returns
  `{:error, {:http_error, 530, message}}`.
  """
  def call_reducer(host, database, reducer_name, args, token) when is_list(args) do
    host
    |> request(:post, call_path(database, reducer_name), token: token, json: args)
    |> to_ok()
  end

  @doc """
  Call a procedure on a database. `args` is a JSON array of positional arguments.

  Returns `{:ok, return_value}` with the procedure's JSON-decoded return value.
  """
  def call_procedure(host, database, procedure_name, args, token) when is_list(args) do
    request(host, :post, call_path(database, procedure_name), token: token, json: args)
  end

  @doc """
  Execute one or more SQL queries against a database.

  Returns `{:ok, results}` where results is a list of
  `%{schema: schema, rows: rows}` maps, one per statement (plus
  `:total_duration_micros` and `:stats` when the server reports them).
  """
  def sql(host, database, query, token) do
    case request(host, :post, "/database/#{Url.segment(database)}/sql", token: token, body: query) do
      {:ok, body} when is_list(body) -> {:ok, parse_sql_results(body)}
      other -> other
    end
  end

  @doc "Fetch database schema. Delegates to `Spacetimedbex.Schema.fetch/2`."
  def schema(host, database) do
    Spacetimedbex.Schema.fetch(host, database)
  end

  @doc """
  Fetch database logs (owner only).

  Options:
    * `:num_lines` - number of log lines (integer)
    * `:follow` - stream logs (boolean, not yet supported — returns single response)
  """
  def logs(host, database, token, opts \\ []) do
    params =
      Enum.reject(
        [num_lines: opts[:num_lines], follow: opts[:follow]],
        &(elem(&1, 1) in [nil, false])
      )

    request(host, :get, "/database/#{Url.segment(database)}/logs", token: token, params: params)
  end

  # ---------------------------------------------------------------------------
  # Ping
  # ---------------------------------------------------------------------------

  @doc "Ping the server. Returns `:ok` on success."
  def ping(host) do
    host |> request(:get, "/ping") |> to_ok()
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc false
  def base_url(host), do: Url.http_base(host)

  @doc false
  def auth_headers(nil), do: []
  def auth_headers(token), do: [{"authorization", "Bearer #{token}"}]

  @doc false
  def parse_sql_results(results) when is_list(results) do
    Enum.map(results, fn
      %{"schema" => schema, "rows" => rows} = result ->
        for {key, field} <- [total_duration_micros: "total_duration_micros", stats: "stats"],
            Map.has_key?(result, field),
            into: %{schema: schema, rows: rows},
            do: {key, result[field]}

      other ->
        other
    end)
  end

  defp call_path(database, name),
    do: "/database/#{Url.segment(database)}/call/#{Url.segment(name)}"

  defp request(host, method, path, opts \\ []) do
    {token, opts} = Keyword.pop(opts, :token)
    opts = Keyword.update(opts, :headers, auth_headers(token), &(auth_headers(token) ++ &1))

    case Req.request([method: method, url: base_url(host) <> path] ++ opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_ok({:ok, _body}), do: :ok
  defp to_ok(error), do: error
end
