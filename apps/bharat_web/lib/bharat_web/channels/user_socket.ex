defmodule BharatWeb.UserSocket do
  use Phoenix.Socket

  channel "transfer:*",   BharatWeb.TransferChannel
  channel "dashboard:*",  BharatWeb.DashboardChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case BharatWeb.Auth.Guardian.decode_and_verify(token) do
      {:ok, claims} ->
        {:ok, assign(socket, :wallet, claims["sub"])}

      {:error, _} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.wallet}"
end
