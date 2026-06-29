class AddComfortKitFieldsToMedicationOrders < ActiveRecord::Migration[8.1]
  def change
    # Dispensed quantity ("6", "10", "1") — string so units like a bottle read
    # cleanly. Full administration sig ("insert 1 rectally q 4 hrs prn temp >
    # 100") that the decomposed frequency/prn_indication fields can't hold verbatim.
    add_column :medication_orders, :quantity, :string
    add_column :medication_orders, :instructions, :text

    # Explicit controlled-substance flag. Until now this was by convention; making
    # it a column lets CcControlledSubstanceCount reconcile against controlled
    # orders precisely (it already belongs_to :medication_order).
    add_column :medication_orders, :controlled, :boolean, default: false, null: false

    # Tags orders that originated from the emergency comfort kit, so we can avoid
    # re-suggesting an already-ordered kit and group them in the UI.
    add_column :medication_orders, :comfort_kit, :boolean, default: false, null: false

    # Anchors an order to the admission it was placed during (the comfort kit is
    # an admission artifact). Optional + nullify: ordinary agent-created orders
    # leave it null, and deleting an eval doesn't delete the standing orders.
    add_reference :medication_orders, :pre_admit_eval, type: :uuid, null: true,
                  foreign_key: { on_delete: :nullify }

    add_index :medication_orders, [ :patient_id, :comfort_kit ]
  end
end
