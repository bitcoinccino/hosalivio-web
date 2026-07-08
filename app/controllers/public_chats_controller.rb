# Public landing-page chat endpoint. Unauthenticated, called by the
# bubble widget on /welcome. Two audience prompts (family vs partner)
# routed through HosalivioBrain. Rate-limited by IP via Rails.cache
# so we don't pay for an Anthropic bill-bomb if a bot finds the URL.
class PublicChatsController < ActionController::Base
  protect_from_forgery with: :null_session

  RATE_LIMIT_MAX_PER_HOUR = 20
  MAX_QUESTION_LENGTH     = 1_000

  def create
    payload = parse_payload
    question = payload["question"].to_s.strip
    audience = payload["audience"].to_s.downcase
    audience = "family" unless %w[family partner].include?(audience)

    if question.blank?
      return render(json: { error: "Ask a question first." }, status: :unprocessable_entity)
    end
    if question.length > MAX_QUESTION_LENGTH
      return render(json: { error: "Keep your question under #{MAX_QUESTION_LENGTH} characters." }, status: :unprocessable_entity)
    end
    if rate_limited?
      return render(json: { error: "You've hit the limit for this hour. Try again later or tap 'Talk to a hospice nurse · 24/7' so a human can help." }, status: :too_many_requests)
    end

    history = sanitize_history(payload["history"])

    # Detect ZIP / city / agency-name so the bot's reply can be aware of
    # what cards are about to render below it. We resolve against the whole
    # conversation, not just this message: if the visitor gave a ZIP or city
    # earlier and now asks "so who can help us?", we look the agency up by
    # that remembered location. The lookup runs once, server-side, and the
    # result rides back in the same JSON payload as the answer.
    locator = audience == "family" ? resolve_locator(question, history) : nil
    cards   = locator ? lookup_branches_as_cards(**locator) : []

    # Single source of truth: when the visitor handed us a real
    # locator AND we have zero matches, skip the brain call entirely
    # and ship just the structured "no results" payload. Avoids the
    # double-fallback bug where the bot says "thank you for sharing"
    # and then the JS renders its own "I couldn't find a partner"
    # bubble. Also saves an API call we don't need.
    if locator && cards.empty?
      bump_rate_counter
      return render(json: {
        audience:   audience,
        query:      locator,
        agencies:   [],
        no_results: true
      })
    end

    context = build_brain_context(question: question, locator: locator, cards_count: cards.size)
    answer = HosalivioBrain.answer_public_question(
      question: context.present? ? "#{context}\n\n#{question}" : question,
      audience: audience.to_sym,
      history:  history
    )
    if answer.blank?
      return render(json: { error: "We couldn't reach the assistant right now. Please tap 'Talk to a hospice nurse · 24/7' below." }, status: :bad_gateway)
    end

    bump_rate_counter
    render json: {
      answer:   answer,
      audience: audience,
      query:    locator,
      agencies: cards
    }
  end

  # GET /public_chat/agencies?zip=33012  (or ?city=Hialeah, or ?name=Velmoza)
  # Returns active HosAlivio partner agencies. Match precedence:
  # ZIP > city > agency-name fuzzy. Used by the welcome composer
  # so partner cards surface whether the visitor types a ZIP or
  # asks about an agency by name. Same per-IP rate limit as #create.
  def agencies
    zip   = params[:zip].to_s.strip.gsub(/\D/, "")[0, 5]
    city  = params[:city].to_s.strip
    name  = params[:name].to_s.strip
    state = params[:state].to_s.strip.upcase[0, 2]

    if zip.blank? && city.blank? && name.blank? && state.blank?
      return render(json: { error: "Enter a ZIP, city, state, or agency name." }, status: :unprocessable_entity)
    end
    if rate_limited?
      return render(json: { error: "You've hit the limit for this hour." }, status: :too_many_requests)
    end

    branches = lookup_branches(zip: zip, city: city, name: name, state: state)
    bump_rate_counter

    cards = branches.first(8).map do |b|
      a = b.agency
      {
        agency_id:      a&.id,
        agency_name:    a&.name,
        agency_dba:     a&.dba_name,
        branch_name:    b.name,
        address:        [ b.address_line1, b.address_line2, [ b.city, b.state, b.zip ].compact_blank.join(", ") ].compact_blank.join(", "),
        phone:          b.phone.presence || a&.phone,
        after_hours:    b.after_hours_phone.presence,
        languages:      Array(a&.languages),
        accepting:      !!a&.accepting_referrals,
        match_reason:   match_reason_for(b, zip: zip, city: city, name: name, state: state)
      }
    end

    render json: {
      query:    { zip: zip.presence, city: city.presence, name: name.presence, state: state.presence },
      agencies: cards
    }
  end

  # POST /public_chat/feedback — anonymous reaction on an AI reply.
  # Hover-revealed thumbs widget on the family/partner chat sends
  # { rating, question, answer, audience, comment } here. Same
  # per-IP rate limit as #create. Stored on chat_feedbacks for
  # later prompt tuning + eval clustering.
  def feedback
    payload = parse_payload
    rating  = payload["rating"].to_s
    unless ChatFeedback::RATINGS.include?(rating)
      return render(json: { error: "Unknown rating." }, status: :unprocessable_entity)
    end
    if rate_limited?
      return render(json: { error: "You've hit the limit for this hour." }, status: :too_many_requests)
    end

    fb = ChatFeedback.new(
      rating:     rating,
      audience:   ChatFeedback::AUDIENCES.include?(payload["audience"].to_s) ? payload["audience"] : nil,
      question:   payload["question"].to_s.first(2_000),
      answer:     payload["answer"].to_s.first(4_000),
      comment:    payload["comment"].to_s.first(1_000).presence,
      ip_address: request.remote_ip,
      user_agent: request.user_agent.to_s.first(255)
    )

    if fb.save
      bump_rate_counter
      render json: { ok: true }
    else
      render json: { error: fb.errors.full_messages.first || "Couldn't save." }, status: :unprocessable_entity
    end
  end

  private

  # Detect a ZIP / city / agency-name in the visitor's question.
  # Precedence: 5-digit ZIP > "in/near <City>" > short proper-noun
  # phrase. Returns a hash like { zip: "33012" } / { city: "Hialeah" }
  # / { name: "Velmoza Care" }, or nil when nothing matches.
  STOP_WORDS_FOR_NAME = %w[
    what how when why who can will should is are does do tell explain
    cost price insurance medicare medicaid eligible hospice elder
    dementia cancer help mom dad mother father husband wife
    thank thanks hello hi hey ok okay yes no yeah nope sure good bad
    great sorry please bye you your yours my me i it this that these
    those here there now then
  ].freeze

  # Florida is HosAlivio's statewide service area for now. We
  # match it as a special "state" locator before falling through
  # to city or name lookups so a query like "hospice in florida"
  # returns every active partner instead of trying to find a city
  # called Florida (which would hit nothing).
  STATE_KEYWORDS = {
    "FL" => /\b(?:florida|fl)\b/i
  }.freeze

  # Authoritative list of FL cities scanned anywhere in the
  # visitor's message. Lets queries like "miami hospice" (no
  # preposition) hit the city detector, and lets multi-word
  # names like "Fort Lauderdale" beat single-word substrings.
  # Sourced from the FL municipal directory.
  KNOWN_FL_CITIES = [
    "Alachua", "Altamonte Springs", "Anna Maria", "Apalachicola", "Apopka", "Atlantic Beach", "Auburndale", "Aventura", "Avon Park",
    "Bal Harbour", "Bartow", "Bay Harbor Islands", "Boca Raton", "Bonita Springs", "Boynton Beach", "Bradenton", "Brooksville",
    "Cape Canaveral", "Cape Coral", "Casselberry", "Celebration", "Chipley", "Cinco Bayou", "Clearwater", "Clermont", "Clewiston",
    "Cocoa", "Cocoa Beach", "Coconut Creek", "Coral Gables", "Coral Springs", "Crystal River", "Dania Beach", "Davie", "Daytona Beach",
    "Deerfield Beach", "DeFuniak Springs", "DeLand", "Delray Beach", "Deltona", "Destin", "Dunedin", "Eagle Lake", "Edgewater", "Edgewood",
    "Eustis", "Fort Lauderdale", "Fort Meade", "Fort Myers", "Fort Myers Beach", "Fort Pierce", "Fort Walton Beach", "Fruitland Park",
    "Gainesville", "Greenacres", "Green Cove Springs", "Gulf Breeze", "Gulfport", "Haines City", "Hallandale Beach", "Hawthorne",
    "Hialeah", "Hialeah Gardens", "Highland Beach", "Hollywood", "Holly Hill", "Holmes Beach", "Homestead", "Hypoluxo", "Indialantic",
    "Jacksonville", "Juno Beach", "Jupiter", "Key Biscayne", "Key West", "Kissimmee", "LaBelle", "Lady Lake", "Lake Alfred", "Lakeland",
    "Lake Mary", "Lake Park", "Lake Wales", "Lake Worth", "Lantana", "Largo", "Lauderdale By The Sea", "Lauderhill", "Leesburg",
    "Lighthouse Point", "Longboat Key", "Longwood", "Maitland", "Marco Island", "Margate", "Melbourne", "Melbourne Beach", "Miami",
    "Miami Beach", "Milton", "Minneola", "Miramar", "Mount Dora", "Naples", "Neptune Beach", "New Port Richey", "New Smyrna Beach",
    "Niceville", "North Miami", "North Miami Beach", "North Port", "Oakland Park", "Ocala", "Ocean Ridge", "Ocoee", "Okeechobee",
    "Oldsmar", "Orange Park", "Orlando", "Ormond Beach", "Oviedo", "Palatka", "Palm Bay", "Palm Beach", "Palm Beach Gardens",
    "Palm Coast", "Palmetto", "Panama City", "Panama City Beach", "Pembroke Pines", "Pensacola", "Pinecrest", "Pinellas Park",
    "Plant City", "Plantation", "Pompano Beach", "Ponce Inlet", "Port Orange", "Port St. Lucie", "Punta Gorda", "Rockledge",
    "Royal Palm Beach", "St. Augustine", "St. Augustine Beach", "St. Cloud", "St. Pete Beach", "St. Petersburg", "Safety Harbor",
    "Sanford", "Sanibel", "Sarasota", "Satellite Beach", "Seaside", "Sebastian", "Sewall's Point", "Shalimar", "Stuart", "Surfside",
    "Tallahassee", "Tamarac", "Tampa", "Tarpon Springs", "Tavares", "Temple Terrace", "Titusville", "Treasure Island", "Valparaiso",
    "Venice", "Vero Beach", "Wellington", "West Melbourne", "West Palm Beach", "Weston", "Wilton Manors", "Winter Garden",
    "Winter Haven", "Winter Park", "Winter Springs"
  ].freeze

  # Compile once at boot — multi-word cities sorted longest-first
  # so "Fort Lauderdale" wins over "Fort", and "Palm Beach Gardens"
  # over "Palm Beach". Periods escaped (Port St. Lucie, etc.).
  KNOWN_FL_CITIES_RE = Regexp.new(
    "\\b(" +
    KNOWN_FL_CITIES.sort_by { |c| -c.length }
                   .map { |c| Regexp.escape(c) }
                   .join("|") +
    ")\\b",
    Regexp::IGNORECASE
  ).freeze

  # Messages that signal the visitor wants agencies / next steps. Only when
  # the current message matches this do we reach back into history for a
  # previously-shared ZIP or city, so a general question ("does Medicare
  # cover this?") doesn't re-trigger the agency cards.
  AGENCY_INTENT_RE = /\b(agenc(?:y|ies)|who can help|help (?:us|me|my)|find|match|options?|partners?|near me|nearest|closest|get started|getting started|sign up|refer|referral|admission|home care|next steps?)\b/i

  # Resolve the location to look up. Prefer whatever is in the current
  # message; if it has none but the visitor is asking about agencies, fall
  # back to the most recent ZIP / city / state they gave earlier in the
  # conversation. We deliberately ignore the name-fuzzy fallback from
  # history (too loose to reuse blindly across turns).
  def resolve_locator(question, history)
    current = extract_locator(question)
    return current if current
    return nil unless question.match?(AGENCY_INTENT_RE)

    Array(history).reverse_each do |turn|
      next unless turn[:role] == "user"
      loc = extract_locator(turn[:content].to_s)
      return loc if loc && (loc[:zip] || loc[:city] || loc[:state])
    end
    nil
  end

  def extract_locator(question)
    if (m = question.match(/\b\d{5}\b/))
      return { zip: m[0] }
    end
    # Known FL city scan — multi-word cities resolve via the
    # longest-first regex above, so "Fort Lauderdale" doesn't
    # get split into "Fort" + something else. We do NOT keep a
    # generic "in/near/at <Capitalized phrase>" fallback because
    # it false-positives on questions like "Can care happen at
    # home?" (capturing "home" as a city). HosAlivio's footprint
    # is FL-only today; if a known FL city isn't in the message,
    # let the bot answer naturally.
    if (m = question.match(KNOWN_FL_CITIES_RE))
      city = KNOWN_FL_CITIES.find { |c| c.downcase == m[1].downcase } || m[1]
      return { city: city }
    end
    STATE_KEYWORDS.each do |code, re|
      return { state: code } if question.match?(re)
    end
    cleaned = question.gsub(/[?.!,]/, "").strip
    if cleaned.length.between?(3, 60)
      words = cleaned.split(/\s+/)
      if words.length <= 6 && (words.map(&:downcase) & STOP_WORDS_FOR_NAME).empty?
        return { name: cleaned }
      end
    end
    nil
  end

  # Same shape the standalone /agencies endpoint serves — keeps
  # the JS card renderer agnostic about whether the cards came
  # from the chat call or the dedicated lookup.
  def lookup_branches_as_cards(zip: nil, city: nil, name: nil, state: nil)
    branches = lookup_branches(zip: zip.to_s, city: city.to_s, name: name.to_s, state: state.to_s)
    branches.first(8).map do |b|
      a = b.agency
      {
        agency_id:    a&.id,
        agency_name:  a&.name,
        agency_dba:   a&.dba_name,
        branch_name:  b.name,
        address:      [ b.address_line1, b.address_line2, [ b.city, b.state, b.zip ].compact_blank.join(", ") ].compact_blank.join(", "),
        phone:        b.phone.presence || a&.phone,
        after_hours:  b.after_hours_phone.presence,
        languages:    Array(a&.languages),
        accepting:    !!a&.accepting_referrals,
        match_reason: match_reason_for(b, zip: zip.to_s, city: city.to_s, name: name.to_s, state: state.to_s)
      }
    end
  end

  # Short context note prepended to the user's question so the
  # brain knows whether agency cards will accompany its reply.
  # The model uses this to skip "what do you mean?" and to
  # acknowledge the lookup naturally ("Pulling 3 partners near
  # 33012, you'll see them below.").
  def build_brain_context(question:, locator:, cards_count:)
    return "" unless locator
    where = locator[:zip] || locator[:city] || locator[:name]
    bits = []
    bits << "[UI CONTEXT — do not echo this back to the visitor]"
    if cards_count.positive?
      bits << "Below your reply, #{cards_count} HosAlivio partner agency card#{'s' if cards_count != 1} matching \"#{where}\" will render automatically. Acknowledge briefly (1 sentence) that they'll appear, do not list them yourself, do not ask the visitor for more info."
    else
      bits << "The visitor said \"#{where}\" but no HosAlivio partner agency matched. A friendly fallback message will render below your reply telling them we'll personally help via the callback CTA. Acknowledge their input warmly in 1 sentence; do not promise to find one."
    end
    bits.join("\n")
  end

  # Branch lookup is the source of truth (zips + city live there;
  # an agency can have multiple branches with different coverage).
  # Filter by partner + active first to keep the result tight.
  # Match precedence: ZIP -> state -> city -> agency-name fuzzy.
  def lookup_branches(zip:, city:, name: nil, state: nil)
    scope = Branch.joins(:agency).where(active: true,
                                        agencies: { active: true, is_partner: true,
                                                    accepting_referrals: true })
    if zip.present?
      prefix = zip[0, 3]
      # service_area_zips stores ZIPs as JSON *strings*, so the search value
      # must be JSON-encoded (a bare "33025" casts to a jsonb *number* and never
      # matches; a leading-zero ZIP would even raise). Qualify with `branches.`
      # since both `agencies` and `branches` carry the column (PG::AmbiguousColumn).
      scope = scope.where(<<~SQL, full: zip.to_json, prefix: prefix.to_json, like: "#{zip}%")
        branches.service_area_zips @> :full::jsonb
        OR branches.service_area_zips @> :prefix::jsonb
        OR branches.zip LIKE :like
      SQL
    elsif state.present?
      scope = scope.where("UPPER(branches.state) = ?", state.upcase)
    elsif city.present?
      scope = scope.where("LOWER(branches.city) = ? OR LOWER(branches.city) LIKE ?",
                          city.downcase, "#{city.downcase}%")
    elsif name.present? && name.length >= 3
      pattern = "%#{name.downcase}%"
      scope = scope.where("LOWER(agencies.name) LIKE :p OR LOWER(agencies.dba_name) LIKE :p", p: pattern)
    else
      return Branch.none
    end
    ordered_matches(scope.distinct.limit(20).includes(:agency).to_a, zip: zip)
  rescue ActiveRecord::StatementInvalid
    Branch.none
  end

  # Deterministic card order: exact-ZIP matches before 3-digit-prefix matches,
  # then agencies accepting referrals, then alphabetical. (No distance/rating
  # data to sort on, so this is the most-relevant ordering we can ground.)
  def ordered_matches(branches, zip:)
    z = zip.to_s
    branches.sort_by do |b|
      exact     = z.present? && (Array(b.service_area_zips).include?(z) || b.zip.to_s.start_with?(z)) ? 0 : 1
      accepting = b.agency&.accepting_referrals ? 0 : 1
      [ exact, accepting, b.agency&.name.to_s.downcase ]
    end
  end

  def match_reason_for(branch, zip:, city:, name: nil, state: nil)
    return "Serves ZIP #{zip}" if zip.present? && Array(branch.service_area_zips).any? { |z| z.to_s == zip }
    return "Serves area #{zip[0, 3]}xx" if zip.present? && Array(branch.service_area_zips).any? { |z| z.to_s == zip[0, 3] }
    return "Located in #{branch.city}" if city.present? && branch.city.to_s.downcase.start_with?(city.to_s.downcase)
    return "Branch ZIP #{branch.zip}" if zip.present? && branch.zip.to_s.start_with?(zip)
    return "#{branch.city}, #{branch.state}" if state.present? && branch.state.to_s.upcase == state.upcase
    return "Matches \"#{name}\"" if name.present?
    "Nearby branch"
  end

  def parse_payload
    if request.content_type.to_s.include?("application/json")
      JSON.parse(request.raw_post)
    else
      params.permit(:question, :audience).to_h
    end
  rescue JSON::ParserError
    {}
  end

  # Normalize the client-supplied conversation history into a trusted shape
  # before it reaches the brain. Only user/assistant roles, string content
  # capped in length, and at most the last 10 turns (older ones are dropped
  # client- and server-side so a hostile payload can't balloon the prompt).
  def sanitize_history(raw)
    Array(raw).last(10).filter_map do |turn|
      next unless turn.is_a?(Hash)
      role    = turn["role"].to_s
      role    = "user" unless %w[user assistant].include?(role)
      content = turn["content"].to_s.strip[0, MAX_QUESTION_LENGTH]
      next if content.blank?
      { role: role, content: content }
    end
  end

  # Single-window counter per IP. Cache key includes the current hour
  # so the count naturally resets each clock hour. Cheap, no extra
  # gem, plenty for a public landing-page widget.
  def rate_key
    "public_chat:rl:#{request.remote_ip}:#{Time.current.utc.strftime('%Y%m%d%H')}"
  end

  def rate_limited?
    (Rails.cache.read(rate_key).to_i) >= RATE_LIMIT_MAX_PER_HOUR
  end

  def bump_rate_counter
    Rails.cache.increment(rate_key, 1, expires_in: 1.hour, raw: true) ||
      Rails.cache.write(rate_key, 1, expires_in: 1.hour, raw: true)
  end
end
