defmodule Crawler.Mixfile do
  use Mix.Project

  @source_url "https://github.com/fredwu/crawler"
  @version "1.5.0"

  def project do
    [
      app: :crawler,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
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
        flags: [:error_handling, :underspecs]
      ]
    ]
  end

  def application do
    [
      mod: {Crawler, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "examples"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:httpoison, "~> 2.2"},
      {:floki, "~> 0.38"},
      {:opq, "~> 4.0"},
      {:retry, "~> 0.19"},
      {:recode, "~> 0.8", only: :dev},
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:plug_cowboy, "~> 2.7", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:excoveralls, "~> 0.18", only: :test}
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
