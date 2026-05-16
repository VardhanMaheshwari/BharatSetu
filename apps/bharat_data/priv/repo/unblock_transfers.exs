# apps/bharat_data/priv/repo/unblock_transfers.exs
alias BharatData.{Repo, Schemas.Transfer}
import Ecto.Query

wallet = "0x63b0222b15d2e6b1ccef487997f5ff64173cc7ef"

IO.puts "Unblocking transfers for wallet: #{wallet}"

{count, _} = from(t in Transfer,
  where: t.wallet == ^wallet,
  where: t.state in ["init", "locked", "confirmed", "porc_in_progress", "porc_finalized"]
)
|> Repo.update_all(set: [state: "failed", failure_reason: "Manual reset to unblock frontend"])

IO.puts "Successfully marked #{count} transfers as failed."
