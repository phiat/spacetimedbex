defmodule Spacetimedbex.Url do
  @moduledoc false

  # Builds base URLs from a `host` option. A bare host ("localhost:3000") uses
  # plain HTTP/WS for backward compatibility; a scheme prefix selects TLS, e.g.
  # "https://maincloud.spacetimedb.com" → https:// and wss://.

  @doc "Base URL for the REST API, e.g. `https://host/v1`."
  def http_base(host) do
    {tls?, authority} = split(host)
    "#{if tls?, do: "https", else: "http"}://#{authority}/v1"
  end

  @doc "Base URL for WebSocket endpoints, e.g. `wss://host/v1`."
  def ws_base(host) do
    {tls?, authority} = split(host)
    "#{if tls?, do: "wss", else: "ws"}://#{authority}/v1"
  end

  @doc "Percent-encode a single path segment (database name, reducer name, identity)."
  def segment(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  defp split(host) do
    {tls?, rest} =
      case host do
        "https://" <> rest -> {true, rest}
        "wss://" <> rest -> {true, rest}
        "http://" <> rest -> {false, rest}
        "ws://" <> rest -> {false, rest}
        rest -> {false, rest}
      end

    {tls?, String.trim_trailing(rest, "/")}
  end
end
