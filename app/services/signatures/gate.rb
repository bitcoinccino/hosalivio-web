module Signatures
  # Single shared gatekeeper every sign-off action runs before
  # calling Signatures::Apply. Validates the four preconditions
  # CMS expects on a clinical e-signature:
  #   1. The actor confirmed intent (checkbox)
  #   2. They have a registered signature on file
  #   3. They typed their own full name (closes the "logged-in
  #      tablet on a colleague's lap" loophole that intent
  #      checkboxes alone don't catch)
  #   4. The form carried apply_signature=1 (so a half-built
  #      submission can't sneak through)
  # Returns [true, nil] on success or [false, "human readable
  # reason"] so callers can render the error inline.
  class Gate
    def self.call(user:, params:)
      return [false, "Confirm the certification statement to sign."] unless flag?(params[:apply_signature]) && flag?(params[:intent_confirmed])
      return [false, "Register your signature first via your profile."] unless user.signature_registered?

      typed = params[:typed_name].to_s
      return [false, "Type your full name to confirm."] if typed.strip.empty?
      return [false, "Typed name doesn't match your account."] unless user.matches_full_name?(typed)

      [true, nil]
    end

    def self.flag?(v)
      v.to_s == "1" || v.to_s.downcase == "true"
    end
  end
end
