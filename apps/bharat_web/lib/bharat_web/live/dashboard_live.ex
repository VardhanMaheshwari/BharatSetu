defmodule BharatWeb.DashboardLive do
  use BharatWeb, :live_view

  alias BharatCore.Pricing.PriceAggregator

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(BharatSetu.PubSub, "prices:updated")
      Phoenix.PubSub.subscribe(BharatSetu.PubSub, "dashboard:stats")
    end

    prices = %{
      BCT: PriceAggregator.get_price("BCT"),
      NCT: PriceAggregator.get_price("NCT"),
      GS: PriceAggregator.get_price("GS"),
      USD_INR: PriceAggregator.get_fx("USD_INR")
    }

    {:ok, assign(socket, prices: prices, stats: %{}, halted: false)}
  end

  @impl true
  def handle_info({:prices, prices}, socket) do
    {:noreply, assign(socket, prices: prices)}
  end

  def handle_info(:halt, socket) do
    {:noreply, assign(socket, halted: true)}
  end

  def handle_info({:stats, stats}, socket) do
    {:noreply, assign(socket, stats: stats)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="dashboard">
      <h1>BharatSetu Dashboard</h1>

      <%= if @halted do %>
        <div class="alert alert-danger">
          Price divergence detected — CBDC minting halted
        </div>
      <% end %>

      <div class="prices">
        <h2>Carbon Credit Prices</h2>
        <p>BCT: $<%= @prices[:BCT] %></p>
        <p>NCT: $<%= @prices[:NCT] %></p>
        <p>GS: $<%= @prices[:GS] %></p>
        <p>USD/INR: ₹<%= @prices[:USD_INR] %></p>
      </div>
    </div>
    """
  end
end
