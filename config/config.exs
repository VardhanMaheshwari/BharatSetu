import Config

config :bharat_web, BharatWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [json: BharatWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: BharatSetu.PubSub,
  live_view: [signing_salt: "bharat_setu_lv"]

config :bharat_core,
  confirmation_depth: 3,
  solana_indexing_enabled: false,
  anvil_indexing_enabled: false

config :bharat_adapters,
  kyc_adapter: BharatAdapters.KYC.MockClient,
  registry_adapter: BharatAdapters.Registry.MockStrategy,
  anvil_http_url: "http://127.0.0.1:8545"

config :bharat_data,
  ecto_repos: [BharatData.Repo]

config :bharat_data, BharatData.Repo,
  migration_primary_key: [type: :uuid],
  migration_timestamps: [type: :utc_datetime_usec]

config :bharat_web, BharatWeb.Auth.Guardian,
  issuer: "bharat_setu"

import_config "#{config_env()}.exs"
