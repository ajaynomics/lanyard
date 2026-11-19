Rails.application.routes.draw do
  # Another name for the app (APP__REDIRECTS) serves nothing but a redirect to
  # its own address, before sign-in or anything else answers.
  constraints(->(request) { DurableAssistants.redirect_hosts.include?(request.host) }) do
    match "(*path)", via: :all, format: false,
      to: redirect(status: 302) { |_params, request| "#{DurableAssistants.config(:app, :url).to_s.delete_suffix("/")}#{request.fullpath}" }
  end

  # The person's agents, one row each, their threads.
  root "conversations#index"

  get "sign_in", to: "sessions#new", as: :sign_in
  # OmniAuth's middleware answers this POST; the route only names the path.
  post "auth/ajent", as: :ajent_auth, to: ->(_env) { [ 404, {}, [] ] }
  get "auth/ajent/callback", to: "sessions#create"
  get "auth/failure", to: "sessions#failure"
  delete "sign_out", to: "sessions#destroy", as: :sign_out
  # The phone app's sign-in: begun in its browser sheet, finished in its web view (NativeSignIn).
  resource :native_sign_in, only: %i[ new create ]
  resource :development_session, only: :create if Rails.env.development?
  get "rails/components", to: "components#show", as: :components if Rails.env.local?

  # Settings, as a Mac's System Settings: you, notifications, Apple Watch,
  # the models, the connectors, then each agent's sections, every one an
  # existing or nested resource rendered in the settings layout. /settings
  # itself is the list a phone starts from; as JSON, the phone app's Settings
  # tab draws its rows from it.
  # Workspaces: Settings lists the person's own and shared ones; a person
  # makes a shared one, and renames any they are in, their own too. Its page
  # lists its people. The one a person used last (Current.workspace), where New
  # agent starts, is one they belong to. Only its owner invites, removes and cancels, and hands it to
  # a member (their membership's ownership); a member leaves.
  # Its Usage is every member's to see; whose account pays, its owner's to choose.
  # Its owner routes outside contacts to its agents; each member may choose
  # the one agent that alone contacts them.
  # Every workspace the person is in on one page: what needs them or is
  # broken, each a link to where it is dealt with. Before the resources, so
  # "overview" is not read as a workspace's id.
  namespace :workspaces do
    resource :overview, only: :show
  end
  resources :workspaces, only: %i[ index show new create edit update ] do
    # Its connectors and helpers, from its group's menu in the agents list: the address says whose they are.
    resources :connectors, only: :index
    resources :helpers, only: :index
    scope module: :workspaces do
      resources :memberships, only: :destroy do
        resource :ownership, only: :create
      end
      resources :invitations, only: %i[ create destroy ]
      # The size its agents' Sprites are made with, set by its owner.
      resource :computer_size, only: :update
      resource :usage, only: :show
      resource :payer, only: :update
      # Which of its agents' calls ask a person first, chosen by its owner.
      resource :approval_policy, only: :update
      # Its own vault user and install connector keys, for its owner alone; members see only whether each is set.
      resource :vault_user, only: %i[ edit update destroy ]
      resources :install_connectors, only: %i[ edit update destroy ]
      # Its Concourse home network and its own Campfire, for its owner alone.
      resource :concourse_network, only: :update
      resource :campfire, only: %i[ update destroy ]
      # Its own voip.ms account, named by its owner alone as a vault entry.
      resource :voipms_account, only: %i[ update destroy ]
      resources :contact_routes, only: %i[ create destroy ]
      resource :sole_contact, only: :update
      # Its own name and colour on its people's pages, set by its owner (Brand).
      resource :brand, only: :update
      # Its shared instructions, which every agent of it follows: its owner
      # changes them, and accepts or declines what a member proposes.
      resource :instructions, only: :update
      resources :proposals, only: %i[ create destroy ] do
        resource :acceptance, only: :create, module: :proposals
      end
    end
  end

  resource :settings, only: :show
  namespace :settings do
    resource :account, only: %i[ show update ]
    # Notifications on this device, and which kinds the person wants.
    resource :notifications, only: %i[ show update ]
    # The person's Apple Watches, each revoked at /watches/:id.
    resources :watches, only: :index
    # Invitations to every shared workspace waiting for an admin's yes before
    # the install emails them; an admin approves or declines each.
    resources :invitations, only: %i[ index destroy ] do
      resource :approval, only: :create, module: :invitations
    end
    # Their own Link wallet, for payments by one-time card: connecting starts
    # Link's device sign-in, and updating says the person entered its phrase.
    resource :wallet, only: %i[ show create update destroy ]
  end
  # Notifications on this browser, turned on in Settings (Notifications), and the person's other devices.
  namespace :push do
    resources :subscriptions, only: %i[ create destroy ] do
      resource :test, only: :create, module: :subscriptions
    end
    # The phone app's notifications (Apple's push service), by the token iOS gave it. Forgetting one is
    # Sign out's (its token in the body): a token in a path would be in the log.
    resources :devices, only: :create
    # What became of a Turn on in the phone app, or why iOS gave it no token (Push::Attempt).
    resources :attempts, only: :create
  end
  # A token for the phone to hand its Watch, and revoking one from Settings (Apple Watch).
  resources :watches, only: %i[ create destroy ]
  # The helpers every agent of the person's has working, then those that ended
  # lately; each agent's own are under it (agents/helpers).
  resources :helpers, only: :index
  # Every card waiting on the person, across their agents (the phone app's Needs you), each opened to answer.
  resources :approvals, only: %i[ index show ]
  # What the phone's Share sheet hands the installed app (the manifest's share_target), then "Share with…".
  resources :shares, only: %i[ create show ]

  # An agent's own page is its settings' General section.
  # The address a new agent would get, shown as its name is typed.
  namespace :agents do
    resource :address, only: :show
  end
  resources :agents, only: %i[ new create show update destroy ] do
    scope module: "agents" do
      # Paused (create) and resumed (destroy) by the person.
      resource :pause, only: %i[ create destroy ]
      # Moved to another of the person's workspaces, by its workspace's owner (Agent::Movable).
      resource :move, only: %i[ new create ]
      resource :instructions, only: %i[ show update ]
      # One switch per tool, for this agent alone, by the name it declares.
      resources :tools, only: %i[ index update ], param: :name, constraints: { name: %r{[^/]+} }, format: false
      # One of the person's connectors, core for this agent or looked up, by its id.
      resources :core_connectors, only: :update
      # A skill is a folder: uploaded, or installed from GitHub and pinned to
      # a commit. One with programs waits for a person's review.
      resources :skills do
        scope module: "skills" do
          resource :approval, only: :create
          resource :rejection, only: :create
          resource :update, only: %i[ show create ]
        end
      end
      resources :github_skills, only: :create
      # Commands: the saved prompts.
      resources :prompts, except: :show
      resources :routines, only: %i[ index update destroy ]
      resources :permissions, only: %i[ index destroy ]
      resource :computer, only: %i[ show update ] do
        # Over SSH: the person's key, and trusting the machine's host key.
        resource :host_key, only: %i[ show create ], module: "computers"
        # A Sprite's own size, over its workspace's, set by the workspace's owner.
        resource :size, only: :update, module: "computers"
      end
      # Email, phone, Concourse and Campfire.
      resource :channels, only: :show
      resource :phone_number, only: :update
      resource :calendar_account, only: :update
      resource :linked_calendar, only: %i[ update destroy ]
      # Its own mail account and forced Bcc, for the workspace's owner alone.
      resource :mail_account, only: %i[ update destroy ]
      resource :calendar_server, only: %i[ update destroy ]
      # Mailboxes and calendar servers it only reads, such as a colleague's, for the workspace's owner alone.
      resources :mailboxes, only: %i[ create destroy ]
      resources :read_only_calendars, only: %i[ create destroy ]
      # When its mail to people outside the install may go, for the workspace's owner alone.
      resource :sending_hours, only: %i[ update destroy ]
      # Whether its cards are priority notifications, for the workspace's owner alone.
      resource :priority_notifications, only: :update
      # Joining Concourse goes to its page and back to /concourse/callback;
      # disconnecting retires the agent there. One outside the workspace's home
      # network, a bridge, speaks once the workspace's owner approves it.
      resource :concourse_join, only: %i[ new create ]
      resources :concourse_agents, only: :destroy do
        resource :bridge_approval, only: :create, module: "concourse_agents"
      end
      # Its Concourse tasks still open, both ways.
      resources :peer_tasks, only: :index, path: "tasks"
      # Its helpers working in the background, then those that ended lately.
      resources :helpers, only: :index
      resource :campfire_bot, only: %i[ create update destroy ] do
        resource :token, only: :create, module: "campfire_bots"
      end
      resource :telegram_bot, only: %i[ update destroy ]
    end
  end
  resources :conversations, only: %i[ index show ] do
    resources :messages, only: :index, module: "conversations"
    # A reply read as it arrived, on the open thread (reading_controller).
    resource :reading, only: :create, module: "conversations"
    resources :submissions, only: :create
    # A message waiting for the agent: made a steer or a follow-up, moved, or taken back.
    resources :queued_messages, only: %i[ update destroy ], module: "conversations" do
      resource :position, only: :update, module: "queued_messages"
    end
    # A message held while the agent is paused, dropped.
    resources :held_messages, only: :destroy, module: "conversations"
    resources :cancellations, only: :create
    # A person's Cancel for a helper working in the background, and their words for it.
    resources :helpers, only: :destroy, module: "conversations" do
      resources :messages, only: :create, module: "helpers"
    end
    # A person's Cancel for a workflow's run, every step of it.
    resources :workflow_runs, only: :destroy, module: "conversations"
    # A person's Cancel for mail held for its agent's sending hours.
    resources :held_emails, only: :destroy, module: "conversations"
    # A person's Revoke for a link an agent made for someone outside (SignInLink).
    resources :sign_in_links, only: :destroy, module: "conversations"
    resources :compactions, only: :create, module: "conversations"
    resource :export, only: :show, module: "conversations"
    resource :archive, only: %i[ create destroy ], module: "conversations"
    # The page and, at the same address, the websocket it opens.
    resource :screen, only: :show, module: "conversations"
    # One-time links to it, for someone not signed in here (ScreenPass).
    resources :screen_passes, only: %i[ create destroy ], module: "conversations"
    # The conversation's own connectors and the person's, as this conversation uses them.
    resources :connectors, only: :index, module: "conversations"
    # The canvas: the agent's documents, listed, made and opened beside its
    # thread. A person's save, restoring an old version, downloading and
    # deleting are each a resource; a deleted document is restored from
    # Recently deleted until it is purged (Document::Deletable).
    resources :documents, only: %i[ index show new create update ], module: "conversations" do
      scope module: "documents" do
        resources :versions, only: :index
        resources :restorations, only: :create
        resource :download, only: :show
        resource :deletion, only: :create
      end
    end
    resources :deleted_documents, only: :index, module: "conversations" do
      scope module: "deleted_documents" do
        resource :restoration, only: :create
      end
    end
    resources :invocations, only: [], module: "conversations/invocations" do
      resource :approval, only: :create
      resource :answer, only: :create
      resource :sign_in, only: :create
      # Taking a payment back, before or after Link approved it (PaymentRequest#cancel!).
      resource :payment, only: :destroy
      # A person saying whether a text still unknown went (Dispatch#close).
      resource :dispatch, only: :update
    end
  end

  # Connectors (MCP servers): the person's own, for every conversation, and each
  # conversation's (conversation_id); one sign-in for both. The services' sign-in
  # pages send the person back to the one fixed callback address.
  get "connectors/callback", to: "connectors/callbacks#show", as: :connectors_callback
  get "connectors/client", to: "connectors/clients#show", as: :connectors_client, defaults: { format: :json }
  # Concourse sends the person back here after they approve or cancel a join.
  get "concourse/callback", to: "concourse_callbacks#show", as: :concourse_callback
  resources :connectors, only: %i[ index show create update destroy ] do
    scope module: "connectors" do
      resource :sign_in, only: %i[ create destroy ]
      resource :refresh, only: :create
      # One switch per tool, for every agent, by the name the server lists it under.
      resources :tools, only: :update, param: :name, constraints: { name: %r{[^/]+} }, format: false
    end
  end
  # One of the install's connectors (wiki, CRM) turned on in the workspace, by name.
  resources :office_connectors, only: :create

  # Connecting the agents' subscriptions (Claude, ChatGPT), once each, by an
  # admitted person, and the Claude API key beside them
  # (/subscriptions/anthropic-api/key). The Claude-only console's address
  # still leads here.
  resources :subscriptions, only: %i[ index destroy ], param: :provider do
    resource :login, only: %i[ create update ], module: "subscriptions"
    resource :key, only: %i[ update destroy ], module: "subscriptions"
  end
  get "claude_subscription", to: redirect("/subscriptions")

  # The sidecar's private callbacks: bearer-token transport, no CSRF. The
  # sidecar calls these addresses, so the path stays /agent/ whatever the module is called.
  # Campfire posts each message for an agent's bot here; the token admits it.
  post "campfire/:token", to: "campfire_webhooks#create", as: :campfire_webhook
  post "telegram/:id", to: "telegram_webhooks#create", as: :telegram_webhook
  post "concourse/:id/push", to: "concourse_pushes#create", as: :concourse_push

  namespace :sidecar, path: "agent" do
    resources :accesses, only: :create
    resources :invocations, only: :create
    resources :frames, only: :create
    resources :syncs, only: :create
    resources :sign_ins, only: :create
    resources :cards, only: :create
    resources :files, only: :create
    resources :uploads, only: :create
    resources :helpers, only: :create
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check
  # A one-time link to a conversation's screen, opened without a sign-in
  # (ScreenPass), and its visitor's Done.
  resources :screen_passes, only: %i[ show destroy ], param: :token

  # A one-time link for someone outside to fill one empty saved sign-in,
  # opened without a sign-in (SignInLink): the form, and its one submit.
  resources :sign_in_links, only: :show, param: :token do
    resource :fill, only: :create, module: "sign_in_links"
  end

  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # The icon, in the accent: /icons/app.png and the rest (Icon::VARIANTS), and
  # the two addresses browsers and iPhones ask for without being told.
  resources :icons, only: :show, constraints: { id: Regexp.union(Icon::VARIANTS.keys), format: /png|svg|ico/ }
  get "favicon.ico" => "icons#show", defaults: { id: "favicon", format: "ico" }
  get "apple-touch-icon.png" => "icons#show", defaults: { id: "apple-touch", format: "png" }

  # A Hotwire Native app's path configuration (PathConfiguration): which screens open as a sheet.
  resources :configurations, only: :show, constraints: { id: Regexp.union(PathConfiguration::VERSIONS.keys) }, defaults: { format: :json }
end
