class AddFamilyOfferToNotes < ActiveRecord::Migration[8.1]
  def change
    # Marks a family-facing HosAlivio reply that OFFERS to do something and is
    # awaiting a yes/no ("would you like me to check with the nurse?"). Set once
    # at post time so pending_family_offer? reads an authoritative flag instead
    # of re-parsing the (encrypted) prose with a regex on every family message.
    add_column :notes, :family_offer, :boolean, default: false, null: false
  end
end
