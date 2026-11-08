module ApplicationCable
  # Turbo's stream names are signed, so nobody can subscribe to a stream they
  # were not given; the connection is also refused without a signed-in, still
  # admitted person.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      session = cookies.encrypted[Rails.application.config.session_options[:key]] || {}
      user = User.find_by(id: session["user_id"]) # tenancy-ok: the session cookie names the person
      self.current_user = (user if user && Admission.admits?(session["email"] || user.email)) || reject_unauthorized_connection
    end
  end
end
