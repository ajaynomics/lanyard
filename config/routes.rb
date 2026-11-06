Rails.application.routes.draw do
  # Pi Durable: browser resources for an authorised workspace, with CSRF.
  scope "workspaces/:workspace_id", as: :workspace do
    namespace :agent do
      resources :conversations, only: %i[index show create] do
        resource :snapshot, only: :show
        resources :submissions, only: :create
        resources :cancellations, only: :create
        resources :inputs, only: [], constraints: { id: %r{[^/]+} } do
          resource :answer, only: :create
        end
      end
    end
  end

  # Pi Durable: private sidecar callbacks, bearer-token transport, no CSRF.
  namespace :agent do
    resources :accesses, only: :create
    resources :effects, only: :create
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
