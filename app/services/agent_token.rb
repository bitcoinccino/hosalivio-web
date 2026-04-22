class AgentToken
  ALGO = "HS256"

  class << self
    def secret
      ENV["HOSALIVIO_JWT_SECRET"].presence || Rails.application.secret_key_base
    end

    def encode(role:, agency_id:, expires_at: 10.years.from_now)
      JWT.encode(
        { role: role.to_s, agency_id: agency_id, exp: expires_at.to_i, iat: Time.current.to_i },
        secret,
        ALGO
      )
    end

    def decode(token)
      return nil if token.blank?
      payload, _ = JWT.decode(token, secret, true, algorithm: ALGO)
      payload.with_indifferent_access
    rescue JWT::DecodeError, JWT::ExpiredSignature
      nil
    end
  end
end
