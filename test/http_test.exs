defmodule Spacetimedbex.HttpTest do
  use ExUnit.Case, async: true

  alias Spacetimedbex.Http

  # ---------------------------------------------------------------------------
  # Unit tests — no live server required
  # ---------------------------------------------------------------------------

  describe "base_url/1" do
    test "builds v1 URL from host" do
      assert Http.base_url("localhost:3000") == "http://localhost:3000/v1"
    end

    test "works with hostname only" do
      assert Http.base_url("spacetime.example.com") == "http://spacetime.example.com/v1"
    end
  end

  describe "auth_headers/1" do
    test "returns Bearer authorization header" do
      assert Http.auth_headers("my-token") == [{"authorization", "Bearer my-token"}]
    end
  end

  describe "parse_sql_results/1" do
    test "parses results with schema and rows keys" do
      raw = [
        %{
          "schema" => %{"elements" => [%{"name" => "id", "type" => "U64"}]},
          "rows" => [[1], [2], [3]]
        }
      ]

      assert [%{schema: schema, rows: rows}] = Http.parse_sql_results(raw)
      assert schema == %{"elements" => [%{"name" => "id", "type" => "U64"}]}
      assert rows == [[1], [2], [3]]
    end

    test "handles multiple result sets" do
      raw = [
        %{"schema" => %{"elements" => []}, "rows" => []},
        %{"schema" => %{"elements" => [%{"name" => "x"}]}, "rows" => [[42]]}
      ]

      assert [%{schema: _, rows: []}, %{schema: _, rows: [[42]]}] = Http.parse_sql_results(raw)
    end

    test "passes through unknown shapes" do
      raw = [%{"error" => "something went wrong"}]
      assert [%{"error" => "something went wrong"}] = Http.parse_sql_results(raw)
    end

    test "handles empty list" do
      assert [] = Http.parse_sql_results([])
    end
  end

  # ---------------------------------------------------------------------------
  # Integration tests — require a live SpacetimeDB at localhost:3000
  # Tag with :integration so they're excluded by default
  # ---------------------------------------------------------------------------

  @host "localhost:3000"

  @tag :integration
  test "ping succeeds against live server" do
    assert :ok = Http.ping(@host)
  end

  @tag :integration
  test "create_identity returns identity and token" do
    assert {:ok, %{"identity" => identity, "token" => token}} = Http.create_identity(@host)
    assert is_binary(identity)
    assert is_binary(token)
  end

  @tag :integration
  test "create_identity and verify round-trip" do
    {:ok, %{"identity" => identity, "token" => token}} = Http.create_identity(@host)
    assert :ok = Http.verify_identity(@host, identity, token)
  end

  @tag :integration
  test "verify_identity rejects wrong token" do
    {:ok, %{"identity" => identity}} = Http.create_identity(@host)
    assert {:error, _} = Http.verify_identity(@host, identity, "bogus-token")
  end

  @tag :integration
  test "get_databases for new identity returns empty or list" do
    {:ok, %{"identity" => identity}} = Http.create_identity(@host)
    assert {:ok, _} = Http.get_databases(@host, identity)
  end

  @tag :integration
  test "get_public_key returns PEM data" do
    assert {:ok, pem} = Http.get_public_key(@host)
    assert is_binary(pem)
  end

  @tag :integration
  test "get_websocket_token returns a token" do
    {:ok, %{"token" => token}} = Http.create_identity(@host)
    assert {:ok, %{"token" => ws_token}} = Http.get_websocket_token(@host, token)
    assert is_binary(ws_token)
  end

  @tag :integration
  test "get_database returns error for nonexistent database" do
    assert {:error, {:http_error, _, _}} = Http.get_database(@host, "nonexistent_db_12345")
  end

  @tag :integration
  test "sql against nonexistent database returns error" do
    {:ok, %{"token" => token}} = Http.create_identity(@host)
    assert {:error, _} = Http.sql(@host, "nonexistent_db_12345", "SELECT 1", token)
  end
end
