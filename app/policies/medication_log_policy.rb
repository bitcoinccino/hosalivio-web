class MedicationLogPolicy < ApplicationPolicy
  def index?  = true
  def show?   = true
  def create? = has_role?(:rn, :aide, :admin)

  class Scope < Scope
    def resolve = scope.all
  end
end
