# frozen_string_literal: true

class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  def index?   = false
  def show?    = false
  def create?  = false
  def new?     = create?
  def update?  = false
  def edit?    = update?
  def destroy? = false

  # Role-based helpers. Works for AgentPrincipal (single role) and User (many roles).
  def role_names
    if user.is_a?(AgentPrincipal)
      [user.role.to_s]
    elsif user.respond_to?(:role_names)
      user.role_names.map(&:to_s)
    else
      []
    end
  end

  def has_role?(*names)
    (names.map(&:to_s) & role_names).any?
  end

  def admin? = has_role?("admin")

  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve = scope.all

    private

    attr_reader :user, :scope
  end
end
