defmodule Crawler.Example.GoogleSearch.Scraper do
  @moduledoc """
  We only scrape Github pages, specifically looking for a project's name and description.
  """

  @behaviour Crawler.Scraper.Spec

  alias Crawler.Store.Page
  alias Crawler.Example.GoogleSearch.Data

  def scrape(%Page{url: "https://github.com" <> _ = url, body: body, opts: _opts} = page) do
    doc =
      body
      |> Floki.parse_document!()

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
        Map.merge(state, %{name => %{url: url, desc: desc}})
      end)
    end

    {:ok, page}
  end

  def scrape(page), do: {:ok, page}
end
