class NotePolicy < ApplicationPolicy
  def index?  = true
  def show?   = true
  # Every clinical role can add a note. Family writes come in via FamilyMessagesController.
  def create? = has_role?(:admissions, :rn, :md, :don, :sw, :chaplain, :aide, :pharmacy, :dme, :admin)
  def update? = has_role?(:admissions, :rn, :md, :don, :admin)   # e.g. mark_read

  class Scope < Scope
    def resolve = scope.all
  end
end
