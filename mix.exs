defmodule BackoffRetry.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/yoavgeva/backoff_retry"

  def project do
    [
      app: :backoff_retry,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      name: "BackoffRetry",
      description:
        "Functional retry with backoff for Elixir — composable strategies, zero macros, injectable sleep."
    ]
  end

  def application do
    []
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "BackoffRetry",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
