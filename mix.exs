defmodule Crawler.Mixfile do
  use Mix.Project

  def project do
    [
      app:             :crawler,
      version:         "0.1.0",
      elixir:          "~> 1.5",
      package:         package(),
      name:            "Crawler",
      description:     "A high performance web crawler in Elixir.",
      start_permanent: Mix.env == :prod,
      deps:            deps(),
      aliases:         ["publish": ["hex.publish", &git_tag/1]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod:                {Crawler, []}
    ]
  end

  defp deps do
    [
      {:httpoison, "~> 0.12.0"},
      {:floki,     "~> 0.17.2"},
      {:bypass,    "~> 0.8", only: :test}
    ]
  end

  defp package do
    [
      maintainers: ["Fred Wu"],
      licenses:    ["MIT"],
      links:       %{"GitHub" => "https://github.com/fredwu/crawler"}
    ]
  end

  defp git_tag(_args) do
    System.cmd "git", ["tag", "v" <> Mix.Project.config[:version]]
  end
end
