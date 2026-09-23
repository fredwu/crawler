defmodule Crawler.HTTP do
  @moduledoc """
  Project-owned HTTP boundary.
  """

  def get(url, headers, opts) do
    opts
    |> Keyword.put(:url, url)
    |> Keyword.put(:headers, headers)
    |> Req.new()
    |> Req.Request.append_response_steps(crawler_final_url: &capture_final_url/1)
    |> Req.request()
  end

  defp capture_final_url({request, %Req.Response{} = response}) do
    url =
      request.url
      |> drop_default_port()
      |> URI.to_string()

    {request, Req.Response.put_private(response, :crawler_url, url)}
  end

  defp capture_final_url(result), do: result

  defp drop_default_port(%URI{scheme: "http", port: 80} = uri), do: %{uri | port: nil}
  defp drop_default_port(%URI{scheme: "https", port: 443} = uri), do: %{uri | port: nil}
  defp drop_default_port(uri), do: uri
end
