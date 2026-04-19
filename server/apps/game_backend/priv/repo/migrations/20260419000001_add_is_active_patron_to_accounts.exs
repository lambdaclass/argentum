defmodule GameBackend.Repo.Migrations.AddIsActivePatronToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :is_active_patron, :integer, null: false, default: 0
    end
  end
end
