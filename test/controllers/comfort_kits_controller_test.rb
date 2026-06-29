require "test_helper"

# Request tests for the admission comfort-kit flow, focused on the gates that
# matter: who can stage drafts, and the MD/signature wall on authorization.
class ComfortKitsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @agency  = create_agency
    @md      = create_user(agency: @agency, full_name: "Davidson Louis", roles: %w[md], registered_signature: true)
    @nurse   = create_user(agency: @agency, full_name: "Nancy Nurse",    roles: %w[admissions rn])
    @patient = create_patient(agency: @agency, assigned_md: @md)
    @eval    = create_eval(agency: @agency, patient: @patient, evaluator: @nurse)
  end

  def kit_orders
    in_tenant(@agency) { @eval.comfort_kit_orders.reload.to_a }
  end

  def stage_drafts!(keys = %w[ativan roxanol compazine_tab])
    in_tenant(@agency) do
      Medications::InitializeComfortKitService.new(eval: @eval, user: @nurse).build_drafts(keys).each(&:save!)
    end
  end

  # ── access ──────────────────────────────────────────────────────────
  test "unauthenticated user is redirected to sign in" do
    get pre_admit_eval_comfort_kit_path(@eval)
    assert_redirected_to new_user_session_path
  end

  test "family user is bounced off the clinician-only flow" do
    family = create_user(agency: @agency, full_name: "Fam Member", family_access: true, patient: @patient)
    sign_in family
    get pre_admit_eval_comfort_kit_path(@eval)
    assert_redirected_to welcome_path
  end

  # ── staging drafts (nurse) ──────────────────────────────────────────
  test "intake nurse stages selected items as draft orders" do
    sign_in @nurse
    assert_difference -> { kit_orders.size }, 3 do
      post pre_admit_eval_comfort_kit_path(@eval), params: { items: %w[ativan roxanol compazine_tab] }
    end
    orders = kit_orders
    assert orders.all?(&:order_draft?), "all staged as drafts"
    assert orders.all?(&:comfort_kit?)
    assert_equal 2, orders.count(&:controlled), "Ativan + Roxanol are controlled"
  end

  test "staging ignores unknown/tampered keys and rebuilds from the trusted constant" do
    sign_in @nurse
    post pre_admit_eval_comfort_kit_path(@eval),
         params: { items: %w[ativan not_a_real_drug] }
    orders = kit_orders
    assert_equal 1, orders.size, "the bogus key is dropped"
    assert_equal "Ativan (lorazepam) Tablets", orders.first.drug_name
  end

  test "a second create does not duplicate an existing kit" do
    sign_in @nurse
    stage_drafts!
    assert_no_difference -> { kit_orders.size } do
      post pre_admit_eval_comfort_kit_path(@eval), params: { items: %w[dulcolax_supp] }
    end
  end

  # ── authorization wall (MD + signature) ─────────────────────────────
  test "non-MD cannot authorize the kit" do
    stage_drafts!
    sign_in @nurse
    post authorize_pre_admit_eval_comfort_kit_path(@eval), params: signature_params(@nurse)
    assert_redirected_to pre_admit_eval_comfort_kit_path(@eval)
    assert_equal "Only the MD can authorize the comfort kit.", flash[:alert]
    assert kit_orders.all?(&:order_draft?), "orders stay drafts"
  end

  test "MD without a complete signature is bounced by the gate" do
    stage_drafts!
    sign_in @md
    # Missing typed_name → Signatures::Gate rejects.
    post authorize_pre_admit_eval_comfort_kit_path(@eval),
         params: { apply_signature: "1", intent_confirmed: "1" }
    assert_redirected_to pre_admit_eval_comfort_kit_path(@eval)
    assert kit_orders.all?(&:order_draft?), "nothing activated without a valid signature"
    assert_empty in_tenant(@agency) { Signature.where(verification_method: "comfort_kit_authorize") }
  end

  test "MD with a valid signature authorizes, activates, and signs every draft" do
    stage_drafts!
    sign_in @md
    post authorize_pre_admit_eval_comfort_kit_path(@eval), params: signature_params(@md)
    assert_redirected_to pre_admit_eval_comfort_kit_path(@eval)

    orders = kit_orders
    assert orders.all?(&:order_active?), "all drafts activated"
    assert orders.all? { |o| o.prescribed_by_id == @md.id }, "prescriber is the signing MD"
    assert orders.all? { |o| o.signatures.any? { |s| s.verification_method == "comfort_kit_authorize" } },
           "each order carries its authorization signature"
  end
end
