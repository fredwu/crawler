import Config

# ExUnit capture_log stores logs and prints them when a test fails.
# A console handler prints a fetch that finishes after that window, and
# OTP reports a crash of that handler as removed_failing_handler.
config :logger,
  backends: [],
  default_handler: false,
  compile_time_purge_matching: [[level_lower_than: :debug]]
