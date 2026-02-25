defmodule Spacetimedbex.MixProject do
  use Mix.Project

  def project do
    [
      app: :spacetimedbex,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "SpacetimeDB client library for Elixir",
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      docs: docs(),
      source_url: "https://github.com/phiat/spacetimedbex"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Spacetimedbex.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:websockex, "~> 0.4"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:phoenix_pubsub, "~> 2.1", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/phiat/spacetimedbex"}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      groups_for_modules: [
        "High-Level API": [
          Spacetimedbex.Client,
          Spacetimedbex.Http,
          Spacetimedbex.Phoenix
        ],
        "Cache & Schema": [
          Spacetimedbex.ClientCache,
          Spacetimedbex.ClientCache.RowDecoder,
          Spacetimedbex.Schema
        ],
        "WebSocket Protocol": [
          Spacetimedbex.Connection,
          Spacetimedbex.Protocol,
          Spacetimedbex.Protocol.ClientMessage,
          Spacetimedbex.Protocol.ServerMessage
        ],
        "BSATN Codec": [
          Spacetimedbex.BSATN,
          Spacetimedbex.BSATN.Encoder,
          Spacetimedbex.BSATN.Decoder,
          Spacetimedbex.BSATN.ValueEncoder
        ],
        Tooling: [
          Spacetimedbex.Codegen
        ]
      ]
    ]
  end
end
