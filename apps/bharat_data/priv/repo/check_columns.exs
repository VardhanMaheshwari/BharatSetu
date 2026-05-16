
# apps/bharat_data/priv/repo/check_columns.exs
alias BharatData.Repo
import Ecto.Query

try do
  query = "SELECT column_name FROM information_schema.columns WHERE table_name = 'transfers'"
  result = Ecto.Adapters.SQL.query!(Repo, query)
  IO.inspect(result.rows, label: "Columns in transfers table")
rescue
  e -> IO.inspect(e, label: "Error checking columns")
end
