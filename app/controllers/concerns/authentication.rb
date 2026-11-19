# Every page needs a signed-in person unless it says otherwise. The session
# holds the user id and the verified email that signed in; Ajent proved who
# they are at sign-in. Nothing else identifies anyone: no header, no address,
# no origin. The one exception is a Watch's own token (Watch), which opens
# only the few JSON actions that name it, and never with a session.
module Authentication
  extend ActiveSupport::Concern

  NOT_ADMITTED = "That account is not set up here.".freeze

  included do
    before_action :require_sign_in
    helper_method :signed_in?
    class_attribute :watch_actions, default: []
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_sign_in, **options
    end

    # The actions a Watch may call with its token, as JSON.
    def allow_watch_access(only:)
      self.watch_actions = Array(only).map(&:to_s)
    end
  end

  private
    def signed_in? = Current.user.present?

    # main_app, because Active Storage's controllers include this too
    # (config/initializers/active_storage.rb) and have no route helpers of ours.
    def require_sign_in
      return authenticate_watch if watch_request?
      Current.user = User.find_by(id: session[:user_id]) if session[:user_id] # tenancy-ok: the session names the signed-in person
      # A session naming someone who is gone is ended, or the sign-in page,
      # seeing it, would send the browser back here, and round again.
      reset_session if session[:user_id] && !Current.user
      Current.email = session[:email] || Current.user&.email
      # Asked on every request, from what was stored at sign-in, so taking
      # someone off the list ends their session without a call to Ajent.
      if Current.user && !Admission.admits?(Current.email)
        Current.user = nil
        reset_session
        return head :unauthorized if request.format.json? || hotwire_native_app?
        return redirect_to main_app.sign_in_path, alert: NOT_ADMITTED, status: :see_other
      end
      return enter_workspace if Current.user
      # A native app asking for data is told, not sent to a page it cannot read.
      # The phone app's pages are told too: it opens its own sign-in sheet over
      # every tab, then starts the tabs afresh (Phone/SceneController.swift).
      return head :unauthorized if request.format.json? || hotwire_native_app?
      session[:return_to] = request.fullpath if request.get? || request.head?
      redirect_to main_app.sign_in_path, status: :see_other
    end

    # A Watch's request: a Bearer token, for an action that allows it, as JSON.
    # Its token alone decides, whatever cookie came too, and it starts no
    # session. Anywhere else a token is no one, as any other header is.
    def authenticate_watch
      watch = Watch.find_by_token(watch_token) # tenancy-ok: the token names its one Watch
      return head :unauthorized unless watch && Admission.admits?(watch.user.email)
      request.session_options[:skip] = true
      watch.used!
      Current.user = watch.user
      Current.email = watch.user.email
      Current.workspace = watch.user.personal_workspace
    end

    # The session's workspace while the person still belongs to it; otherwise
    # their personal one, which the session then names.
    def enter_workspace(workspace = Current.user.workspace_for(session[:workspace_id]))
      Current.workspace = workspace
      session[:workspace_id] = workspace.id
    end

    # The request's agent, thread or card, in whichever of the person's
    # workspaces it is: being in that workspace is what lets them reach it, not
    # which one the session last showed. The phone keeps a page per tab and
    # answers notices from every workspace, so a request about another one is
    # ordinary. The request works in the record's workspace; only a page they
    # open makes it the one they work in. One they are not in is not found.
    def find_in_workspace(records, id)
      Current.user.public_send(records).find(id).tap { work_in it.workspace }
    end

    # A request works in the workspace its record or its address names; a page the person opens there makes it the
    # one they last used, where New agent starts.
    def work_in(workspace)
      opening_a_page? ? enter_workspace(workspace) : Current.workspace = workspace
    end

    # Not a change, Turbo fetching ahead of a click, a frame filling in, or the
    # Watch, whose token reaches all the person's workspaces at once.
    def opening_a_page?
      request.get? && request.headers["X-Sec-Purpose"] != "prefetch" && !turbo_frame_request? && !watch_request?
    end

    # Where a list finds its threads and cards: the workspace the person works
    # in, or for a Watch, every workspace of theirs, since a notice from any of
    # them reaches their phone and so their wrist.
    def reach = watch_request? ? Current.user : Current.workspace

    def watch_request? = watch_token.present? && action_name.in?(watch_actions) && request.format.json?

    def watch_token = request.authorization.to_s[/\ABearer (\S+)\z/, 1]

    # A token is not a cookie a browser sends by itself, so another site
    # cannot borrow it: Rails' forgery check has nothing to guard.
    def verified_request? = watch_request? || super

    # Who signed in, once the provider (or the development button) has said
    # so. In the browser sheet of the phone's app (NativeSignIn) it goes back
    # to the app as a one-time code and starts no session in the sheet;
    # anywhere else it starts a session here, in the workspace they were
    # just invited to, if any.
    def complete_sign_in(user, email:, workspace: nil)
      pending = session.delete(:native_sign_in)
      if pending.is_a?(Hash) && pending["until"].to_i > Time.current.to_i && NativeSignIn.challenge?(pending["challenge"])
        redirect_to NativeSignIn.return_url(user, email: email, challenge: pending["challenge"]), allow_other_host: true # turbo-ok: identity providers return the browser here by GET
      else
        start_session_for user, email: email, workspace: workspace
      end
    end

    def start_session_for(user, email:, workspace: nil)
      return_to = session[:return_to]
      reset_session
      session[:user_id] = user.id
      session[:email] = email
      session[:workspace_id] = workspace.id if workspace
      ahoy.authenticate(user)
      # The phone app signs in from its sign-in sheet: Hotwire Native's refresh closes the sheet, and the app starts
      # its tabs afresh, signed in (Phone/SceneController.swift). A browser goes to the page it asked for.
      refresh_or_redirect_to safe_return_path(return_to) # turbo-ok: identity providers return the browser here by GET
    end

    def safe_return_path(path)
      path.is_a?(String) && path.start_with?("/") && !path.start_with?("//") ? path : root_path
    end
end
