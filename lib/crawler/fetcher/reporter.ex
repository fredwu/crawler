defmodule Crawler.Fetcher.Reporter do
  @moduledoc """
  Reports status of the fetch to external systems.
  """

  defmodule Spec do
    @type opts        :: map
    @type error_msg   :: String.t
    @type status_code :: integer

    @callback report_success(opts) :: nil
    @callback report_fail(opts, error_msg, status_code) :: nil
  end

  @behaviour __MODULE__.Spec

  @doc """
  Reports successful fetch to external system.

  ## Example implementation

      def report_success(opts) do
        IO.puts(opts[:url] <> " was successfully fetched")
      end
  """
  def report_success(_opts), do: nil

  @doc """
  Reports failed fetch to external system.

  ## Example implementation

      def report_fail(opts, error_msg, status_code) do
        IO.puts("Failed to fetch " <> opts[:url])
      end
  """
  def report_fail(_opts, _error_msg, _status_code), do: nil

end
