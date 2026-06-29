ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Test support (world builders, helpers).
Dir[Rails.root.join("test/support/**/*.rb")].each { |f| require f }

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # World builders (agency / users / patients / evals) available everywhere.
    include TestWorld
  end
end

# Devise sign-in/out for controller & request tests (Warden test mode).
class ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
end
