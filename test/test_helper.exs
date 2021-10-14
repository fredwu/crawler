[File.cwd!(), "test", "tmp", "*"]
|> Path.join()
|> Path.wildcard()
|> Enum.each(&File.rm_rf/1)

ExUnit.start()
Application.ensure_all_started(:bypass)
