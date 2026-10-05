defmodule Crawler.Diagnostics do
  @moduledoc false

  alias Crawler.URL

  def crawl(opts) do
    opts
    |> Enum.into(%{})
    |> Map.take([:depth, :max_depths, :max_pages, :html_tag])
    |> Map.put(:url, url(opts[:url]))
    |> inspect()
  end

  def url(url) when is_binary(url) do
    case URL.resolve(url, nil) do
      {:ok, target} ->
        target
        |> URI.parse()
        |> Map.put(:userinfo, nil)
        |> URI.to_string()

      :skip ->
        "<invalid URL>"
    end
  end

  def url(_url), do: "<unknown>"

  def failure(kind, reason, stacktrace) do
    reason = Exception.normalize(kind, reason, stacktrace)
    type = if is_exception(reason), do: inspect(reason.__struct__), else: inspect(kind)

    stacktrace =
      Enum.map(stacktrace, fn
        {module, function, args, location} when is_list(args) ->
          {module, function, length(args), location}

        entry ->
          entry
      end)

    "#{type}\n" <> Exception.format_stacktrace(stacktrace)
  end
end
