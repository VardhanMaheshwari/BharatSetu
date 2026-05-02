defmodule BharatData.Channels do
  import Ecto.Query
  alias BharatData.{Repo, Schemas.Channel}

  def get(id), do: Repo.get(Channel, id)

  def get!(id), do: Repo.get!(Channel, id)

  def list_active do
    Channel |> where([c], c.active == true) |> Repo.all()
  end

  def create(attrs) do
    %Channel{}
    |> Channel.changeset(attrs)
    |> Repo.insert()
  end

  def upsert(attrs) do
    %Channel{}
    |> Channel.changeset(attrs)
    |> Repo.insert(on_conflict: :replace_all, conflict_target: :id)
  end
end
