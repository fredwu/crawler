defmodule Crawler.LoggerSilenceTest do
  use ExUnit.Case, async: false

  require Logger

  @tag capture_log: false
  test "the console handler stays off outside a test" do
    assert Application.get_env(:logger, :backends) == []
    assert Application.get_env(:logger, :default_handler) == false
    assert :logger.get_handler_config(:default) == {:error, {:not_found, :default}}
  end

  test "capture_log still records a message" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Logger.error("captured-marker")
      end)

    assert log =~ "captured-marker"
  end
end
