defmodule GameBackend.Repo.Migrations.AddSpouseIdToCharacters do
  use Ecto.Migration

  def change do
    alter table(:characters) do
      add :spouse_id, :bigint, default: 0, null: false
    end
  end
end
