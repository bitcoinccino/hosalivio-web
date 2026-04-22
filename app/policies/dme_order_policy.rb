class DmeOrderPolicy < ApplicationPolicy
  def index?  = true
  def show?   = true
  def create? = has_role?(:dme, :rn, :don, :admin)
  def update? = has_role?(:dme, :admin)

  class Scope < Scope
    def resolve = scope.all
  end
end
