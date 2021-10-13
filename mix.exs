defmodule Crawler.Mixfile do
  use Mix.Project

  @source_url "https://github.com/fredwu/crawler"
  @version "1.1.2"

  def project do
    [
      app: :crawler,
      version: @version,
      elixir: "~> 1.5",
      package: package(),
      name: "Crawler",
      description: "A high performance web crawler in Elixir.",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [coveralls: :test],
      aliases: [publish: ["hex.publish", &git_tag/1]],
      dialyzer: [
        plt_add_apps: [:crawler],
        flags: [:error_handling, :race_conditions, :underspecs]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Crawler, []}
    ]
  end

  defp deps do
    [
      {:httpoison, "~> 1.5"},
      {:floki, "~> 0.25"},
      {:opq, "~> 3.0"},
      {:retry, "~> 0.10"},
      {:plug_cowboy, "~> 1.0", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:dialyxir, "~> 0.5", only: [:dev, :test], runtime: false},
      {:bypass, "~> 1.0", only: :test},
      {:excoveralls, "~> 0.7", only: :test}
    ]
  end

  defp package do
    [
      maintainers: ["Fred Wu"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp git_tag(_args) do
    System.cmd("git", ["tag", "v" <> Mix.Project.config()[:version]])
    System.cmd("git", ["push"])
    System.cmd("git", ["push", "--tags"])
  end

  defp docs do
    [
      extras: ["CHANGELOG.md": [title: "Changelog"], "README.md": [title: "Overview"]],
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      formatters: ["html"]
    ]
  end
end
