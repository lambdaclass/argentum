defmodule GameBackend.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def up do
    # 1. Create accounts table
    create table(:accounts) do
      add :username, :string, null: false
      add :password_hash, :string, null: false
      timestamps()
    end

    create unique_index(:accounts, [:username])

    # 2. Add temporary integer column for the new FK
    alter table(:characters) do
      add :account_id_new, :bigint
    end

    flush()

    # 3. Migrate existing characters: create accounts from distinct account_id strings
    execute """
    INSERT INTO accounts (username, password_hash, inserted_at, updated_at)
    SELECT DISTINCT
      LOWER(REPLACE(c.account_id, 'account_', '')),
      '$2b$12$placeholder_hash_for_migration',
      NOW(),
      NOW()
    FROM characters c
    WHERE c.account_id IS NOT NULL
    ON CONFLICT (username) DO NOTHING
    """

    # 4. Link characters to their new account IDs
    execute """
    UPDATE characters c
    SET account_id_new = a.id
    FROM accounts a
    WHERE LOWER(REPLACE(c.account_id, 'account_', '')) = a.username
    """

    # 5. Drop old string column, rename new one, add constraints
    alter table(:characters) do
      remove :account_id
    end

    rename table(:characters), :account_id_new, to: :account_id

    flush()

    alter table(:characters) do
      modify :account_id, references(:accounts, on_delete: :delete_all), null: false
    end

    create index(:characters, [:account_id])
  end

  def down do
    # Remove FK constraint
    drop_if_exists index(:characters, [:account_id])

    alter table(:characters) do
      remove :account_id
    end

    alter table(:characters) do
      add :account_id, :string
    end

    flush()

    # Restore old string account_id from accounts table
    execute """
    UPDATE characters c
    SET account_id = 'account_' || a.username
    FROM accounts a
    WHERE c.account_id IS NULL
    """

    drop table(:accounts)
  end
end
