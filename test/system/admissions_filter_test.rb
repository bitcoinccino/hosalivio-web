require "application_system_test_case"

class AdmissionsFilterTest < ApplicationSystemTestCase
  test "search + status chips filter the admissions queue instantly" do
    agency = create_agency
    admin  = create_user(agency: agency, full_name: "Ada Admin", roles: %w[admin])

    ben   = create_patient(agency: agency, first_name: "Benworth", last_name: "Zoff")
    maria = create_patient(agency: agency, first_name: "Maria", last_name: "Gonzalez")

    in_tenant(agency) do
      d = create_eval(agency: agency, patient: ben)      # draft by default
      d.update_columns(primary_icd10_description: "Agranulocytosis secondary to chemotherapy")

      c = create_eval(agency: agency, patient: maria)
      c.update!(status: :certified, evaluator_name: "Dr. House",
                primary_icd10_description: "Infectious gastroenteritis and colitis",
                noe_deadline_at: 3.days.from_now)
    end

    sign_in_as(admin)
    visit admissions_queue_path

    # Default (All) shows both in-flight evals.
    assert_text "Benworth Zoff"
    assert_text "Maria Gonzalez"

    # Free-text search narrows by patient name.
    fill_in placeholder: "Search patient or diagnosis…", with: "gonzalez"
    assert_no_text "Benworth Zoff"
    assert_text "Maria Gonzalez"

    # Search also matches diagnosis text.
    fill_in placeholder: "Search patient or diagnosis…", with: "agranulocytosis"
    assert_text "Benworth Zoff"
    assert_no_text "Maria Gonzalez"

    # Clear, then filter by status chip: Draft → only the draft eval.
    fill_in placeholder: "Search patient or diagnosis…", with: ""
    click_button "Draft"
    assert_text "Benworth Zoff"
    assert_no_text "Maria Gonzalez"

    # Awaiting NOE (certified) → only Maria.
    click_button "Awaiting NOE"
    assert_text "Maria Gonzalez"
    assert_no_text "Benworth Zoff"

    # Admitted (noe_filed) → nothing here yet → empty state.
    click_button "Admitted"
    assert_text "No admissions match your search"

    # Back link returns to the Mission Stage dashboard.
    click_link "Mission Stage"
    assert_current_path dashboard_path
  end
end
