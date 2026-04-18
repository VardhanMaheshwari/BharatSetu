defmodule BharatAdapters.MixProject do
  use Mix.Project

  def project do
    [
      app: :bharat_adapters,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:ethereumex, "~> 0.10"},
      {:ex_abi, "~> 0.6"},
      {:ex_rlp, "~> 0.6"},
      {:ex_secp256k1, "~> 0.7"},
      {:ex_keccak, "~> 0.7"}
    ]
  end
end
