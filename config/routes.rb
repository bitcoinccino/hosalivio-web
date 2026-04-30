Rails.application.routes.draw do
  devise_for :users, controllers: { sessions: "users/sessions" }

  # Universal 6-digit email-code sign-in — available alongside the
  # standard Devise password flow for every user (admin, clinician,
  # family).
  get  "users/sign_in_code",        to: "passwordless#new",     as: :new_passwordless
  post "users/sign_in_code",        to: "passwordless#create",  as: :passwordless
  get  "users/sign_in_code/verify", to: "passwordless#verify",  as: :verify_passwordless
  post "users/sign_in_code/verify", to: "passwordless#consume"

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
      post "family_messages",   to: "family_messages#create"
      post "clinician_messages", to: "clinician_messages#create"

      # Whisper transcription for voice dictation (family chat, visit narratives).
      # Dormant until OPENAI_API_KEY is set; falls back to browser Web Speech.
      post "transcribe", to: "transcriptions#create"

      # Out-of-app push pings — openclaw poller uses these to fetch pending
      # rows and confirm delivery. Auth via OPENCLAW_PINGS_SECRET (separate
      # from per-tenant AgentToken because this is cross-tenant infra).
      get  "outbound_pings/pending",         to: "outbound_pings#pending"
      post "outbound_pings/:id/delivered",   to: "outbound_pings#delivered"

      # Telegram bot webhook — receives reply messages and routes them
      # back into the matched patient chat. Auth via the
      # X-Telegram-Bot-Api-Secret-Token header set during webhook
      # registration (TELEGRAM_WEBHOOK_SECRET env). Gated by
      # Agency#features["allow_telegram_replies"] (default false).
      post "telegram/webhook", to: "telegram_webhooks#receive"

      # ASR session bootstrap — voice_visit_controller.js calls this
      # before opening the streaming connection. Returns Deepgram
      # short-lived key for en/es/pt patients, falls back to Web
      # Speech for Haitian Creole and other languages.
      post "asr_sessions", to: "asr_sessions#create"
    end
  end

  # Internal dashboards (auth required — gated in DashboardsController)
  get "dashboard", to: "dashboards#show", as: :dashboard
  get "patients/:id",      to: "patient_chats#show", as: :patient
  get "patients/:id/chat", to: "patient_chats#show", as: :patient_chat  # alias

  # Family-user invitations for a specific patient
  resources :patients, only: [] do
    resources :family, only: [:new, :create, :destroy], controller: "patient_families"
    resources :consents, only: [:index, :new, :create, :show], controller: "consent_forms"
  end

  # Calendar + visit CRUD (clinician-facing scheduling)
  get "calendar", to: "calendars#show", as: :calendar
  resources :visits, only: [:new, :create, :show, :edit, :update, :destroy] do
    collection do
      post :start_now
    end
    member do
      get  :record
      post :begin
      post :finish
      post :sync_to_eval
      post :discard
      post :route_to_md
      post :sign_note
    end
  end

  # Self-serve profile editing (all signed-in users, including family)
  resource :profile, only: [:edit, :update], controller: "profiles" do
    delete :avatar, action: :remove_avatar
    get    :signature, action: :edit_signature, as: :signature
    patch  :signature, action: :update_signature
    delete :signature, action: :remove_signature
    post   "notifications/test", action: :test_notification, as: :test_notification
  end

  # Quick clinician actions from the My Day overdue-meds card
  resources :medication_logs, only: [:create] do
    collection do
      post :escalate
    end
  end

  # Per-agency team management (coordinator / DON / admin)
  resources :pre_admit_evals, only: [:show, :edit, :update] do
    member do
      post :confirm_pps
      post :certify
      post :finalize
      post :quick_set
      post :request_changes
    end
  end
  # Clinician thumbs-up / thumbs-down on AI-authored notes
  post "notes/:note_id/feedback", to: "note_feedbacks#create", as: :note_feedback

  # Aggregated AI feedback dashboard (admin / DON / curators)
  resource :agent_feedback, only: [:show], controller: "agent_feedbacks"

  resource  :agency_features, only: [:edit, :update], controller: "agency_features"
  resource  :agency_profile,  only: [:edit, :update], controller: "agency_profile"
  resources :branches, only: [:index, :new, :create, :edit, :update, :destroy]
  resources :team_members, only: [:index, :new, :create, :destroy] do
    member { post :reactivate }
  end

  # Out-of-app deeplink: openclaw scripts send Telegram / SMS / email
  # pings that include a signed link to /inbox?t=<token>. The
  # InboxLinksController validates + consumes the token and signs
  # the user in for the matching session.
  get "inbox", to: "inbox_links#show", as: :inbox_link

  # Acknowledge a handoff from the My Day dashboard inline button.
  post "agent_events/:agent_event_id/acknowledge",
       to:   "handoff_acknowledgments#create",
       as:   :handoff_acknowledgment

  # Clinician notifications inbox (reminders, etc.)
  resources :notifications, only: [:index] do
    member     { post :mark_read }
    collection { post :mark_all_read }
  end

  # Public landing
  get "welcome", to: "pages#welcome", as: :welcome

  # Public landing-page chat — unauthenticated, IP-rate-limited.
  # Drives the HosAlivio bubble widget on /welcome. Family +
  # partner audiences route through different system prompts.
  post "public_chat",          to: "public_chats#create",   as: :public_chat
  get  "public_chat/agencies", to: "public_chats#agencies", as: :public_chat_agencies
  post "public_chat/feedback", to: "public_chats#feedback", as: :public_chat_feedback

  # 'Coming soon' upsell page for the agency-admin Upgrade link in the menu
  get "upgrade", to: "pages#upgrade", as: :upgrade

  # Public pricing page for prospective partners
  get "pricing", to: "pages#pricing", as: :pricing

  # Public 3-step partner-signup wizard. Session-backed until step 3 so
  # abandoning the flow never creates a half-provisioned Agency.
  get    "partners/new",         to: "partners#new",      as: :new_partner
  post   "partners",             to: "partners#create"
  get    "partners/step_2",      to: "partners#step_2",   as: :partner_step_2
  post   "partners/step_2",      to: "partners#save_step_2"
  get    "partners/step_3",      to: "partners#step_3",   as: :partner_step_3
  post   "partners/complete",    to: "partners#complete", as: :complete_partner

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
