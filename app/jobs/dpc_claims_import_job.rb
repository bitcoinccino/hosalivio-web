# Pulls a patient's Medicare diagnosis history from DPC and stores it on the
# admission eval as ADVISORY comorbidities (the RN confirms; nothing is
# auto-committed into the eval's own diagnosis fields). No-op unless DPC is
# configured. `patient_dpc_id` is the patient's id within DPC, available once
# the patient has been registered + attributed to a treating practitioner.
#
# Mirrors VitasEmrSyncJob: env-gated, tenant-wrapped, dormant until credentialed.
class DpcClaimsImportJob < ApplicationJob
  queue_as :default

  def perform(eval_id, patient_dpc_id)
    return unless Dpc.configured?
    eval_rec = PreAdmitEval.unscoped.find_by(id: eval_id)
    return unless eval_rec

    ActsAsTenant.with_tenant(eval_rec.agency) do
      rows = Dpc::Client.new.diagnoses_for(patient_dpc_id)
      return if rows.empty?

      history = rows.map do |r|
        { "icd10" => r.icd10, "description" => r.description,
          "last_seen" => r.last_seen&.iso8601, "count" => r.count }
      end
      raw = eval_rec.raw_json.deep_dup
      raw["pre_admit_eval"] ||= {}
      raw["pre_admit_eval"]["diagnosis"] ||= {}
      raw["pre_admit_eval"]["diagnosis"]["medicare_claims_history"] = {
        "source"      => "DPC",
        "imported_at" => Time.current.iso8601,
        "diagnoses"   => history
      }
      eval_rec.update!(raw_json: raw)
      Rails.logger.info("[DpcClaimsImportJob] eval=#{eval_rec.id} imported=#{history.size}")
    end
  end
end
