class RemoveDonRole < ActiveRecord::Migration[8.1]
  # DON was retired from the role vocabulary (folded into agency admin).
  # Detach any users still holding it, then delete the global Role row.
  # Raw SQL avoids acts_as_tenant / model-callback concerns during migration.
  def up
    execute(<<~SQL)
      DELETE FROM user_roles WHERE role_id IN (SELECT id FROM roles WHERE name = 'don');
      DELETE FROM roles WHERE name = 'don';
    SQL
  end

  def down
    execute(<<~SQL)
      INSERT INTO roles (name, label, created_at, updated_at)
      SELECT 'don', 'Director of Nursing', now(), now()
      WHERE NOT EXISTS (SELECT 1 FROM roles WHERE name = 'don');
    SQL
  end
end
