defmodule BharatAdapters.KYC.Behaviour do
  @moduledoc "KYC provider contract."

  @callback check(wallet :: String.t()) ::
              {:ok, %{tier: non_neg_integer()}} | {:error, term()}
end
