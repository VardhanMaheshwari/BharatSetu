defmodule BharatData.TokenRegistry do
  import Ecto.Query
  alias BharatData.{Repo, Schemas.TokenRegistry}

  def lookup(channel_id, original_chain, original_address) do
    TokenRegistry
    |> where([t], t.channel_id == ^channel_id)
    |> where([t], t.original_chain == ^original_chain)
    |> where([t], fragment("lower(?)", t.original_address) == ^String.downcase(original_address))
    |> Repo.one()
  end

  def lookup_by_wrapped(channel_id, wrapped_chain, wrapped_address) do
    TokenRegistry
    |> where([t], t.channel_id == ^channel_id)
    |> where([t], t.wrapped_chain == ^wrapped_chain)
    |> where([t], fragment("lower(?)", t.wrapped_address) == ^String.downcase(wrapped_address))
    |> Repo.one()
  end

  def is_wrapped?(channel_id, chain, address) do
    case lookup_by_wrapped(channel_id, chain, address) do
      nil -> false
      _   -> true
    end
  end

  def register(attrs) do
    %TokenRegistry{}
    |> TokenRegistry.changeset(attrs)
    |> Repo.insert(on_conflict: :replace_all,
                   conflict_target: [:channel_id, :original_chain, :original_address])
  end

  def list_for_channel(channel_id) do
    TokenRegistry
    |> where([t], t.channel_id == ^channel_id)
    |> Repo.all()
  end
end
