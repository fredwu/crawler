defmodule Crawler.Mixfile do
  use Mix.Project

  def project do
    [
      app:             :crawler,
      version:         "0.0.0",
      elixir:          "~> 1.3",
      package:         package(),
      name:            "Crawler",
      description:     "A high performance web crawler in Elixir.",
      build_embedded:  Mix.env == :prod,
      start_permanent: Mix.env == :prod,
      deps:            deps(),
      aliases:         ["publish": ["hex.publish", &git_tag/1]]
    ]
  end

  def application do
    [
      applications: [:logger, :httpoison, :floki],
      mod:          {Crawler, []}
    ]
  end

  defp deps do
    [
      {:httpoison, "~> 0.9.0"},
      {:floki,     "~> 0.9.0"},
      {:ex_doc,    ">= 0.0.0", only: :dev},
      {:bypass,    github: "PSPDFKit-labs/bypass", only: :test}
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
