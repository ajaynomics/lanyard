# A bot's computer name becomes the prefix of its agents' Sprites
# (<prefix>-<env>-b<bot id>; each agent's Sprite adds -c<conversation id>).
class NameComputersAsPrefixes < ActiveRecord::Migration[8.2]
  def up
    execute "UPDATE computers SET name = REPLACE(name, '-bot-', '-b') WHERE name LIKE '%-bot-%'"
  end

  def down
    select_rows("SELECT id, name FROM computers WHERE name GLOB '*-b[0-9]*'").each do |id, name|
      execute "UPDATE computers SET name = #{quote(name.sub(/-b(\d+)\z/, '-bot-\1'))} WHERE id = #{Integer(id)}"
    end
  end
end
