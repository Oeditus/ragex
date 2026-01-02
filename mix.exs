defmodule Ragex.MixProject do
  use Mix.Project

  def project do
    [
      app: :ragex,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.github": :test
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Ragex.Application, []},
      start_phases: [auto_analyze: []]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:file_system, "~> 1.0"},
      # Embeddings and ML
      {:bumblebee, "~> 0.5"},
      {:nx, "~> 0.9"},
      {:exla, "~> 0.9"},
      # Doc / Test
      {:credo, "~> 1.5", only: :dev},
      {:dialyxir, "~> 1.1", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end
end
