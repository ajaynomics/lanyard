# A skill becomes a folder (docs/skills.md): the files beside its SKILL.md,
# whether it waits for a person's review, and where it came from on GitHub.
# Existing skills are SKILL.md alone, so they stay ready with no files.
class CreateSkillBundledFiles < ActiveRecord::Migration[8.2]
  def change
    create_table :skill_bundled_files do |t|
      t.references :skill, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :path, null: false
      t.binary :content, null: false
      t.integer :size, null: false
      t.boolean :executable, null: false, default: false
      t.timestamps
      t.index %i[ skill_id path ], unique: true
    end

    change_table :skills do |t|
      t.string :state, null: false, default: "ready"
      t.string :github_repo
      t.string :github_path
      t.string :github_ref
      t.string :github_sha
    end
  end
end
