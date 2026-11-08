class AddSshToComputers < ActiveRecord::Migration[8.2]
  def change
    add_column :computers, :ssh_host, :string
    add_column :computers, :ssh_user, :string
    add_column :computers, :folder, :string
  end
end
