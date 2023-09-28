import Config

config :tesla, adapter: {Tesla.Adapter.Finch, name: Crawler.Finch}

config :logger,
  backends: [:console],
  compile_time_purge_matching: [[level_lower_than: :info]]

if File.exists?("config/#{Mix.env()}.exs") do
  import_config("#{Mix.env()}.exs")
end
