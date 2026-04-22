Rails.application.routes.draw do
  devise_for :users

  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
    namespace :v1 do
      resources :patients, only: [:index, :show, :create, :update] do
        resources :visits,              only: [:index, :create]
        resources :medication_orders,   only: [:index, :create]
        resources :pharmacy_deliveries, only: [:index, :create]
        resources :dme_orders,          only: [:index, :create]
        resources :notes,               only: [:index, :create]
      end
      resources :medication_orders, only: [:show, :update] do
        resources :medication_logs, only: [:index, :create]
      end
      resources :pharmacy_deliveries, only: [:show, :update]
      resources :dme_orders,          only: [:show, :update]
      resources :notes, only: [:show] do
        post :mark_read, on: :member
      end

      # Family UI inbound — requires authenticated family session (see controller)
      post "family_messages", to: "family_messages#create"
    end
  end

  # Internal dashboards (auth required — gated in DashboardsController)
  get "dashboard", to: "dashboards#show", as: :dashboard
  get "patients/:id",      to: "patient_chats#show", as: :patient
  get "patients/:id/chat", to: "patient_chats#show", as: :patient_chat  # alias

  # Calendar + visit CRUD (clinician-facing scheduling)
  get "calendar", to: "calendars#show", as: :calendar
  resources :visits, only: [:new, :create, :show, :edit, :update, :destroy]

  # Per-agency team management (coordinator / DON / admin)
  resources :branches, only: [:index, :new, :create, :edit, :update, :destroy]
  resources :team_members, only: [:index, :new, :create, :destroy] do
    member { post :reactivate }
  end

  # Clinician notifications inbox (reminders, etc.)
  resources :notifications, only: [:index] do
    member     { post :mark_read }
    collection { post :mark_all_read }
  end

  # Public landing
  get "welcome", to: "pages#welcome", as: :welcome

  # Inquiries: public create, authenticated management
  resources :inquiries, only: [:index, :create] do
    member do
      post :claim
      post :mark_contacted
      post :dismiss
      get  :convert            # form page
      post :convert_to_patient # atomic transaction
    end
  end

  # Root: signed-in clinicians/admins see dashboard; everyone else sees welcome.
  authenticated :user do
    root to: "dashboards#show", as: :authenticated_root
  end
  root to: "pages#welcome"
end
