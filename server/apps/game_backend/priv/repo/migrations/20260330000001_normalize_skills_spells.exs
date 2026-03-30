defmodule GameBackend.Repo.Migrations.NormalizeSkillsSpells do
  use Ecto.Migration

  def change do
    create table(:character_skills) do
      add :character_id, references(:characters, on_delete: :delete_all), null: false
      add :skill_name, :string, null: false
      add :level, :integer, default: 0
      timestamps()
    end

    create unique_index(:character_skills, [:character_id, :skill_name])
    create index(:character_skills, [:character_id])

    create table(:character_spells) do
      add :character_id, references(:characters, on_delete: :delete_all), null: false
      add :spell_id, :integer, null: false
      timestamps()
    end

    create unique_index(:character_spells, [:character_id, :spell_id])
    create index(:character_spells, [:character_id])

    alter table(:characters) do
      remove :skills
      remove :spells
    end
  end
end
