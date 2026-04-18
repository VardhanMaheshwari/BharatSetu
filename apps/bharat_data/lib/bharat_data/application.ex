defmodule BharatData.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [BharatData.Repo]
    Supervisor.start_link(children, strategy: :one_for_one, name: BharatData.Supervisor)
  end
end
