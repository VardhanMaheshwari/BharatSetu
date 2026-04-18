defmodule BharatRelayer.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BharatRelayer.Worker
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BharatRelayer.Supervisor)
  end
end
