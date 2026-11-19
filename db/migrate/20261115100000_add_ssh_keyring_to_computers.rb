# Each agent's own SSH key pair and trusted hosts in the sidecar (issue #59,
# Computer#ssh_keyring). Until now an SSH computer used its person's keyring,
# shared by all their agents. Each existing SSH computer keeps that one, so
# the key on its machine and the hosts it trusts stay as they are; every
# other computer is left empty and uses its agent's own, `agent-<id>`.
class AddSshKeyringToComputers < ActiveRecord::Migration[8.2]
  def up
    add_column :computers, :ssh_keyring, :string
    execute <<~SQL
      UPDATE computers SET ssh_keyring = (
        SELECT COALESCE(NULLIF(users.ssh_keyring, ''), 'person-' || users.id)
        FROM agents JOIN users ON users.id = agents.user_id WHERE agents.id = computers.agent_id)
      WHERE provider = 'ssh'
    SQL
  end

  def down
    remove_column :computers, :ssh_keyring
  end
end
