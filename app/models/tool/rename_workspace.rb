# Renames a shared workspace, as its page's Rename does, for anyone in it.
class Tool::RenameWorkspace < Tool
  include Tool::WorkspaceCalls

  description "Rename a shared workspace, when your person asks. A personal workspace goes by its person's name."
  argument :workspace, :string, required: false, max_length: 100, description: "Its name now, as list_workspaces gives it. Left out, yours."
  argument :name, :string, min_length: 1, max_length: 100, description: "Its new name."
  asks :approval, always: false

  def approval_title(arguments) = "Rename #{target(arguments)} to #{arguments["name"].to_s.squish}?"

  def call(name:, workspace: nil)
    target = check
    was = target.to_s
    target.update(name: name.squish)
    refuse_unless_saved(target)
    { renamed: was, to: target.name }
  end

  private
    def check
      workspace_named(arguments["workspace"]).tap do |workspace|
        raise Tool::Refusal, "#{workspace} is #{workspace.owner}'s own workspace, which goes by its person's name." if workspace.personal?
      end
    end

    def target(arguments) = arguments["workspace"].presence || agent.workspace
end
