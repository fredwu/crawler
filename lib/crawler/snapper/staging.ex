defmodule Crawler.Snapper.Staging do
  @moduledoc false

  @prefix ".crawler-"

  def prefix, do: @prefix

  def filename do
    @prefix <> Integer.to_string(System.unique_integer([:positive])) <> ".tmp"
  end
end
