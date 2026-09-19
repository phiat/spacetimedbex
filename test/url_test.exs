defmodule Spacetimedbex.UrlTest do
  use ExUnit.Case, async: true

  alias Spacetimedbex.Url

  test "bare host uses plain http/ws" do
    assert Url.http_base("localhost:3000") == "http://localhost:3000/v1"
    assert Url.ws_base("localhost:3000") == "ws://localhost:3000/v1"
  end

  test "https host uses TLS for both" do
    assert Url.http_base("https://maincloud.spacetimedb.com") ==
             "https://maincloud.spacetimedb.com/v1"

    assert Url.ws_base("https://maincloud.spacetimedb.com/") ==
             "wss://maincloud.spacetimedb.com/v1"
  end

  test "explicit http/ws schemes stay plain" do
    assert Url.ws_base("http://example.com") == "ws://example.com/v1"
    assert Url.http_base("ws://example.com") == "http://example.com/v1"
  end

  test "segment percent-encodes path segments" do
    assert Url.segment("my-db") == "my-db"
    assert Url.segment("a/b c") == "a%2Fb%20c"
  end
end
