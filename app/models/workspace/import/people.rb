# The copy's people. Both installs sign in through the same provider, so a
# person is the one here with the same sign-in subject, whatever their email
# is now, who keeps their own settings; anyone not here comes as they were.
# All become members of the workspace, and the owner named its owner.
class Workspace::Import::People
  TABLE = Workspace::Import::Table.new("users", User,
    drop: { "ssh_keyring" => "an SSH key held by the other install's sidecar; a person's computers here use their agents' own" })

  def self.here(row) = row["oidc_sub"].present? ? User.find_by(oidc_sub: row["oidc_sub"]) : nil # tenancy-ok: the one person here with this sign-in

  # Someone else here with this person's email: one email cannot be two people.
  def self.other(row) = row["email"].present? ? User.where("lower(email) = ?", row["email"].downcase).where.not(oidc_sub: row["oidc_sub"]).first : nil # tenancy-ok: whether this email is someone else's here

  # The copy's person who owns the workspace: the one with this email, or its first.
  def self.owner(source, email)
    rows = []
    source.each("users") { rows << it }
    email.present? ? rows.find { it["email"].to_s.casecmp?(email) } : rows.first
  end

  def initialize(run)
    @run = run
  end

  def bring(owner:)
    owner = self.class.owner(@run.source, owner)
    @run.owner = owner["id"]
    @run.ids("users")
    @run.source.each("users") do |row|
      if (person = self.class.here(row)) then @run.matched(row["id"], person)
      else TABLE.copy_row(row, @run)
      end
      @run.workspace.memberships.find_or_create_by!(user_id: @run.id("users", row["id"])) { it.role = row["id"] == owner["id"] ? "owner" : "member" }
    end
  end
end
