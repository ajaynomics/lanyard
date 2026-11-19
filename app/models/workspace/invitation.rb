# An email the owner of a shared workspace invited. Once an admin of the
# install (ACCESS__ADMINS) says yes, the inviter's own being one, or another's
# in Settings, it admits the email (Admission) and the install emails it:
# who comes in, and what the install sends to someone outside it, are the
# install's to decide. It admits until it becomes a membership, when that
# person signs in with the email verified, or is cancelled.
class Workspace::Invitation < ApplicationRecord
  # An install that serves one person (Admission.owner) signs everyone in as
  # them, so an invitation there would make nobody a member: it invites nobody.
  REFUSED_FOR_ONE_OWNER = "Inviting people needs single-owner mode off.".freeze

  belongs_to :workspace
  belongs_to :inviter, class_name: "User"
  belongs_to :approver, class_name: "User", optional: true

  scope :approved, -> { where.not(approved_at: nil) }
  scope :awaiting_approval, -> { where(approved_at: nil) }

  normalizes :email, with: -> { it.strip.downcase }

  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, uniqueness: { scope: :workspace, message: "is already invited" }
  validate :not_a_member, :not_for_one_owner, on: :create

  # Someone who has already signed in with this email, verified, and is still
  # let in, joins at once rather than at their next sign-in, which may be weeks away.
  def invitee = User.find_by("lower(email) = ?", email) # tenancy-ok: the one person whose verified email this is

  def approve(by:)
    update!(approver: by, approved_at: Time.current)
    WorkspaceMailer.invitation(self).deliver_later if WorkspaceMailer.delivers?
  end

  def awaiting_approval? = approved_at.nil?

  def refused_for_one_owner? = errors.added?(:base, REFUSED_FOR_ONE_OWNER)

  # Accepted, it became a membership and is no invitation any more.
  def accepted? = destroyed?

  # The person signed in with this email: a member from now on.
  def accept(user)
    transaction do
      workspace.memberships.find_or_create_by!(user: user) { it.role = "member" }
      destroy!
    end
  end

  private
    def not_a_member
      errors.add(:email, "is already a member") if workspace.members.exists?(email: email)
    end

    def not_for_one_owner
      errors.add(:base, REFUSED_FOR_ONE_OWNER) if Admission.owner
    end
end
