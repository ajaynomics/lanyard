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

ActiveRecord::Schema[8.2].define(version: 2026_11_07_160100) do
  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

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
    t.json "capabilities", default: [], null: false
    t.json "skills", default: [], null: false
    t.json "prompts", default: [], null: false
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
    t.json "capabilities", default: ["codemode", "subagents", "web_search"], null: false
    t.index ["user_id"], name: "index_bots_on_user_id"
  end

  create_table "computers", force: :cascade do |t|
    t.integer "bot_id", null: false
    t.string "provider", default: "local", null: false
    t.string "name", null: false
    t.string "state", default: "off", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "notes_file", default: true, null: false
    t.index ["bot_id"], name: "index_computers_on_bot_id", unique: true
  end

  create_table "concourse_agents", force: :cascade do |t|
    t.integer "bot_id", null: false
    t.string "organization", null: false
    t.string "handle", null: false
    t.string "client_id", null: false
    t.text "client_secret", null: false
    t.string "cursor"
    t.datetime "checked_at"
    t.string "check_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bot_id"], name: "index_concourse_agents_on_bot_id", unique: true
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
    t.json "usage"
    t.integer "parent_id"
    t.integer "forked_at_entry_id"
    t.integer "notes_file_bytes"
    t.datetime "archived_at"
    t.datetime "last_message_at"
    t.integer "root_id"
    t.integer "branches_count", default: 0, null: false
    t.index ["bot_id", "archived_at", "last_message_at"], name: "index_conversations_for_listing"
    t.index ["bot_id", "durable_id"], name: "index_conversations_on_bot_id_and_durable_id", unique: true
    t.index ["bot_id", "request_id"], name: "index_conversations_on_bot_id_and_request_id", unique: true
    t.index ["bot_id"], name: "index_conversations_on_bot_id"
    t.index ["parent_id"], name: "index_conversations_on_parent_id"
    t.index ["root_id"], name: "index_conversations_on_root_id"
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

  create_table "mcp_servers", force: :cascade do |t|
    t.integer "bot_id"
    t.string "name", null: false
    t.string "url"
    t.text "token"
    t.json "tools", default: [], null: false
    t.datetime "refreshed_at"
    t.string "refresh_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.integer "conversation_id"
    t.boolean "enabled", default: true, null: false
    t.text "headers"
    t.string "oauth_scope"
    t.text "oauth_client"
    t.text "oauth_tokens"
    t.text "oauth_pending"
    t.string "oauth_state"
    t.index ["bot_id"], name: "index_mcp_servers_on_bot_id"
    t.index ["conversation_id", "name"], name: "index_mcp_servers_on_conversation_id_and_name", unique: true, where: "conversation_id IS NOT NULL"
    t.index ["conversation_id"], name: "index_mcp_servers_on_conversation_id"
    t.index ["oauth_state"], name: "index_mcp_servers_on_oauth_state", unique: true
    t.index ["user_id", "name"], name: "index_mcp_servers_on_user_id_and_name", unique: true, where: "conversation_id IS NULL"
    t.index ["user_id"], name: "index_mcp_servers_on_user_id"
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
    t.text "thinking"
    t.json "usage"
    t.index ["conversation_id", "entry_id"], name: "index_messages_on_conversation_id_and_entry_id"
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

  create_table "peer_tasks", force: :cascade do |t|
    t.integer "conversation_id", null: false
    t.string "task_id", null: false
    t.string "context_id"
    t.string "peer", null: false
    t.string "direction", null: false
    t.string "state", null: false
    t.json "delivered_ids", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "task_id"], name: "index_peer_tasks_on_conversation_id_and_task_id", unique: true
    t.index ["conversation_id"], name: "index_peer_tasks_on_conversation_id"
    t.index ["task_id"], name: "index_peer_tasks_on_task_id"
  end

  create_table "prompts", force: :cascade do |t|
    t.integer "bot_id", null: false
    t.string "name", null: false
    t.string "description", default: "", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bot_id", "name"], name: "index_prompts_on_bot_id_and_name", unique: true
    t.index ["bot_id"], name: "index_prompts_on_bot_id"
  end

  create_table "skills", force: :cascade do |t|
    t.integer "bot_id", null: false
    t.string "name", null: false
    t.string "description", limit: 1024, null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bot_id", "name"], name: "index_skills_on_bot_id_and_name", unique: true
    t.index ["bot_id"], name: "index_skills_on_bot_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "oidc_sub", null: false
    t.string "name", default: "", null: false
    t.string "email", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["oidc_sub"], name: "index_users_on_oidc_sub", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "answers", "invocations"
  add_foreign_key "answers", "users", column: "decided_by_id"
  add_foreign_key "approvals", "invocations"
  add_foreign_key "approvals", "users", column: "decided_by_id"
  add_foreign_key "bot_revisions", "bots"
  add_foreign_key "bots", "users"
  add_foreign_key "computers", "bots"
  add_foreign_key "concourse_agents", "bots"
  add_foreign_key "conversations", "bots"
  add_foreign_key "conversations", "conversations", column: "parent_id", on_delete: :nullify
  add_foreign_key "conversations", "conversations", column: "root_id", on_delete: :nullify
  add_foreign_key "conversations", "users"
  add_foreign_key "invocations", "conversations"
  add_foreign_key "mcp_servers", "bots"
  add_foreign_key "mcp_servers", "conversations"
  add_foreign_key "mcp_servers", "users"
  add_foreign_key "messages", "conversations"
  add_foreign_key "notes", "bots"
  add_foreign_key "peer_tasks", "conversations"
  add_foreign_key "prompts", "bots"
  add_foreign_key "skills", "bots"
end
