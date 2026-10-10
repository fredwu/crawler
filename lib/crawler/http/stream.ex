defmodule Crawler.HTTP.Stream do
  @moduledoc false

  alias Crawler.HTTP.Body

  def stream(req, finch_request, finch_name, finch_options) do
    response = Req.Response.new()

    case Finch.stream_while(
           finch_request,
           finch_name,
           {req, response},
           &collect(&1, &2, req.into),
           finch_options
         ) do
      {:ok, acc} ->
        acc

      {:error, exception} ->
        {req, normalize_error(exception)}

      {:error, exception, acc} ->
        Body.release(acc)
        {req, normalize_error(exception)}
    end
  end

  defp collect({:status, status}, {req, response}, _into) do
    {:cont, {req, %{response | status: status}}}
  end

  defp collect({:headers, fields}, {req, response}, _into) do
    {:cont, {req, append_headers(response, fields)}}
  end

  defp collect({:data, data}, acc, into) do
    into.({:data, data}, acc)
  end

  defp collect({:trailers, fields}, {req, response}, _into) do
    {:cont, {req, update_in(response.trailers, &Map.merge(&1, pair_map(fields)))}}
  end

  defp append_headers(response, fields) do
    Enum.reduce(fields, response, fn {name, value}, response ->
      append_header(response, name, value)
    end)
  end

  defp append_header(%Req.Response{headers: headers} = response, name, value) do
    %{response | headers: append_field(headers, field_name(name), field_value(value))}
  end

  defp append_field(fields, name, value) do
    Map.update(fields, name, [value], &(&1 ++ [value]))
  end

  defp field_name(name) do
    name
    |> to_string()
    |> String.downcase(:ascii)
  end

  defp field_value(value) when is_binary(value), do: value
  defp field_value(value), do: to_string(value)

  defp pair_map(fields) do
    Enum.reduce(fields, %{}, fn {name, value}, acc ->
      Map.update(acc, field_name(name), [field_value(value)], &(&1 ++ [field_value(value)]))
    end)
  end

  defp normalize_error(%Mint.TransportError{reason: reason}) do
    %Req.TransportError{reason: reason}
  end

  defp normalize_error(%Mint.HTTPError{module: Mint.HTTP1, reason: reason}) do
    %Req.HTTPError{protocol: :http1, reason: reason}
  end

  defp normalize_error(%Mint.HTTPError{module: Mint.HTTP2, reason: reason}) do
    %Req.HTTPError{protocol: :http2, reason: reason}
  end

  defp normalize_error(%Finch.Error{reason: reason}) do
    %Req.HTTPError{protocol: :http2, reason: reason}
  end

  defp normalize_error(%Finch.TransportError{reason: reason}) do
    %Req.TransportError{reason: reason}
  end

  defp normalize_error(%Finch.HTTPError{module: module, reason: reason}) do
    protocol = if module == Mint.HTTP2, do: :http2, else: :http1
    %Req.HTTPError{protocol: protocol, reason: reason}
  end

  defp normalize_error(error), do: error
end
