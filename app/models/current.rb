class Current < ActiveSupport::CurrentAttributes
  attribute :user
  # The verified email that signed in. It is the user's own, except where an
  # install has an owner (ACCESS__OWNER_EMAIL), whom everyone signs in as:
  # admission and the admins' console go by who signed in, not by the owner.
  attribute :email

  def admin? = Admission.admin?(email)
end
