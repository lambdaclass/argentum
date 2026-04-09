defmodule GameBackend.Repo.Migrations.AddGuildDepthFields do
  use Ecto.Migration

  def change do
    alter table(:guilds) do
      add :level, :integer, default: 1, null: false
      add :current_exp, :integer, default: 0, null: false
      add :news, :text, default: ""
      add :url, :string, default: ""
      add :alignment, :integer, default: 0, null: false
    end
  end
end
