import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :collab_md, CollabMdWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "AhDUVukmVlFf/zMxo+vbxCj0Gg/4w1BmGzBmp6aK0legWIjlK82rNR4pTeQxcWEN",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
