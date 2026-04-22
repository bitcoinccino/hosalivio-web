class MedicationOrderPolicy < ApplicationPolicy
  def index?  = true
  def show?   = true
  def create? = has_role?(:md, :admin)
  def update? = has_role?(:md, :admin)

  class Scope < Scope
    def resolve = scope.all
  end
end
