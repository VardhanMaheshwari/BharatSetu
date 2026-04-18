defmodule BharatWeb.Plugs.CorrelationId do
  import Plug.Conn

  @header "x-correlation-id"

  def init(opts), do: opts

  def call(conn, _opts) do
    correlation_id =
      case get_req_header(conn, @header) do
        [id | _] -> id
        [] -> generate_id()
      end

    conn
    |> put_req_header(@header, correlation_id)
    |> put_resp_header(@header, correlation_id)
    |> assign(:correlation_id, correlation_id)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
