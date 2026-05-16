defmodule BharatData.Repo.Migrations.AddMissingTransferFields do
  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE transfers ADD COLUMN IF NOT EXISTS compliance_status varchar NOT NULL DEFAULT 'approved'",
      "ALTER TABLE transfers DROP COLUMN IF EXISTS compliance_status"
    )

    execute(
      "ALTER TABLE transfers ADD COLUMN IF NOT EXISTS transfer_type varchar NOT NULL DEFAULT 'token_to_token'",
      "ALTER TABLE transfers DROP COLUMN IF EXISTS transfer_type"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS transfers_compliance_status_index ON transfers (compliance_status)",
      "DROP INDEX IF EXISTS transfers_compliance_status_index"
    )
  end
end