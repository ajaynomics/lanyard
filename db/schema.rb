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

ActiveRecord::Schema[8.2].define(version: 2026_11_19_040000) do
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

  create_table "agent_calendar_servers", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.string "url", null: false
    t.string "vault_entry", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "read_only", default: false, null: false
    t.index ["agent_id", "url"], name: "index_agent_calendar_servers_on_agent_id_and_url", unique: true
    t.index ["agent_id"], name: "index_agent_calendar_servers_writable", unique: true, where: "NOT read_only"
  end

  create_table "agent_mail_account_folders", force: :cascade do |t|
    t.integer "mail_account_id", null: false
    t.string "name", null: false
    t.integer "validity"
    t.integer "last_uid", default: 0, null: false
    t.datetime "read_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["mail_account_id", "name"], name: "index_agent_mail_account_folders_on_mail_account_id_and_name", unique: true
  end

  create_table "agent_mail_accounts", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.string "address", null: false
    t.string "display_name"
    t.string "smtp_host"
    t.integer "smtp_port", default: 587, null: false
    t.string "imap_host"
    t.integer "imap_port", default: 993, null: false
    t.string "vault_entry", null: false
    t.string "forced_bcc"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "inbox_validity"
    t.integer "inbox_last_uid", default: 0, null: false
    t.datetime "inbox_read_at"
    t.string "inbox_error"
    t.boolean "read_only", default: false, null: false
    t.string "folder_names"
    t.boolean "primary", default: false, null: false
    t.index ["agent_id", "address"], name: "index_agent_mail_accounts_on_agent_id_and_address", unique: true
    t.index ["agent_id"], name: "index_agent_mail_accounts_sending", unique: true, where: "NOT read_only"
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
    t.integer "mail_to_agent_id"
    t.boolean "asks_every_email", default: false, null: false
    t.boolean "asks_every_text", default: false, null: false
    t.boolean "asks_every_imessage", default: false, null: false
    t.boolean "asks_every_concourse_send", default: false, null: false
    t.boolean "promotes_found_tools", default: false, null: false
    t.datetime "paused_at"
    t.datetime "resumed_at"
    t.string "linked_calendar_server"
    t.string "linked_calendar"
    t.string "linked_calendar_entry"
    t.integer "workspace_id", null: false
    t.string "send_from"
    t.string "send_until"
    t.string "send_time_zone"
    t.boolean "asks_every_instruction_change", default: true, null: false
    t.string "claude_route"
    t.boolean "priority_notifications", default: true, null: false
    t.index ["email_name"], name: "index_agents_on_email_name", unique: true
    t.index ["mail_to_agent_id"], name: "index_agents_on_mail_to_agent_id"
    t.index ["phone_number"], name: "index_agents_on_phone_number", unique: true
    t.index ["user_id"], name: "index_agents_on_user_id"
    t.index ["workspace_id"], name: "index_agents_on_workspace_id"
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
    t.string "ssh_keyring"
    t.datetime "held_at"
    t.integer "cpus"
    t.integer "memory_mib"
    t.integer "disk_mib"
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
    t.integer "bridge_approved_by_id"
    t.datetime "bridge_approved_at"
    t.index ["agent_id", "organization"], name: "index_concourse_agents_on_agent_id_and_organization", unique: true
    t.index ["bridge_approved_by_id"], name: "index_concourse_agents_on_bridge_approved_by_id"
  end

  create_table "connector_moves", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.integer "mcp_server_id"
    t.string "connector_name", null: false
    t.string "reason", null: false
    t.datetime "created_at", null: false
    t.index ["agent_id"], name: "index_connector_moves_on_agent_id"
    t.index ["mcp_server_id"], name: "index_connector_moves_on_mcp_server_id"
  end

  create_table "conversation_submissions", force: :cascade do |t|
    t.integer "conversation_id", null: false
    t.string "request_id", null: false
    t.string "input_digest", null: false
    t.string "payload_digest", null: false
    t.string "definition_digest", null: false
    t.text "payload"
    t.json "context", default: {}, null: false
    t.string "durable_id"
    t.json "receipt"
    t.datetime "accepted_at"
    t.datetime "acknowledged_at"
    t.datetime "compacted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "request_id"], name: "idx_on_conversation_id_request_id_10dc5d00ac", unique: true
    t.index ["conversation_id"], name: "index_conversation_submissions_on_conversation_id"
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
    t.string "execution_status", default: "idle", null: false
    t.json "metered_usage"
    t.index ["agent_id", "archived_at", "last_message_at"], name: "index_conversations_for_listing"
    t.index ["agent_id", "durable_id"], name: "index_conversations_on_agent_id_and_durable_id", unique: true
    t.index ["agent_id", "request_id"], name: "index_conversations_on_agent_id_and_request_id", unique: true
    t.index ["agent_id"], name: "index_conversations_one_thread_per_agent", unique: true, where: "parent_id IS NULL"
    t.index ["parent_id"], name: "index_conversations_on_parent_id"
    t.index ["root_id"], name: "index_conversations_on_root_id"
    t.index ["user_id", "listed_at"], name: "index_conversations_on_user_id_and_listed_at"
    t.index ["user_id"], name: "index_conversations_on_user_id"
  end

  create_table "core_connectors", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.integer "mcp_server_id", null: false
    t.datetime "created_at", null: false
    t.index ["agent_id", "mcp_server_id"], name: "index_core_connectors_on_agent_id_and_mcp_server_id", unique: true
    t.index ["mcp_server_id"], name: "index_core_connectors_on_mcp_server_id"
  end

  create_table "dispatches", force: :cascade do |t|
    t.integer "invocation_id", null: false
    t.string "key", null: false
    t.string "tool_name", null: false
    t.string "state", default: "pending", null: false
    t.string "sender", null: false
    t.string "fingerprint", null: false
    t.string "provider_id"
    t.integer "checks", default: 0, null: false
    t.datetime "settled_at"
    t.integer "closed_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["closed_by_id"], name: "index_dispatches_on_closed_by_id"
    t.index ["fingerprint"], name: "index_dispatches_on_fingerprint"
    t.index ["invocation_id"], name: "index_dispatches_on_invocation_id", unique: true
    t.index ["key"], name: "index_dispatches_on_key", unique: true
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
    t.datetime "deleted_at"
    t.string "deleted_by"
    t.index ["agent_id", "title"], name: "index_documents_on_agent_id_and_title", unique: true, where: "deleted_at IS NULL"
    t.index ["agent_id"], name: "index_documents_on_agent_id"
    t.index ["deleted_at"], name: "index_documents_on_deleted_at"
  end

  create_table "held_emails", force: :cascade do |t|
    t.integer "conversation_id", null: false
    t.integer "invocation_id", null: false
    t.datetime "send_at", null: false
    t.string "state", default: "held", null: false
    t.datetime "sent_at"
    t.string "error"
    t.integer "cancelled_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cancelled_by_id"], name: "index_held_emails_on_cancelled_by_id"
    t.index ["conversation_id"], name: "index_held_emails_on_conversation_id"
    t.index ["invocation_id"], name: "index_held_emails_on_invocation_id", unique: true
    t.index ["state", "send_at"], name: "index_held_emails_on_state_and_send_at"
  end

  create_table "helpers", force: :cascade do |t|
    t.integer "conversation_id", null: false
    t.string "call_id", null: false
    t.text "task", null: false
    t.string "state", default: "running", null: false
    t.text "answer"
    t.string "reason"
    t.json "calls", default: [], null: false
    t.integer "call_count", default: 0, null: false
    t.json "usage"
    t.datetime "finished_at"
    t.datetime "delivered_at"
    t.datetime "told_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.json "messages", default: [], null: false
    t.string "model"
    t.string "thinking_level"
    t.index ["conversation_id", "call_id"], name: "index_helpers_on_conversation_id_and_call_id", unique: true
    t.index ["conversation_id"], name: "index_helpers_on_conversation_id"
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
    t.datetime "handed_back_at"
    t.datetime "claimed_at"
    t.datetime "started_at"
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
    t.boolean "install_core"
    t.boolean "loaded", default: true, null: false
    t.json "disabled_tools", default: [], null: false
    t.boolean "asks_every_write", default: false, null: false
    t.integer "workspace_id", null: false
    t.string "vault_entry"
    t.index ["conversation_id", "name"], name: "index_mcp_servers_on_conversation_id_and_name", unique: true, where: "conversation_id IS NOT NULL"
    t.index ["conversation_id"], name: "index_mcp_servers_on_conversation_id"
    t.index ["oauth_state"], name: "index_mcp_servers_on_oauth_state", unique: true
    t.index ["user_id"], name: "index_mcp_servers_on_user_id"
    t.index ["workspace_id", "name"], name: "index_mcp_servers_on_workspace_id_and_name", unique: true, where: "conversation_id IS NULL"
    t.index ["workspace_id"], name: "index_mcp_servers_on_workspace_id"
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
    t.string "request_id"
    t.integer "author_id"
    t.string "sender"
    t.index ["conversation_id", "entry_id"], name: "index_messages_on_conversation_id_and_entry_id"
    t.index ["conversation_id", "entry_key"], name: "index_messages_on_conversation_id_and_entry_key", unique: true
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
  end

  create_table "model_usages", force: :cascade do |t|
    t.integer "workspace_id", null: false
    t.integer "agent_id"
    t.string "agent_name", null: false
    t.integer "conversation_id"
    t.integer "helper_id"
    t.integer "payer_id"
    t.string "model"
    t.string "tool"
    t.integer "input", default: 0, null: false
    t.integer "output", default: 0, null: false
    t.integer "cache_read", default: 0, null: false
    t.integer "cache_write", default: 0, null: false
    t.integer "total_tokens", default: 0, null: false
    t.decimal "cost", precision: 14, scale: 6
    t.datetime "created_at", null: false
    t.index ["agent_id"], name: "index_model_usages_on_agent_id"
    t.index ["conversation_id"], name: "index_model_usages_on_conversation_id"
    t.index ["helper_id"], name: "index_model_usages_on_helper_id"
    t.index ["payer_id"], name: "index_model_usages_on_payer_id"
    t.index ["workspace_id", "created_at"], name: "index_model_usages_on_workspace_id_and_created_at"
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

  create_table "payment_requests", force: :cascade do |t|
    t.integer "invocation_id", null: false
    t.string "state", default: "requested", null: false
    t.integer "amount", null: false
    t.string "currency", null: false
    t.string "payee", null: false
    t.string "checkout_url", null: false
    t.text "reason", null: false
    t.string "link_id"
    t.string "approval_url"
    t.datetime "expires_at"
    t.string "card_brand"
    t.string "card_last4"
    t.datetime "card_valid_until"
    t.datetime "filled_at"
    t.string "decided_by"
    t.string "failure"
    t.datetime "next_ask_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["invocation_id"], name: "index_payment_requests_on_invocation_id", unique: true
    t.index ["next_ask_at"], name: "index_payment_requests_on_next_ask_at"
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
    t.integer "concourse_agent_id"
    t.boolean "notes_followed", default: true, null: false
    t.index ["concourse_agent_id"], name: "index_peer_tasks_on_concourse_agent_id"
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

  create_table "push_attempts", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "outcome", null: false
    t.integer "code"
    t.string "user_agent", default: "", null: false
    t.datetime "created_at", null: false
    t.index ["user_id"], name: "index_push_attempts_on_user_id"
  end

  create_table "push_devices", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "token", null: false
    t.string "environment", default: "production", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "session_digest"
    t.index ["token"], name: "index_push_devices_on_token", unique: true
    t.index ["user_id"], name: "index_push_devices_on_user_id"
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
    t.datetime "once_at"
    t.index ["agent_id"], name: "index_routines_on_agent_id"
    t.index ["next_run_at"], name: "index_routines_on_next_run_at"
  end

  create_table "screen_passes", force: :cascade do |t|
    t.integer "conversation_id", null: false
    t.integer "created_by_id", null: false
    t.string "token_digest", null: false
    t.string "viewer_digest"
    t.datetime "expires_at", null: false
    t.datetime "opened_at"
    t.datetime "ended_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id"], name: "index_screen_passes_on_conversation_id"
    t.index ["created_by_id"], name: "index_screen_passes_on_created_by_id"
    t.index ["token_digest"], name: "index_screen_passes_on_token_digest", unique: true
  end

  create_table "shares", force: :cascade do |t|
    t.integer "user_id", null: false
    t.text "text", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "submission_request_id"
    t.index ["created_at"], name: "index_shares_on_created_at"
    t.index ["user_id"], name: "index_shares_on_user_id"
  end

  create_table "sign_in_links", force: :cascade do |t|
    t.integer "conversation_id", null: false
    t.integer "invocation_id", null: false
    t.integer "revoked_by_id"
    t.string "entry_id", null: false
    t.string "name", null: false
    t.string "token_digest", null: false
    t.datetime "expires_at", null: false
    t.datetime "used_at"
    t.string "outcome"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id"], name: "index_sign_in_links_on_conversation_id"
    t.index ["invocation_id"], name: "index_sign_in_links_on_invocation_id"
    t.index ["revoked_by_id"], name: "index_sign_in_links_on_revoked_by_id"
    t.index ["token_digest"], name: "index_sign_in_links_on_token_digest", unique: true
  end

  create_table "skill_bundled_files", force: :cascade do |t|
    t.integer "skill_id", null: false
    t.string "path", null: false
    t.binary "content", null: false
    t.integer "size", null: false
    t.boolean "executable", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["skill_id", "path"], name: "index_skill_bundled_files_on_skill_id_and_path", unique: true
  end

  create_table "skills", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.string "name", null: false
    t.string "description", limit: 1024, null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "state", default: "ready", null: false
    t.string "github_repo"
    t.string "github_path"
    t.string "github_ref"
    t.string "github_sha"
    t.index ["agent_id", "name"], name: "index_skills_on_agent_id_and_name", unique: true
    t.index ["agent_id"], name: "index_skills_on_agent_id"
  end

  create_table "telegram_bots", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.string "vault_entry", null: false
    t.string "username"
    t.string "webhook_secret", null: false
    t.json "chats", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_telegram_bots_on_agent_id", unique: true
  end

  create_table "telegram_messages", force: :cascade do |t|
    t.integer "telegram_bot_id", null: false
    t.bigint "chat_id", null: false
    t.bigint "message_id", null: false
    t.string "sender", null: false
    t.text "text", null: false
    t.datetime "sent_at", null: false
    t.datetime "created_at", null: false
    t.index ["telegram_bot_id", "chat_id", "message_id"], name: "idx_on_telegram_bot_id_chat_id_message_id_e45a71d9af", unique: true
    t.index ["telegram_bot_id", "chat_id", "sent_at"], name: "idx_on_telegram_bot_id_chat_id_sent_at_8985ae4aa1"
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
    t.text "link_session"
    t.index ["oidc_sub"], name: "index_users_on_oidc_sub", unique: true
  end

  create_table "watches", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "name", null: false
    t.string "token_digest", null: false
    t.datetime "last_used_at"
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["token_digest"], name: "index_watches_on_token_digest", unique: true
    t.index ["user_id"], name: "index_watches_on_user_id"
  end

  create_table "workflow_runs", force: :cascade do |t|
    t.integer "workflow_id", null: false
    t.string "call_id", null: false
    t.string "state", default: "running", null: false
    t.datetime "finished_at"
    t.datetime "delivered_at"
    t.datetime "told_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["state"], name: "index_workflow_runs_on_state"
    t.index ["workflow_id", "call_id"], name: "index_workflow_runs_on_workflow_id_and_call_id", unique: true
    t.index ["workflow_id"], name: "index_workflow_runs_on_workflow_id"
  end

  create_table "workflow_steps", force: :cascade do |t|
    t.integer "run_id", null: false
    t.integer "position", null: false
    t.string "call_id", null: false
    t.text "task", null: false
    t.text "context"
    t.string "state", default: "pending", null: false
    t.text "answer"
    t.string "reason"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "model"
    t.string "thinking_level"
    t.index ["call_id"], name: "index_workflow_steps_on_call_id", unique: true
    t.index ["run_id", "position"], name: "index_workflow_steps_on_run_id_and_position", unique: true
    t.index ["run_id"], name: "index_workflow_steps_on_run_id"
  end

  create_table "workflows", force: :cascade do |t|
    t.integer "conversation_id", null: false
    t.string "name", null: false
    t.string "kind", null: false
    t.json "steps", default: [], null: false
    t.text "context"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id"], name: "index_workflows_on_conversation_id"
  end

  create_table "workspace_campfire_rooms", force: :cascade do |t|
    t.integer "workspace_id", null: false
    t.integer "room_id", null: false
    t.datetime "held_at"
    t.json "relayed_at", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["workspace_id", "room_id"], name: "index_workspace_campfire_rooms_on_workspace_id_and_room_id", unique: true
  end

  create_table "workspace_contact_routes", force: :cascade do |t|
    t.integer "workspace_id", null: false
    t.integer "agent_id", null: false
    t.string "contact", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_workspace_contact_routes_on_agent_id"
    t.index ["workspace_id", "contact"], name: "index_workspace_contact_routes_on_workspace_id_and_contact", unique: true
  end

  create_table "workspace_imports", force: :cascade do |t|
    t.integer "workspace_id", null: false
    t.string "source_digest", null: false
    t.string "source_version", null: false
    t.json "report", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["source_digest"], name: "index_workspace_imports_on_source_digest", unique: true
    t.index ["workspace_id"], name: "index_workspace_imports_on_workspace_id", unique: true
  end

  create_table "workspace_install_connectors", force: :cascade do |t|
    t.integer "workspace_id", null: false
    t.string "name", null: false
    t.string "url"
    t.text "api_key", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["workspace_id", "name"], name: "index_workspace_install_connectors_on_workspace_id_and_name", unique: true
  end

  create_table "workspace_invitations", force: :cascade do |t|
    t.integer "workspace_id", null: false
    t.integer "inviter_id", null: false
    t.string "email", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "approved_at"
    t.integer "approver_id"
    t.index ["approver_id"], name: "index_workspace_invitations_on_approver_id"
    t.index ["email"], name: "index_workspace_invitations_on_email"
    t.index ["inviter_id"], name: "index_workspace_invitations_on_inviter_id"
    t.index ["workspace_id", "email"], name: "index_workspace_invitations_on_workspace_id_and_email", unique: true
    t.index ["workspace_id"], name: "index_workspace_invitations_on_workspace_id"
  end

  create_table "workspace_mail_domains", force: :cascade do |t|
    t.integer "workspace_id", null: false
    t.string "domain", null: false
    t.string "smtp_host", null: false
    t.integer "smtp_port", default: 587, null: false
    t.string "imap_host"
    t.integer "imap_port", default: 993, null: false
    t.string "vault_entry", null: false
    t.integer "inbox_validity"
    t.integer "inbox_last_uid", default: 0, null: false
    t.datetime "inbox_read_at"
    t.string "inbox_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_workspace_mail_domains_on_domain", unique: true
    t.index ["workspace_id"], name: "index_workspace_mail_domains_on_workspace_id", unique: true
  end

  create_table "workspace_memberships", force: :cascade do |t|
    t.integer "workspace_id", null: false
    t.integer "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "role", default: "owner", null: false
    t.integer "sole_contact_id"
    t.string "phone_number"
    t.index ["sole_contact_id"], name: "index_workspace_memberships_on_sole_contact_id"
    t.index ["user_id"], name: "index_workspace_memberships_on_user_id"
    t.index ["workspace_id", "user_id"], name: "index_workspace_memberships_on_workspace_id_and_user_id", unique: true
    t.index ["workspace_id"], name: "index_workspace_memberships_on_workspace_id"
    t.index ["workspace_id"], name: "index_workspace_memberships_one_owner", unique: true, where: "role = 'owner'"
  end

  create_table "workspace_proposals", force: :cascade do |t|
    t.integer "workspace_id", null: false
    t.integer "proposed_by_id", null: false
    t.text "instructions", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["proposed_by_id"], name: "index_workspace_proposals_on_proposed_by_id"
    t.index ["workspace_id"], name: "index_workspace_proposals_on_workspace_id"
  end

  create_table "workspace_revisions", force: :cascade do |t|
    t.integer "workspace_id", null: false
    t.text "instructions", null: false
    t.integer "changed_by_id"
    t.integer "proposed_by_id"
    t.integer "proposed_by_agent_id"
    t.datetime "created_at", null: false
    t.index ["changed_by_id"], name: "index_workspace_revisions_on_changed_by_id"
    t.index ["proposed_by_agent_id"], name: "index_workspace_revisions_on_proposed_by_agent_id"
    t.index ["proposed_by_id"], name: "index_workspace_revisions_on_proposed_by_id"
    t.index ["workspace_id"], name: "index_workspace_revisions_on_workspace_id"
  end

  create_table "workspaces", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "name"
    t.boolean "personal", default: false, null: false
    t.text "passbolt_private_key"
    t.text "passbolt_passphrase"
    t.string "concourse_home"
    t.string "campfire_url"
    t.string "campfire_vault_entry"
    t.integer "computer_cpus"
    t.integer "computer_memory_mib"
    t.integer "computer_disk_mib"
    t.integer "payer_id"
    t.text "instructions", default: "", null: false
    t.string "voipms_vault_entry"
    t.string "approval_policy"
    t.string "app_name"
    t.integer "accent_hue"
    t.string "link_host"
    t.index ["payer_id"], name: "index_workspaces_on_payer_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "agent_calendar_servers", "agents"
  add_foreign_key "agent_mail_account_folders", "agent_mail_accounts", column: "mail_account_id", on_delete: :cascade
  add_foreign_key "agent_mail_accounts", "agents"
  add_foreign_key "agent_revisions", "agents"
  add_foreign_key "agents", "agents", column: "mail_to_agent_id", on_delete: :nullify
  add_foreign_key "agents", "users"
  add_foreign_key "agents", "workspaces"
  add_foreign_key "ahoy_events", "ahoy_visits", column: "visit_id", on_delete: :nullify
  add_foreign_key "ahoy_events", "users", on_delete: :nullify
  add_foreign_key "ahoy_visits", "users", on_delete: :nullify
  add_foreign_key "answers", "invocations"
  add_foreign_key "answers", "users", column: "decided_by_id"
  add_foreign_key "approvals", "invocations"
  add_foreign_key "approvals", "users", column: "decided_by_id"
  add_foreign_key "campfire_bots", "agents"
  add_foreign_key "campfire_rooms", "users", on_delete: :cascade
  add_foreign_key "computers", "agents"
  add_foreign_key "concourse_agents", "agents"
  add_foreign_key "concourse_agents", "users", column: "bridge_approved_by_id", on_delete: :nullify
  add_foreign_key "connector_moves", "agents", on_delete: :cascade
  add_foreign_key "connector_moves", "mcp_servers", on_delete: :nullify
  add_foreign_key "conversation_submissions", "conversations", on_delete: :cascade
  add_foreign_key "conversations", "agents"
  add_foreign_key "conversations", "conversations", column: "parent_id", on_delete: :nullify
  add_foreign_key "conversations", "conversations", column: "root_id", on_delete: :nullify
  add_foreign_key "conversations", "users"
  add_foreign_key "core_connectors", "agents", on_delete: :cascade
  add_foreign_key "core_connectors", "mcp_servers", on_delete: :cascade
  add_foreign_key "dispatches", "invocations", on_delete: :cascade
  add_foreign_key "dispatches", "users", column: "closed_by_id", on_delete: :nullify
  add_foreign_key "document_versions", "documents"
  add_foreign_key "documents", "agents"
  add_foreign_key "held_emails", "conversations", on_delete: :cascade
  add_foreign_key "held_emails", "invocations", on_delete: :cascade
  add_foreign_key "held_emails", "users", column: "cancelled_by_id", on_delete: :nullify
  add_foreign_key "helpers", "conversations", on_delete: :cascade
  add_foreign_key "invocations", "conversations"
  add_foreign_key "mcp_servers", "conversations"
  add_foreign_key "mcp_servers", "users"
  add_foreign_key "mcp_servers", "workspaces"
  add_foreign_key "messages", "conversations"
  add_foreign_key "model_usages", "agents", on_delete: :nullify
  add_foreign_key "model_usages", "conversations", on_delete: :nullify
  add_foreign_key "model_usages", "helpers", on_delete: :nullify
  add_foreign_key "model_usages", "workspaces", column: "payer_id", on_delete: :nullify
  add_foreign_key "model_usages", "workspaces", on_delete: :cascade
  add_foreign_key "notes", "agents"
  add_foreign_key "payment_requests", "invocations"
  add_foreign_key "peer_tasks", "conversations"
  add_foreign_key "permissions", "agents"
  add_foreign_key "permissions", "users", column: "granted_by_id"
  add_foreign_key "prompts", "agents"
  add_foreign_key "push_attempts", "users", on_delete: :cascade
  add_foreign_key "push_devices", "users", on_delete: :cascade
  add_foreign_key "push_subscriptions", "users"
  add_foreign_key "routines", "agents"
  add_foreign_key "screen_passes", "conversations", on_delete: :cascade
  add_foreign_key "screen_passes", "users", column: "created_by_id", on_delete: :cascade
  add_foreign_key "shares", "users"
  add_foreign_key "sign_in_links", "conversations", on_delete: :cascade
  add_foreign_key "sign_in_links", "invocations", on_delete: :cascade
  add_foreign_key "sign_in_links", "users", column: "revoked_by_id", on_delete: :nullify
  add_foreign_key "skill_bundled_files", "skills", on_delete: :cascade
  add_foreign_key "skills", "agents"
  add_foreign_key "telegram_bots", "agents", on_delete: :cascade
  add_foreign_key "telegram_messages", "telegram_bots", on_delete: :cascade
  add_foreign_key "uploads", "conversations"
  add_foreign_key "watches", "users", on_delete: :cascade
  add_foreign_key "workflow_runs", "workflows", on_delete: :cascade
  add_foreign_key "workflow_steps", "workflow_runs", column: "run_id", on_delete: :cascade
  add_foreign_key "workflows", "conversations", on_delete: :cascade
  add_foreign_key "workspace_campfire_rooms", "workspaces", on_delete: :cascade
  add_foreign_key "workspace_contact_routes", "agents", on_delete: :cascade
  add_foreign_key "workspace_contact_routes", "workspaces", on_delete: :cascade
  add_foreign_key "workspace_imports", "workspaces", on_delete: :cascade
  add_foreign_key "workspace_install_connectors", "workspaces", on_delete: :cascade
  add_foreign_key "workspace_invitations", "users", column: "approver_id", on_delete: :nullify
  add_foreign_key "workspace_invitations", "users", column: "inviter_id"
  add_foreign_key "workspace_invitations", "workspaces"
  add_foreign_key "workspace_mail_domains", "workspaces", on_delete: :cascade
  add_foreign_key "workspace_memberships", "agents", column: "sole_contact_id", on_delete: :nullify
  add_foreign_key "workspace_memberships", "users"
  add_foreign_key "workspace_memberships", "workspaces"
  add_foreign_key "workspace_proposals", "users", column: "proposed_by_id", on_delete: :cascade
  add_foreign_key "workspace_proposals", "workspaces", on_delete: :cascade
  add_foreign_key "workspace_revisions", "agents", column: "proposed_by_agent_id", on_delete: :nullify
  add_foreign_key "workspace_revisions", "users", column: "changed_by_id", on_delete: :nullify
  add_foreign_key "workspace_revisions", "users", column: "proposed_by_id", on_delete: :nullify
  add_foreign_key "workspace_revisions", "workspaces", on_delete: :cascade
  add_foreign_key "workspaces", "workspaces", column: "payer_id", on_delete: :nullify
end
