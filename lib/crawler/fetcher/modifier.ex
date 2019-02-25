defmodule Crawler.Fetcher.Modifier do
  @moduledoc """
  Modifies request options and headers before dispatch.
  """

  defmodule Spec do
    @type url    :: String.t
    @type header :: {String.t, String.t}
    @type opts   :: map

    @callback headers(opts) :: list(header) | []
    @callback opts(opts)    :: keyword | []
  end

  @behaviour __MODULE__.Spec

  @doc """
  Allows modifing headers prior to making a crawl request.

  ## Example implementation

      def headers(opts) do
        if opts[:url] == "http://modifier" do
          [{"Referer", "http://fetcher"}]
        end
        []
      end
  """
  def headers(_opts), do: []

  @doc """
  Allows passing opts to httpPoison prior to making the crawl request

  ## Example implementation

      def opts(opts) do
        if opts[:url] == "http://modifier" do
          # add a new pool to hackney
          [hackney: [pool: :modifier]]
        end
        []
      end
  """
  def opts(_opts), do: []
end
