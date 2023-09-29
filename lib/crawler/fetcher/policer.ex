defmodule Crawler.Fetcher.Policer do
  @moduledoc """
  Checks a series of conditions to determine whether it is okay to continue.
  """

  require Logger

  alias Crawler.Store

  @uri_schemes ["http", "https"]
  @asset_extra_depth 2

  @doc """
  Checks a series of conditions to determine whether it is okay to continue,
  i.e. to allow `Crawler.Fetcher.fetch/1` to begin its tasks.
  """
  def police(opts) do
    with {_, true} <- within_max_pages?(opts),
         {_, true} <- within_fetch_depth?(opts),
         {_, true} <- acceptable_uri_scheme?(opts),
         {_, true} <- not_fetched_yet?(opts),
         {_, true} <- perform_url_filtering(opts) do
      {:ok, opts}
    else
      {fail_type, _} ->
        police_error(fail_type, opts)
    end
  end

  defp within_max_pages?(%{max_pages: :infinity} = _opts), do: {:within_max_pages?, true}

  defp within_max_pages?(%{max_pages: max_pages} = _opts) when is_integer(max_pages) do
    {:within_max_pages?, Store.ops_count() <= max_pages}
  end

  defp within_max_pages?(_opts), do: {:within_max_pages?, true}

  defp within_fetch_depth?(%{depth: depth, max_depths: max_depths} = opts) do
    max_depths =
      case opts[:html_tag] do
        "a" -> max_depths
        _ -> max_depths + @asset_extra_depth
      end

    {:within_fetch_depth?, depth < max_depths}
  end

  defp within_fetch_depth?(_opts), do: {:within_fetch_depth?, true}

  defp acceptable_uri_scheme?(%{url: url} = _opts) do
    scheme =
      url
      |> String.split("://", parts: 2)
      |> Kernel.hd()

    {:acceptable_uri_scheme?, Enum.member?(@uri_schemes, scheme)}
  end

  defp acceptable_uri_scheme?(_opts), do: {:acceptable_uri_scheme?, true}

  defp not_fetched_yet?(%{url: url} = _opts) do
    {:not_fetched_yet?, !Store.find(url)}
  end

  defp not_fetched_yet?(_opts), do: {:not_fetched_yet?, true}

  defp perform_url_filtering(%{url_filter: url_filter, url: url} = opts) do
    {:ok, pass_through?} = url_filter.filter(url, opts)

    {:perform_url_filtering, pass_through?}
  end

  defp perform_url_filtering(_opts), do: {:perform_url_filtering, true}

  defp police_error(fail_type, opts) do
    msg = "Fetch failed '#{fail_type}', with opts: #{Kernel.inspect(opts)}."

    Logger.warning(msg)

    {:error, msg}
  end
end
