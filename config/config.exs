use Mix.Config

config :logger, backends: [:console], compile_time_purge_level: :info

if File.exists?("config/#{Mix.env}.exs") do
  import_config("#{Mix.env}.exs")
end
