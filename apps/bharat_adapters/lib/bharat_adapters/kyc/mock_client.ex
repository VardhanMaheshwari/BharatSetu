defmodule BharatAdapters.KYC.MockClient do
  @behaviour BharatAdapters.KYC.Behaviour

  @impl true
  def check(_wallet), do: {:ok, %{tier: 2}}
end
