defmodule BharatWeb.PriceController do
  use BharatWeb, :controller

  alias BharatCore.Pricing.PriceAggregator

  def index(conn, _params) do
    prices = %{
      BCT: PriceAggregator.get_price("BCT"),
      NCT: PriceAggregator.get_price("NCT"),
      GS:  PriceAggregator.get_price("GS"),
      fx: %{
        USD_INR: PriceAggregator.get_fx("USD_INR")
      }
    }

    json(conn, %{data: prices})
  end
end
