defmodule ReviewQueue.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/njoroge-viktor/review-queue"

  def project do
    [
      app: :review_queue,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      test_coverage: [summary: [threshold: 85]],
      dialyzer: [plt_add_apps: [:mix, :ex_unit]],
      name: "ReviewQueue",
      source_url: @source_url,
      description: description(),
      package: package(),
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ReviewQueue.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      check: ["format --check-formatted", "credo --strict", "test"]
    ]
  end

  defp description do
    "Concurrent review queue for annotation workforces, built on OTP supervision and ETS."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
