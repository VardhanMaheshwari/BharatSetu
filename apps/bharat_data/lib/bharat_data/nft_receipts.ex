defmodule BharatData.NftReceipts do
  import Ecto.Query
  alias BharatData.{Repo, Schemas.NftReceipt}

  def create(attrs) do
    %NftReceipt{}
    |> NftReceipt.changeset(attrs)
    |> Repo.insert()
  end

  def get_by_transfer(transfer_id) do
    NftReceipt |> where([r], r.transfer_id == ^transfer_id) |> Repo.one()
  end

  def get_by_cross_chain_id(cross_chain_id) do
    NftReceipt |> where([r], r.cross_chain_id == ^cross_chain_id) |> Repo.one()
  end

  def update_wrapped(id, wrapped_chain, wrapped_mint) do
    NftReceipt
    |> Repo.get!(id)
    |> NftReceipt.changeset(%{wrapped_chain: wrapped_chain, wrapped_mint: wrapped_mint})
    |> Repo.update()
  end
end
