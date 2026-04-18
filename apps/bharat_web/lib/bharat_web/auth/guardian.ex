defmodule BharatWeb.Auth.Guardian do
  use Guardian, otp_app: :bharat_web

  def subject_for_token(wallet, _claims) when is_binary(wallet) do
    {:ok, wallet}
  end

  def subject_for_token(_, _), do: {:error, :invalid_subject}

  def resource_from_claims(%{"sub" => wallet}) do
    {:ok, wallet}
  end

  def resource_from_claims(_), do: {:error, :invalid_claims}
end
