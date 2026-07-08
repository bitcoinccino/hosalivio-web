class VisitPolicy < ApplicationPolicy
  def index?   = true
  def show?    = true
  def create?  = has_role?(:rn, :md, :sw, :chaplain, :aide, :admin)
  def update?  = has_role?(:rn, :md, :admin)

  class Scope < Scope
    def resolve = scope.all
  end
end
