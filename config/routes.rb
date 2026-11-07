Rails.application.routes.draw do
  root "bots#index"

  get "sign_in", to: "sessions#new", as: :sign_in
  # OmniAuth's middleware answers this POST; the route only names the path.
  post "auth/ajent", as: :ajent_auth, to: ->(_env) { [ 404, {}, [] ] }
  get "auth/ajent/callback", to: "sessions#create"
  get "auth/failure", to: "sessions#failure"
  delete "sign_out", to: "sessions#destroy", as: :sign_out
  resource :development_session, only: :create if Rails.env.development?

  resources :bots, only: %i[ index show edit update ] do
    resources :conversations, only: %i[ index create ]
    resource :computer, only: :update, module: "bots"
    resource :concourse_agent, only: %i[ update destroy ], module: "bots"
    # Listed on the bot's settings page, which is their index.
    resources :prompts, :skills, module: "bots", except: %i[ index show ]
  end
  resources :conversations, only: %i[ show update ] do
    resources :submissions, only: :create
    resources :cancellations, only: :create
    resources :forks, only: :create, module: "conversations"
    resources :compactions, only: :create, module: "conversations"
    resource :export, only: :show, module: "conversations"
    resource :tree, only: :show, module: "conversations"
    resource :archive, only: %i[ create destroy ], module: "conversations"
    # The page and, at the same address, the websocket it opens.
    resource :screen, only: :show, module: "conversations"
    # The agent's own connectors and the person's, as this agent uses them.
    resources :connectors, only: :index, module: "conversations"
    resources :invocations, only: [], module: "conversations/invocations" do
      resource :approval, only: :create
      resource :answer, only: :create
    end
  end

  # Connectors (MCP servers): the person's own, for every agent, and each
  # agent's (conversation_id); one sign-in for both. The services' sign-in
  # pages send the person back to the one fixed callback address.
  get "connectors/callback", to: "connectors/callbacks#show", as: :connectors_callback
  resources :connectors, only: %i[ index create update destroy ] do
    scope module: "connectors" do
      resource :sign_in, only: %i[ create destroy ]
      resource :refresh, only: :create
    end
  end

  # Connecting the bots' subscriptions (Claude, ChatGPT), once each, by an
  # admitted person, and the Claude API key beside them
  # (/subscriptions/anthropic-api/key). The Claude-only console's address
  # still leads here.
  resources :subscriptions, only: %i[ index destroy ], param: :provider do
    resource :login, only: %i[ create update ], module: "subscriptions"
    resource :key, only: %i[ update destroy ], module: "subscriptions"
  end
  get "claude_subscription", to: redirect("/subscriptions")

  # The sidecar's private callbacks: bearer-token transport, no CSRF.
  namespace :agent do
    resources :accesses, only: :create
    resources :invocations, only: :create
    resources :frames, only: :create
    resources :syncs, only: :create
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
end
