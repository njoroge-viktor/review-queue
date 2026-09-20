import Config

config :review_queue,
  port: 4000,
  lease_ttl: :timer.minutes(5),
  max_attempts: 3

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
