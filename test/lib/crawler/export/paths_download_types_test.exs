defmodule Crawler.Export.PathsDownloadTypesTest do
  use ExUnit.Case, async: true

  alias Crawler.Export.Paths

  @id "download00000000000000001"

  test "document response media types keep their static download suffix" do
    for {type, extension} <- [
          {"application/vnd.openxmlformats-officedocument.wordprocessingml.document", ".docx"},
          {"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", ".xlsx"}
        ] do
      assert {:ok, "resources/" <> @id <> ^extension} = Paths.artifact(@id, type)
      assert Paths.extension(type <> "; charset=binary") == extension
    end
  end

  test "unknown response media types keep the binary fallback" do
    assert Paths.extension("application/x-unknown-download") == ".bin"

    assert {:ok, "resources/" <> @id <> ".bin"} =
             Paths.artifact(@id, "application/x-unknown-download")
  end
end
