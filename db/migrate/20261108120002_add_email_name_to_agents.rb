# Each agent's address at the install's mail domain (docs/email.md), made from
# its name and unique across the install, since one domain serves every person.
class AddEmailNameToAgents < ActiveRecord::Migration[8.2]
  def up
    add_column :agents, :email_name, :string
    taken = []
    select_rows("SELECT id, name FROM agents ORDER BY id").each do |id, name|
      base = name.to_s.parameterize.first(40).delete_suffix("-").presence || "agent"
      email_name = (1..).lazy.map { it == 1 ? base : "#{base}-#{it}" }.find { !taken.include?(it) }
      taken << email_name
      execute "UPDATE agents SET email_name = #{connection.quote(email_name)} WHERE id = #{id}"
    end
    change_column_null :agents, :email_name, false
    add_index :agents, :email_name, unique: true
  end

  def down
    remove_column :agents, :email_name
  end
end
