# Agents that rewrote their own instructions copied the identity the app puts
# above them (Agent#identity), so they read it twice. Agent now drops a leading
# copy on save; this drops the ones already saved. Each agent it changes gets a
# revision of the new text, as any change does; the old text is the revision
# before it, or one recorded here first when there is none.
#
# Plain SQL and a copy of the pattern, frozen as they are today, so later
# changes to Agent can't change what this did.
class StripIdentityFromInstructions < ActiveRecord::Migration[8.2]
  IDENTITY_HEADER = /\A\s*(?:(?:Your name is [^\n]+\. Neither can be changed\.|Your title is [^\n]+\.|Your phone number is [^\n]+; you text from it with send_text\.)[ \t]*(?:\n\s*|\z))+/

  def up
    select_rows("SELECT id, instructions, model, tool_names, capabilities FROM agents ORDER BY id").each do |id, instructions, model, tool_names, capabilities|
      stripped = instructions.sub(IDENTITY_HEADER, "")
      next if stripped == instructions || stripped.blank?

      latest = select_one("SELECT instructions, skills, prompts FROM agent_revisions WHERE agent_id = #{Integer(id)} ORDER BY id DESC LIMIT 1")
      snapshot = { model: model, tool_names: tool_names, capabilities: capabilities,
                   skills: latest&.fetch("skills") || "[]", prompts: latest&.fetch("prompts") || "[]" }
      record_revision(id, instructions, **snapshot) unless latest&.fetch("instructions") == instructions
      update "UPDATE agents SET instructions = #{quote(stripped)}, updated_at = #{quote(Time.current)} WHERE id = #{Integer(id)}"
      record_revision(id, stripped, **snapshot)
    end
  end

  def down
    # The text before is in each agent's revisions.
  end

  private
    def record_revision(agent_id, instructions, **snapshot)
      values = { agent_id: agent_id, instructions: instructions, **snapshot, created_at: Time.current }
      insert "INSERT INTO agent_revisions (#{values.keys.join(', ')}) VALUES (#{values.values.map { quote(it) }.join(', ')})"
    end
end
