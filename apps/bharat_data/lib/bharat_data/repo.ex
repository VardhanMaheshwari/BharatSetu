defmodule BharatData.Repo do
  use Ecto.Repo,
    otp_app: :bharat_data,
    adapter: Ecto.Adapters.Postgres
end
