module Signatures
  # Single chokepoint for "apply this clinician's signature to this
  # record" so every sign-off path (PreAdmitEval#certify, Visit
  # route_to_md, late-entry notes) writes a uniform audit row. The
  # caller passes the signable record + the user + the request so we
  # can stamp IP / user-agent / verification method without each
  # caller plumbing those through manually.
  #
  # Usage:
  #   Signatures::Apply.call(
  #     signable: eval_rec,
  #     user:     current_user,
  #     intent:   "I certify…",
  #     request:  request,
  #     method:   :registered_signature   # or :drawn_inline / :typed_only
  #   )
  class Apply
    INTENT_DEFAULT = "I certify that I have reviewed this document and authorized the application of my electronic signature."

    def self.call(signable:, user:, request:, method: :registered_signature, intent: INTENT_DEFAULT)
      new(signable: signable, user: user, request: request, method: method, intent: intent).call
    end

    def initialize(signable:, user:, request:, method:, intent:)
      @signable = signable
      @user     = user
      @request  = request
      @method   = method.to_s
      @intent   = intent
    end

    def call
      Signature.create!(
        user:                @user,
        signable:            @signable,
        verification_method: @method,
        intent_text:         @intent,
        document_hash:       hash_of(@signable),
        ip_address:          @request&.remote_ip,
        user_agent:          @request&.user_agent.to_s.first(255),
        signed_name:         @user.full_name,
        signature_blob_id:   @user.signature.attached? ? @user.signature.blob_id : nil,
        signed_at:           Time.current
      )
    end

    private

    # Snapshot the signable's content so an auditor can prove the
    # underlying record wasn't mutated post-signing. We sort the
    # attribute hash so cosmetic ordering changes don't invalidate
    # the hash; we exclude `updated_at` because Rails bumps it on
    # touches and we don't want signatures to look "broken" after
    # an unrelated touch.
    def hash_of(record)
      payload = record.attributes.except("updated_at").sort.to_h
      Digest::SHA256.hexdigest(payload.to_json)
    end
  end
end
