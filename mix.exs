defmodule Ragex.MixProject do
  use Mix.Project

  def project do
    [
      app: :ragex,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Ragex.Application, []}
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
      {:dialyxir, "~> 1.1", only: :dev}
    ]
  end
end
