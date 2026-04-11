defmodule GameBackend.CharacterSkill do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "character_skills" do
    belongs_to(:character, GameBackend.Characters)
    field(:skill_name, :string)
    field(:level, :integer, default: 0)
    timestamps()
  end

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [:character_id, :skill_name, :level])
    |> validate_required([:character_id, :skill_name])
    |> unique_constraint([:character_id, :skill_name])
  end
end
