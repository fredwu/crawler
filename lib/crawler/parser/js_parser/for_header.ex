defmodule Crawler.Parser.JsParser.ForHeader do
  @moduledoc false

  def open(headers, "for", depth), do: [{depth, :binding} | headers]
  def open(headers, _statement, _depth), do: headers

  def close([{depth, _phase} | headers], depth), do: headers
  def close(headers, _depth), do: headers

  def binding?([{depth, :binding} | _headers], depth), do: true
  def binding?(_headers, _depth), do: false

  def operator([{depth, :binding} | headers], depth, operator)
      when operator in [?;, ?=, ?,],
      do: [{depth, :expression} | headers]

  def operator(headers, _depth, _operator), do: headers

  def word([{depth, :binding} | headers], depth, word, complete?, previous)
      when word in ["of", "in"] and complete? and previous not in ["const", "let", "var"] do
    {word == "of", [{depth, :expression} | headers]}
  end

  def word(headers, _depth, _word, _complete?, _previous), do: {false, headers}
end
