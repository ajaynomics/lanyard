# Each person's own SSH key pair and trusted hosts in the sidecar
# (agent/ssh-computers.mjs, User#ssh_keyring). Until now the install had one
# pair for everyone. If one person used SSH computers, that pair stays theirs
# ("shared"), so their machines keep working; everyone else gets their own on
# first use and adds it to their machines.
class AddSshKeyringToUsers < ActiveRecord::Migration[8.2]
  def up
    add_column :users, :ssh_keyring, :string
    users = select_values(<<~SQL)
      SELECT DISTINCT agents.user_id FROM computers JOIN agents ON agents.id = computers.agent_id
      WHERE computers.provider = 'ssh' AND computers.ssh_host IS NOT NULL
    SQL
    execute "UPDATE users SET ssh_keyring = 'shared' WHERE id = #{Integer(users.sole)}" if users.one?
  end

  def down
    remove_column :users, :ssh_keyring
  end
end
