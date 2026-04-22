class PharmacyDeliveryPolicy < ApplicationPolicy
  def index?  = true
  def show?   = true
  def create? = has_role?(:pharmacy, :admin)
  def update? = has_role?(:pharmacy, :rn, :admin)   # RN confirms delivery at home

  class Scope < Scope
    def resolve = scope.all
  end
end
