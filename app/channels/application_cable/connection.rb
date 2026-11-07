module ApplicationCable
  # Turbo's stream names are signed, so nobody can subscribe to a stream they
  # were not given; the connection is also refused without a signed-in, still
  # admitted person.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      user_id = cookies.encrypted[Rails.application.config.session_options[:key]]&.dig("user_id")
      user = User.find_by(id: user_id) # tenancy-ok: the session cookie names the person
      self.current_user = (user if user && Admission.admits?(user.email)) || reject_unauthorized_connection
    end
  end
end
