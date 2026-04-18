defmodule BharatAdapters.KYC do
  @moduledoc "Delegates to configured KYC adapter."

  def check(wallet) do
    adapter().check(wallet)
  end

  defp adapter do
    Application.get_env(:bharat_adapters, :kyc_adapter, BharatAdapters.KYC.MockClient)
  end
end
