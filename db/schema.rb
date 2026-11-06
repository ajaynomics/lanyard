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

ActiveRecord::Schema[8.2].define(version: 2026_11_06_000003) do
  create_table "answers", force: :cascade do |t|
    t.integer "invocation_id", null: false
    t.integer "decided_by_id", null: false
    t.json "selections", default: [], null: false
    t.text "text", default: "", null: false
    t.datetime "created_at", null: false
    t.index ["decided_by_id"], name: "index_answers_on_decided_by_id"
    t.index ["invocation_id"], name: "index_answers_on_invocation_id", unique: true
  end

  create_table "approvals", force: :cascade do |t|
    t.integer "invocation_id", null: false
    t.integer "decided_by_id", null: false
    t.string "decision", null: false
    t.datetime "created_at", null: false
    t.index ["decided_by_id"], name: "index_approvals_on_decided_by_id"
    t.index ["invocation_id"], name: "index_approvals_on_invocation_id", unique: true
  end

  create_table "bot_revisions", force: :cascade do |t|
    t.integer "bot_id", null: false
    t.text "instructions", null: false
    t.string "model", null: false
    t.json "tool_names", default: [], null: false
    t.datetime "created_at", null: false
    t.index ["bot_id"], name: "index_bot_revisions_on_bot_id"
  end

  create_table "bots", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "name", null: false
    t.text "instructions", null: false
    t.string "model", null: false
    t.string "thinking_level", default: "medium", null: false
    t.string "time_zone", default: "UTC", null: false
    t.json "tool_names", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_bots_on_user_id"
  end

  create_table "conversations", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "bot_id", null: false
    t.string "request_id", null: false
    t.string "durable_id", null: false
    t.string "title", default: "", null: false
    t.string "status", default: "idle", null: false
    t.string "definition_digest"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "last_entry_id"
    t.string "failure"
    t.index ["bot_id", "durable_id"], name: "index_conversations_on_bot_id_and_durable_id", unique: true
    t.index ["bot_id", "request_id"], name: "index_conversations_on_bot_id_and_request_id", unique: true
    t.index ["bot_id"], name: "index_conversations_on_bot_id"
    t.index ["user_id"], name: "index_conversations_on_user_id"
  end

  create_table "invocations", force: :cascade do |t|
    t.integer "conversation_id", null: false
    t.string "task_id", null: false
    t.string "call_id", null: false
    t.string "tool_name", null: false
    t.json "arguments", default: {}, null: false
    t.string "digest", null: false
    t.string "state", default: "pending", null: false
    t.json "result"
    t.string "error"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "task_id", "call_id"], name: "index_invocations_on_conversation_id_and_task_id_and_call_id", unique: true
    t.index ["conversation_id"], name: "index_invocations_on_conversation_id"
  end

  create_table "messages", force: :cascade do |t|
    t.integer "conversation_id", null: false
    t.string "entry_key", null: false
    t.integer "entry_id", null: false
    t.string "role", null: false
    t.text "content", default: "", null: false
    t.string "tool_name"
    t.string "tool_call_id"
    t.json "tool_calls", default: [], null: false
    t.boolean "error", default: false, null: false
    t.datetime "created_at", null: false
    t.index ["conversation_id", "entry_key"], name: "index_messages_on_conversation_id_and_entry_key", unique: true
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
  end

  create_table "notes", force: :cascade do |t|
    t.integer "bot_id", null: false
    t.string "key", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bot_id", "key"], name: "index_notes_on_bot_id_and_key", unique: true
    t.index ["bot_id"], name: "index_notes_on_bot_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "oidc_sub", null: false
    t.string "name", default: "", null: false
    t.string "email", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["oidc_sub"], name: "index_users_on_oidc_sub", unique: true
  end

  add_foreign_key "answers", "invocations"
  add_foreign_key "answers", "users", column: "decided_by_id"
  add_foreign_key "approvals", "invocations"
  add_foreign_key "approvals", "users", column: "decided_by_id"
  add_foreign_key "bot_revisions", "bots"
  add_foreign_key "bots", "users"
  add_foreign_key "conversations", "bots"
  add_foreign_key "conversations", "users"
  add_foreign_key "invocations", "conversations"
  add_foreign_key "messages", "conversations"
  add_foreign_key "notes", "bots"
end
