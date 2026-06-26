# Cross-origin requests for the /api/v1 surface.
# OpenClaw agents call us server-to-server; browsers only hit the Rails app directly.
# Lock origins down in production.

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins Rails.env.production? ? [] : "*"

    resource "/api/*",
             headers: :any,
             methods: [ :get, :post, :patch, :put, :delete, :options, :head ],
             expose: [ "X-Request-Id" ]
  end
end
