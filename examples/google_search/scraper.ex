defmodule Crawler.Example.GoogleSearch.Scraper do
  @moduledoc """
  Scrapes HTTPS GitHub pages without URL credentials for a project's name and description.
  """

  @behaviour Crawler.Scraper.Spec

  alias Crawler.Example.GoogleSearch.Data
  alias Crawler.Store.Page
  alias Crawler.URL.Host

  def scrape(%Page{url: url} = page) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}} when is_binary(host) ->
        if Host.fold(host) == "github.com", do: scrape_project(page), else: {:ok, page}

      _ ->
        {:ok, page}
    end
  end

  def scrape(page), do: {:ok, page}

  defp scrape_project(%Page{url: url, body: body} = page) do
    doc = Floki.parse_document!(body)

    name =
      doc
      |> Floki.find("#repository-container-header strong a")
      |> Floki.text()

    desc =
      doc
      |> Floki.find(".Layout-sidebar p.f4")
      |> Floki.text()
      |> String.trim()

    if name != "" do
      Agent.update(Data, fn state ->
        Map.put(state, name, %{url: url, desc: desc})
      end)
    end

    {:ok, page}
  end
end
