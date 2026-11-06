# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.2].define(version: 2026_11_01_000000) do
  create_table "agent_conversations", force: :cascade do |t|
    t.string "workspace_id", null: false
    t.string "actor_id", null: false
    t.string "request_id", null: false
    t.string "durable_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["workspace_id", "actor_id", "durable_id"], name: "agent_conversation_identity", unique: true
    t.index ["workspace_id", "actor_id", "request_id"], name: "agent_conversation_admission", unique: true
  end

  create_table "agent_effects", force: :cascade do |t|
    t.string "workspace_id", null: false
    t.string "actor_id", null: false
    t.string "task_id", null: false
    t.string "call_id", null: false
    t.string "argument_digest", null: false
    t.json "result"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["workspace_id", "actor_id", "task_id", "call_id"], name: "agent_effect_identity", unique: true
  end

  create_table "agent_notes", force: :cascade do |t|
    t.string "workspace_id", null: false
    t.string "actor_id", null: false
    t.string "key", null: false
    t.text "body", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["workspace_id", "actor_id", "key"], name: "agent_note_identity", unique: true
  end
end
