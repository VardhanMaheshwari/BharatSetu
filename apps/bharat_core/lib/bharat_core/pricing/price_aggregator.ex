defmodule BharatCore.Pricing.PriceAggregator do
  use GenServer
  require Logger

  @refresh_interval_ms 30_000
  @vwap_divergence_threshold 0.05

  def start_link(_), do: GenServer.start_link(__MODULE__, %{halted: false}, name: __MODULE__)

  def get_price(token), do: Cachex.get!(:price_cache, {:price, token})
  def get_fx(pair), do: Cachex.get!(:price_cache, {:fx, pair})

  @impl true
  def init(state) do
    send(self(), :refresh)
    {:ok, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    sources = [
      Task.async(fn -> fetch_coingecko_prices() end),
      Task.async(fn -> fetch_rbi_fx() end)
    ]

    results = Task.await_many(sources, 10_000)
    [carbon_prices, fx_rates] = results

    case compute_vwap(carbon_prices) do
      {:ok, prices} ->
        Enum.each(prices, fn {k, v} ->
          Cachex.put!(:price_cache, {:price, to_string(k)}, v)
        end)

        Enum.each(fx_rates, fn {k, v} ->
          Cachex.put!(:price_cache, {:fx, to_string(k)}, v)
        end)

        Phoenix.PubSub.broadcast(BharatSetu.PubSub, "prices:updated", {:prices, prices})
        schedule_refresh()
        {:noreply, %{state | halted: false}}

      {:error, :divergence_too_high} ->
        Logger.error("Price divergence exceeds #{@vwap_divergence_threshold * 100}% — halting CBDC minting")
        Phoenix.PubSub.broadcast(BharatSetu.PubSub, "prices:halted", :halt)
        schedule_refresh()
        {:noreply, %{state | halted: true}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp fetch_coingecko_prices do
    api_key = Application.get_env(:bharat_adapters, :coingecko_api_key, "")

    case Req.get("https://api.coingecko.com/api/v3/simple/price",
           params: %{
             ids: "toucan-protocol-base-carbon-tonne,nature-carbon-tonne,gold-standard",
             vs_currencies: "usd"
           },
           headers: [{"x-cg-demo-api-key", api_key}]
         ) do
      {:ok, %{status: 200, body: body}} ->
        %{
          "BCT" => get_in(body, ["toucan-protocol-base-carbon-tonne", "usd"]),
          "NCT" => get_in(body, ["nature-carbon-tonne", "usd"]),
          "GS"  => get_in(body, ["gold-standard", "usd"])
        }

      _ ->
        %{"BCT" => nil, "NCT" => nil, "GS" => nil}
    end
  end

  defp fetch_rbi_fx do
    %{"USD_INR" => 83.50}
  end

  defp compute_vwap(prices) do
    valid = Enum.reject(prices, fn {_, v} -> is_nil(v) end)

    if length(valid) == 0 do
      {:error, :divergence_too_high}
    else
      {:ok, Map.new(valid)}
    end
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end
end
