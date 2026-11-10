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

ActiveRecord::Schema[8.2].define(version: 2026_11_11_020000) do
  create_table "action_mailbox_inbound_emails", force: :cascade do |t|
    t.integer "status", default: 0, null: false
    t.string "message_id", null: false
    t.string "message_checksum", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id", "message_checksum"], name: "index_action_mailbox_inbound_emails_uniqueness", unique: true
  end

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

  create_table "agent_revisions", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.text "instructions", null: false
    t.string "model", null: false
    t.json "tool_names", default: [], null: false
    t.datetime "created_at", null: false
    t.json "capabilities", default: [], null: false
    t.json "skills", default: [], null: false
    t.json "prompts", default: [], null: false
    t.index ["agent_id"], name: "index_agent_revisions_on_agent_id"
  end

  create_table "agents", force: :cascade do |t|
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
    t.string "email_name", null: false
    t.json "disabled_tools", default: [], null: false
    t.string "title"
    t.text "passbolt_private_key"
    t.text "passbolt_passphrase"
    t.string "phone_number"
    t.string "caldav_username"
    t.text "caldav_password"
    t.index ["email_name"], name: "index_agents_on_email_name", unique: true
    t.index ["phone_number"], name: "index_agents_on_phone_number", unique: true
    t.index ["user_id"], name: "index_agents_on_user_id"
  end

  create_table "ahoy_events", force: :cascade do |t|
    t.integer "visit_id"
    t.integer "user_id"
    t.string "name"
    t.json "properties"
    t.datetime "time"
    t.index ["name", "time"], name: "index_ahoy_events_on_name_and_time"
    t.index ["user_id"], name: "index_ahoy_events_on_user_id"
    t.index ["visit_id"], name: "index_ahoy_events_on_visit_id"
  end

  create_table "ahoy_visits", force: :cascade do |t|
    t.string "visit_token"
    t.string "visitor_token"
    t.integer "user_id"
    t.string "ip"
    t.text "user_agent"
    t.text "referrer"
    t.string "referring_domain"
    t.text "landing_page"
    t.string "browser"
    t.string "os"
    t.string "device_type"
    t.string "utm_source"
    t.string "utm_medium"
    t.string "utm_term"
    t.string "utm_content"
    t.string "utm_campaign"
    t.datetime "started_at"
    t.index ["user_id"], name: "index_ahoy_visits_on_user_id"
    t.index ["visit_token"], name: "index_ahoy_visits_on_visit_token", unique: true
    t.index ["visitor_token", "started_at"], name: "index_ahoy_visits_on_visitor_token_and_started_at"
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

  create_table "campfire_bots", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.json "askers", default: {}, null: false
    t.string "bot_key", null: false
    t.string "token", null: false
    t.json "rooms", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "confirmed_at"
    t.index ["agent_id"], name: "index_campfire_bots_on_agent_id", unique: true
    t.index ["token"], name: "index_campfire_bots_on_token", unique: true
  end

  create_table "campfire_rooms", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "held_at"
    t.json "relayed_at", default: [], null: false
    t.integer "room_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "room_id"], name: "index_campfire_rooms_on_user_id_and_room_id", unique: true
    t.index ["user_id"], name: "index_campfire_rooms_on_user_id"
  end

  create_table "computers", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.string "provider", default: "local", null: false
    t.string "name", null: false
    t.string "state", default: "off", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "notes_file", default: true, null: false
    t.string "ssh_host"
    t.string "ssh_user"
    t.string "folder"
    t.index ["agent_id"], name: "index_computers_on_agent_id", unique: true
  end

  create_table "concourse_agents", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.string "organization", null: false
    t.string "handle", null: false
    t.string "client_id", null: false
    t.text "client_secret", null: false
    t.string "cursor"
    t.datetime "checked_at"
    t.string "check_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "push_token"
    t.string "status", default: "admitted", null: false
    t.index ["agent_id"], name: "index_concourse_agents_on_agent_id", unique: true
  end

  create_table "conversations", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "agent_id", null: false
    t.string "request_id", null: false
    t.string "durable_id"
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
    t.json "activated_tools", default: [], null: false
    t.datetime "stalled_at"
    t.datetime "read_at"
    t.datetime "replied_at"
    t.string "current_tool"
    t.datetime "listed_at", null: false
    t.date "dated_on"
    t.datetime "error_told_at"
    t.index ["agent_id", "archived_at", "last_message_at"], name: "index_conversations_for_listing"
    t.index ["agent_id", "durable_id"], name: "index_conversations_on_agent_id_and_durable_id", unique: true
    t.index ["agent_id", "request_id"], name: "index_conversations_on_agent_id_and_request_id", unique: true
    t.index ["agent_id"], name: "index_conversations_one_thread_per_agent", unique: true, where: "parent_id IS NULL"
    t.index ["parent_id"], name: "index_conversations_on_parent_id"
    t.index ["root_id"], name: "index_conversations_on_root_id"
    t.index ["user_id", "listed_at"], name: "index_conversations_on_user_id_and_listed_at"
    t.index ["user_id"], name: "index_conversations_on_user_id"
  end

  create_table "document_versions", force: :cascade do |t|
    t.integer "document_id", null: false
    t.integer "number", null: false
    t.text "body", null: false
    t.string "author", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["document_id", "number"], name: "index_document_versions_on_document_id_and_number", unique: true
    t.index ["document_id"], name: "index_document_versions_on_document_id"
  end

  create_table "documents", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.string "title", null: false
    t.string "kind", default: "markdown", null: false
    t.string "language"
    t.integer "seen_version_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "title"], name: "index_documents_on_agent_id_and_title", unique: true
    t.index ["agent_id"], name: "index_documents_on_agent_id"
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
    t.json "preview"
    t.index ["conversation_id", "task_id", "call_id"], name: "index_invocations_on_conversation_id_and_task_id_and_call_id", unique: true
    t.index ["conversation_id"], name: "index_invocations_on_conversation_id"
  end

  create_table "mcp_servers", force: :cascade do |t|
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
    t.string "command"
    t.json "args", default: [], null: false
    t.text "env"
    t.string "cwd"
    t.boolean "sign_in_needed", default: false, null: false
    t.string "oauth_app"
    t.string "install"
    t.boolean "loaded", default: true, null: false
    t.json "disabled_tools", default: [], null: false
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
    t.json "calls"
    t.integer "call_count"
    t.index ["conversation_id", "entry_id"], name: "index_messages_on_conversation_id_and_entry_id"
    t.index ["conversation_id", "entry_key"], name: "index_messages_on_conversation_id_and_entry_key", unique: true
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
  end

  create_table "notes", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.string "key", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "key"], name: "index_notes_on_agent_id_and_key", unique: true
    t.index ["agent_id"], name: "index_notes_on_agent_id"
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

  create_table "permissions", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.string "tool_name", null: false
    t.string "recipient", default: "", null: false
    t.integer "granted_by_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "tool_name", "recipient"], name: "index_permissions_on_agent_id_and_tool_name_and_recipient", unique: true
    t.index ["agent_id"], name: "index_permissions_on_agent_id"
    t.index ["granted_by_id"], name: "index_permissions_on_granted_by_id"
  end

  create_table "prompts", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.string "name", null: false
    t.string "description", default: "", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "name"], name: "index_prompts_on_agent_id_and_name", unique: true
    t.index ["agent_id"], name: "index_prompts_on_agent_id"
  end

  create_table "push_subscriptions", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "endpoint", null: false
    t.string "p256dh_key", null: false
    t.string "auth_key", null: false
    t.string "user_agent", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["endpoint"], name: "index_push_subscriptions_on_endpoint", unique: true
    t.index ["user_id"], name: "index_push_subscriptions_on_user_id"
  end

  create_table "routines", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.string "schedule", null: false
    t.text "prompt", null: false
    t.datetime "next_run_at"
    t.datetime "last_run_at"
    t.datetime "paused_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_routines_on_agent_id"
    t.index ["next_run_at"], name: "index_routines_on_next_run_at"
  end

  create_table "shares", force: :cascade do |t|
    t.integer "user_id", null: false
    t.text "text", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_shares_on_created_at"
    t.index ["user_id"], name: "index_shares_on_user_id"
  end

  create_table "skills", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.string "name", null: false
    t.string "description", limit: 1024, null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "name"], name: "index_skills_on_agent_id_and_name", unique: true
    t.index ["agent_id"], name: "index_skills_on_agent_id"
  end

  create_table "uploads", force: :cascade do |t|
    t.integer "conversation_id", null: false
    t.string "task_id", null: false
    t.string "call_id", null: false
    t.string "path", null: false
    t.string "sha256", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "task_id", "call_id", "path"], name: "idx_on_conversation_id_task_id_call_id_path_d4a9ead9e1", unique: true
    t.index ["conversation_id"], name: "index_uploads_on_conversation_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "oidc_sub", null: false
    t.string "name", default: "", null: false
    t.string "email", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "ssh_keyring"
    t.boolean "push_messages", default: true, null: false
    t.boolean "push_needs_you", default: true, null: false
    t.boolean "push_errors", default: true, null: false
    t.index ["oidc_sub"], name: "index_users_on_oidc_sub", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "agent_revisions", "agents"
  add_foreign_key "agents", "users"
  add_foreign_key "ahoy_events", "ahoy_visits", column: "visit_id", on_delete: :nullify
  add_foreign_key "ahoy_events", "users", on_delete: :nullify
  add_foreign_key "ahoy_visits", "users", on_delete: :nullify
  add_foreign_key "answers", "invocations"
  add_foreign_key "answers", "users", column: "decided_by_id"
  add_foreign_key "approvals", "invocations"
  add_foreign_key "approvals", "users", column: "decided_by_id"
  add_foreign_key "campfire_bots", "agents"
  add_foreign_key "campfire_rooms", "users"
  add_foreign_key "computers", "agents"
  add_foreign_key "concourse_agents", "agents"
  add_foreign_key "conversations", "agents"
  add_foreign_key "conversations", "conversations", column: "parent_id", on_delete: :nullify
  add_foreign_key "conversations", "conversations", column: "root_id", on_delete: :nullify
  add_foreign_key "conversations", "users"
  add_foreign_key "document_versions", "documents"
  add_foreign_key "documents", "agents"
  add_foreign_key "invocations", "conversations"
  add_foreign_key "mcp_servers", "conversations"
  add_foreign_key "mcp_servers", "users"
  add_foreign_key "messages", "conversations"
  add_foreign_key "notes", "agents"
  add_foreign_key "peer_tasks", "conversations"
  add_foreign_key "permissions", "agents"
  add_foreign_key "permissions", "users", column: "granted_by_id"
  add_foreign_key "prompts", "agents"
  add_foreign_key "push_subscriptions", "users"
  add_foreign_key "routines", "agents"
  add_foreign_key "shares", "users"
  add_foreign_key "skills", "agents"
  add_foreign_key "uploads", "conversations"
end
