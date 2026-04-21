defmodule GameBackend.Repo.Migrations.AddPotionStateToCharacters do
  use Ecto.Migration

  def change do
    alter table(:characters) do
      add :duracion_efecto, :integer, default: 0, null: false
      add :tomo_pocion, :boolean, default: false, null: false
      add :str_potion_delta, :integer, default: 0, null: false
      add :agi_potion_delta, :integer, default: 0, null: false
      add :str_backup, :integer, default: 0, null: false
      add :agi_backup, :integer, default: 0, null: false
    end
  end
end
