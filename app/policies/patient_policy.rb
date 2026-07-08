class PatientPolicy < ApplicationPolicy
  # Family users (humans only) are gated to a single patient they belong to.
  def index?   = !has_role?(:family)
  def show?
    return record.id == user.try(:patient_id).to_s if has_role?(:family)
    true
  end
  def create?  = has_role?(:admissions, :admin)
  # Updating a patient (incl. reassigning the care team via assigned_*_id) is a
  # management action — admin / DON / admissions only. Clinical roles (RN, MD)
  # don't edit the patient record or the care-team assignment here; the MD's
  # job is reviewing/certifying the eval, not re-staffing the patient.
  def update?  = has_role?(:admissions, :admin)
  def destroy? = admin?

  class Scope < Scope
    def resolve
      return scope.where(id: user.patient_id) if user.respond_to?(:family_access) && user.family_access?
      scope.all
    end
  end
end
