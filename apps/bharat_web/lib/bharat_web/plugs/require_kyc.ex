defmodule BharatWeb.Plugs.RequireKYC do
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @min_kyc_tier 2

  def init(opts), do: opts

  def call(conn, _opts) do
    wallet = conn.assigns.wallet

    case BharatAdapters.KYC.check(wallet) do
      {:ok, %{tier: tier}} when tier >= @min_kyc_tier ->
        assign(conn, :kyc_tier, tier)

      {:ok, %{tier: tier}} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "KYC tier #{tier} insufficient; tier #{@min_kyc_tier} required"})
        |> halt()

      {:error, _reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "KYC service unavailable"})
        |> halt()
    end
  end
end
