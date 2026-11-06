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
    resources :mcp_servers, only: %i[ create destroy ], module: "bots" do
      resource :refresh, only: :create, module: "mcp_servers"
    end
  end
  resources :conversations, only: :show do
    resources :submissions, only: :create
    resources :cancellations, only: :create
    resources :forks, only: :create, module: "conversations"
    resources :invocations, only: [], module: "conversations/invocations" do
      resource :approval, only: :create
      resource :answer, only: :create
    end
  end

  # Connecting the bots' Claude subscription, once, by an admitted person.
  resource :claude_subscription, only: %i[ show destroy ] do
    resource :login, only: %i[ create update ], module: "claude_subscriptions"
  end

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
