class PatientPolicy < ApplicationPolicy
  # Family users (humans only) are gated to a single patient they belong to.
  def index?   = !has_role?(:family)
  def show?
    return record.id == user.try(:patient_id).to_s if has_role?(:family)
    true
  end
  def create?  = has_role?(:admissions, :admin)
  # Updating a patient (incl. reassigning the care team via assigned_*_id) is a
  # management action. RN removed: an RN must not reassign patients — that
  # belongs to admin / DON / admissions. MD kept for cert-related edits.
  def update?  = has_role?(:admissions, :md, :don, :admin)
  def destroy? = admin?

  class Scope < Scope
    def resolve
      return scope.where(id: user.patient_id) if user.respond_to?(:family_access) && user.family_access?
      scope.all
    end
  end
end
