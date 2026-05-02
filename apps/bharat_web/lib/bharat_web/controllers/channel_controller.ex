defmodule BharatWeb.ChannelController do
  use BharatWeb, :controller

  alias BharatData.{Channels, TokenRegistry}

  # GET /api/channels
  def index(conn, _params) do
    channels = Channels.list_active()
    json(conn, %{data: Enum.map(channels, &serialize_channel/1)})
  end

  # GET /api/channels/:id
  def show(conn, %{"id" => id}) do
    case Channels.get(id) do
      nil     -> conn |> put_status(:not_found) |> json(%{error: "not found"})
      channel -> json(conn, %{data: serialize_channel(channel)})
    end
  end

  # GET /api/channels/:id/tokens
  def tokens(conn, %{"id" => channel_id}) do
    entries = TokenRegistry.list_for_channel(channel_id)
    json(conn, %{data: Enum.map(entries, &serialize_token/1)})
  end

  # GET /api/channels/:id/tokens/lookup?chain=ethereum&address=0x...
  def token_lookup(conn, %{"id" => channel_id, "chain" => chain, "address" => address}) do
    case TokenRegistry.lookup(channel_id, chain, address) do
      nil   -> conn |> put_status(:not_found) |> json(%{error: "token not registered"})
      entry -> json(conn, %{data: serialize_token(entry)})
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp serialize_channel(c) do
    %{
      id:               c.id,
      name:             c.name,
      zone_a:           c.zone_a,
      zone_b:           c.zone_b,
      zone_a_chain_id:  c.zone_a_chain_id,
      zone_b_cluster:   c.zone_b_cluster,
      active:           c.active
    }
  end

  defp serialize_token(t) do
    %{
      id:               t.id,
      channel_id:       t.channel_id,
      symbol:           t.symbol,
      name:             t.name,
      original_chain:   t.original_chain,
      original_address: t.original_address,
      original_standard: t.original_standard,
      original_decimals: t.original_decimals,
      wrapped_chain:    t.wrapped_chain,
      wrapped_address:  t.wrapped_address,
      wrapped_standard: t.wrapped_standard
    }
  end
end
