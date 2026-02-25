defmodule Spacetimedbex.Http do
  @moduledoc """
  HTTP client for the SpacetimeDB REST API (v1).

  All functions take `host` (e.g. `"localhost:3000"`) as the first argument
  and return `{:ok, result} | {:error, reason}` tuples. Authentication is
  handled via explicit `token` parameters — no global state.

  Uses `Req` for HTTP, consistent with `Spacetimedbex.Schema.fetch/2`.
  """

  # ---------------------------------------------------------------------------
  # Identity
  # ---------------------------------------------------------------------------

  @doc "Create a new identity and token."
  def create_identity(host) do
    post(base_url(host) <> "/identity", nil)
  end

  @doc "List databases owned by `identity`."
  def get_databases(host, identity) do
    get(base_url(host) <> "/identity/#{identity}/databases")
  end

  @doc "Verify that `token` belongs to `identity`. Returns `:ok` on 204."
  def verify_identity(host, identity, token) do
    url = base_url(host) <> "/identity/#{identity}/verify"

    case Req.get(url, headers: auth_headers(token)) do
      {:ok, %{status: 204}} -> :ok
      {:ok, %{status: 400}} -> {:error, :identity_mismatch}
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Get a short-lived websocket token."
  def get_websocket_token(host, token) do
    post(base_url(host) <> "/identity/websocket-token", nil, token: token)
  end

  @doc "Get the public key for verifying tokens (PEM format)."
  def get_public_key(host) do
    url = base_url(host) <> "/identity/public-key"

    case Req.get(url) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Associate an email with an identity."
  def set_email(host, identity, email, token) do
    url = base_url(host) <> "/identity/#{identity}/set-email?email=#{URI.encode_www_form(email)}"

    case Req.post(url, headers: auth_headers(token)) do
      {:ok, %{status: status}} when status in 200..204 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Database management
  # ---------------------------------------------------------------------------

  @doc "Get database metadata."
  def get_database(host, name_or_identity) do
    get(base_url(host) <> "/database/#{name_or_identity}")
  end

  @doc """
  Publish a WASM module to a database.

  Options:
    * `:clear` - clear existing data on update (boolean)
  """
  def publish_database(host, name_or_identity, wasm_binary, token, opts \\ []) do
    query = if opts[:clear], do: "?clear=true", else: ""
    url = base_url(host) <> "/database/#{name_or_identity}#{query}"

    case Req.post(url,
           body: wasm_binary,
           headers: auth_headers(token) ++ [{"content-type", "application/wasm"}]
         ) do
      {:ok, %{status: status, body: body}} when status in 200..201 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Delete a database."
  def delete_database(host, name_or_identity, token) do
    url = base_url(host) <> "/database/#{name_or_identity}"

    case Req.delete(url, headers: auth_headers(token)) do
      {:ok, %{status: status}} when status in 200..204 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Get database identity hex string."
  def get_database_identity(host, name_or_identity) do
    get(base_url(host) <> "/database/#{name_or_identity}/identity")
  end

  @doc "List all names for a database."
  def get_database_names(host, name_or_identity) do
    get(base_url(host) <> "/database/#{name_or_identity}/names")
  end

  @doc "Add a name to a database."
  def add_database_name(host, name_or_identity, new_name, token) do
    url = base_url(host) <> "/database/#{name_or_identity}/names"

    case Req.post(url, body: new_name, headers: auth_headers(token)) do
      {:ok, %{status: status, body: body}} when status in 200..201 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Replace the full name list for a database."
  def set_database_names(host, name_or_identity, names, token) when is_list(names) do
    url = base_url(host) <> "/database/#{name_or_identity}/names"

    case Req.put(url, json: names, headers: auth_headers(token)) do
      {:ok, %{status: status}} when status in 200..204 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Operations
  # ---------------------------------------------------------------------------

  @doc "Call a reducer on a database."
  def call_reducer(host, database, reducer_name, args, token) when is_list(args) do
    url = base_url(host) <> "/database/#{database}/call/#{reducer_name}"

    case Req.post(url, json: args, headers: auth_headers(token)) do
      {:ok, %{status: status}} when status in 200..204 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Execute one or more SQL queries against a database.

  Returns `{:ok, results}` where results is a list of
  `%{schema: schema, rows: rows}` maps, one per statement.
  """
  def sql(host, database, query, token) do
    url = base_url(host) <> "/database/#{database}/sql"

    case Req.post(url, body: query, headers: auth_headers(token)) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, parse_sql_results(body)}

      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Fetch database schema. Delegates to `Spacetimedbex.Schema.fetch/2`."
  def schema(host, database) do
    Spacetimedbex.Schema.fetch(host, database)
  end

  @doc """
  Fetch database logs.

  Options:
    * `:num_lines` - number of log lines (integer)
    * `:follow` - stream logs (boolean, not yet supported — returns single response)
  """
  def logs(host, database, token, opts \\ []) do
    params =
      []
      |> maybe_add_param(:num_lines, opts[:num_lines])
      |> maybe_add_param(:follow, opts[:follow])

    query = if params == [], do: "", else: "?" <> URI.encode_query(params)
    url = base_url(host) <> "/database/#{database}/logs#{query}"

    case Req.get(url, headers: auth_headers(token)) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Ping
  # ---------------------------------------------------------------------------

  @doc "Ping the server. Returns `:ok` on success."
  def ping(host) do
    case Req.get(base_url(host) <> "/../ping") do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc false
  def base_url(host), do: "http://#{host}/v1"

  @doc false
  def auth_headers(token), do: [{"authorization", "Bearer #{token}"}]

  @doc false
  def parse_sql_results(results) when is_list(results) do
    Enum.map(results, fn
      %{"schema" => schema, "rows" => rows} -> %{schema: schema, rows: rows}
      other -> other
    end)
  end

  # Generic GET with JSON response
  defp get(url) do
    case Req.get(url) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Generic POST with optional auth and no body
  defp post(url, body, opts \\ []) do
    req_opts =
      if opts[:token] do
        [headers: auth_headers(opts[:token])]
      else
        []
      end

    req_opts = if body, do: Keyword.put(req_opts, :json, body), else: req_opts

    case Req.post(url, req_opts) do
      {:ok, %{status: status, body: resp_body}} when status in 200..201 -> {:ok, resp_body}
      {:ok, %{status: status, body: resp_body}} -> {:error, {:http_error, status, resp_body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, _key, false), do: params
  defp maybe_add_param(params, key, value), do: [{key, value} | params]
end
