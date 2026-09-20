import Config

# A short lease keeps expiry tests fast where they cannot inject a clock.
config :review_queue, lease_ttl: 100, max_attempts: 3, port: 4002
config :logger, level: :warning
