defmodule BharatWeb.DashboardChannel do
  use BharatWeb, :channel

  @impl true
  def join("dashboard:lobby", _payload, socket) do
    Phoenix.PubSub.subscribe(BharatSetu.PubSub, "prices:updated")
    Phoenix.PubSub.subscribe(BharatSetu.PubSub, "dashboard:stats")
    {:ok, socket}
  end

  @impl true
  def handle_info({:prices, prices}, socket) do
    push(socket, "prices_updated", %{prices: prices})
    {:noreply, socket}
  end

  def handle_info({:stats, stats}, socket) do
    push(socket, "stats_updated", stats)
    {:noreply, socket}
  end
end
