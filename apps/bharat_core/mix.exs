defmodule BharatCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :bharat_core,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {BharatCore.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix_pubsub, "~> 2.1"},
      {:cachex, "~> 3.6"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:ethereumex, "~> 0.10"},
      {:ex_abi, "~> 0.6"},
      {:redix, "~> 1.3"},
      {:ex_secp256k1, "~> 0.7"},
      {:ex_keccak, "~> 0.7"},
      {:bharat_adapters, in_umbrella: true},
      {:bharat_data, in_umbrella: true}
    ]
  end
end
