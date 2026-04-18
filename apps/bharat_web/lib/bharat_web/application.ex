defmodule BharatWeb.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BharatWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: BharatWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    BharatWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
