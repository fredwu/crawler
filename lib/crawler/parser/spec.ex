defmodule Crawler.Parser.Spec do
  @moduledoc """
  Spec for defining a parser.
  """

  alias Crawler.Store.Page

  @type element      :: {String.t, String.t} | {String.t, String.t, String.t, String.t}
  @type opts         :: map
  @type page         :: %Page{body: String.t}
  @type input        :: %{page: page, opts: opts}
  @type link_handler :: (element, opts -> term)

  @callback parse(input, link_handler) :: page
  @callback parse({:error, term}, link_handler) :: :ok
end
