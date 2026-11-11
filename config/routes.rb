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
  resource :development_session, only: :create if Rails.env.development?
  get "rails/components", to: "components#show", as: :components if Rails.env.local?

  # Settings, as a Mac's System Settings: you, the models, the connectors,
  # then each agent's sections, every one an existing or nested resource
  # rendered in the settings layout. /settings itself is the list a phone
  # starts from.
  resource :settings, only: :show
  namespace :settings do
    resource :account, only: %i[ show update ]
    # Which kinds of notification the person wants, from You.
    resource :notifications, only: :update
  end
  # Notifications on this browser, turned on in Settings (You), and the person's other devices.
  namespace :push do
    resources :subscriptions, only: %i[ create destroy ] do
      resource :test, only: :create, module: :subscriptions
    end
  end
  # What the phone's Share sheet hands the installed app (the manifest's share_target), then "Share with…".
  resources :shares, only: %i[ create show ]

  # An agent's own page is its settings' General section.
  # The address a new agent would get, shown as its name is typed.
  namespace :agents do
    resource :address, only: :show
  end
  resources :agents, only: %i[ new create show update destroy ] do
    scope module: "agents" do
      resource :instructions, only: %i[ show update ]
      # One switch per tool, for this agent alone, by the name it declares.
      resources :tools, only: %i[ index update ], param: :name, constraints: { name: %r{[^/]+} }, format: false
      resources :skills, except: :show
      # Commands: the saved prompts.
      resources :prompts, except: :show
      resources :routines, only: %i[ index update destroy ]
      resources :permissions, only: %i[ index destroy ]
      resource :computer, only: %i[ show update ] do
        # Over SSH: the person's key, and trusting the machine's host key.
        resource :host_key, only: %i[ show create ], module: "computers"
      end
      # Email, phone, Concourse and Campfire.
      resource :channels, only: :show
      resource :phone_number, only: :update
      resource :calendar_account, only: :update
      # Joining Concourse goes to its page and back to /concourse/callback;
      # disconnecting retires the agent there.
      resource :concourse_join, only: %i[ new create ]
      resources :concourse_agents, only: :destroy
      # Its Concourse tasks still open, both ways.
      resources :peer_tasks, only: :index, path: "tasks"
      resource :campfire_bot, only: %i[ create update destroy ] do
        resource :token, only: :create, module: "campfire_bots"
      end
    end
  end
  resources :conversations, only: %i[ index show ] do
    resources :messages, only: :index, module: "conversations"
    # A reply read as it arrived, on the open thread (reading_controller).
    resource :reading, only: :create, module: "conversations"
    resources :submissions, only: :create
    # A message waiting for the agent: made a steer or a follow-up, or taken back.
    resources :queued_messages, only: %i[ update destroy ], module: "conversations"
    resources :cancellations, only: :create
    resources :compactions, only: :create, module: "conversations"
    resource :export, only: :show, module: "conversations"
    resource :archive, only: %i[ create destroy ], module: "conversations"
    # The page and, at the same address, the websocket it opens.
    resource :screen, only: :show, module: "conversations"
    # The conversation's own connectors and the person's, as this conversation uses them.
    resources :connectors, only: :index, module: "conversations"
    # The canvas: the agent's documents, opened beside its thread (closed, at
    # the index). A person's save, restoring an old version and downloading
    # are each a resource.
    resources :documents, only: %i[ index show update ], module: "conversations" do
      scope module: "documents" do
        resources :versions, only: :index
        resources :restorations, only: :create
        resource :download, only: :show
      end
    end
    resources :invocations, only: [], module: "conversations/invocations" do
      resource :approval, only: :create
      resource :answer, only: :create
      resource :sign_in, only: :create
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
  post "concourse/:id/push", to: "concourse_pushes#create", as: :concourse_push

  namespace :sidecar, path: "agent" do
    resources :accesses, only: :create
    resources :invocations, only: :create
    resources :frames, only: :create
    resources :syncs, only: :create
    resources :sign_ins, only: :create
    resources :files, only: :create
    resources :uploads, only: :create
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # The icon, in the accent: /icons/app.png and the rest (Icon::VARIANTS), and
  # the two addresses browsers and iPhones ask for without being told.
  resources :icons, only: :show, constraints: { id: Regexp.union(Icon::VARIANTS.keys), format: /png|svg|ico/ }
  get "favicon.ico" => "icons#show", defaults: { id: "favicon", format: "ico" }
  get "apple-touch-icon.png" => "icons#show", defaults: { id: "apple-touch", format: "png" }

  # A Hotwire Native app's path configuration: which screens open as a modal.
  resources :configurations, only: :show, constraints: { id: /ios_v1|android_v1/ }, defaults: { format: :json }
end
