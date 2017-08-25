defmodule Crawler.Parser.Spec do
  @moduledoc """
  Spec for defining a parser.
  """

  @type page         :: map
  @type link_handler :: fun

  @callback parse(page, link_handler) :: page
end
