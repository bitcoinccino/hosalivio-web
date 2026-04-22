# Be sure to restart your server when you modify this file.

# Version of your assets, change this if you want to expire all your assets.
Rails.application.config.assets.version = "1.0"

# Add additional assets to the asset load path.
# tailwindcss-rails compiles into app/assets/builds/tailwind.css — make it
# discoverable to Propshaft so `stylesheet_link_tag "tailwind"` works.
Rails.application.config.assets.paths << Rails.root.join("app/assets/builds")
