module VisitsHelper
  # One rendered conversation turn: the spoken text plus the resolved
  # identity (name / title / photo) of who said it. `avatar` is an
  # ActiveStorage attachment (patient photo or user avatar) or nil.
  TranscriptTurn = Struct.new(
    :body, :speaker_name, :title, :role_key, :avatar, :initials, :color,
    keyword_init: true
  )

  ROLE_COLORS = {
    "patient"   => "#2F6F4E", # sage green
    "clinician" => "#D97757", # terracotta
    "family"    => "#2B4A7A", # blue
    "other"     => "#6B665F"  # muted
  }.freeze

  DISCIPLINE_TITLES = {
    "rn"            => "RN · Case Manager",
    "md"            => "Physician",
    "social_worker" => "Social Worker",
    "chaplain"      => "Chaplain",
    "aide"          => "Hospice Aide",
    "don"           => "Director of Nursing"
  }.freeze

  CLINICIAN_TOKENS = %w[
    rn nurse clinician md doctor physician aide chaplain
    social worker social_worker lpn lvn np pa
  ].freeze

  # Parse a visit's raw transcript (`[Speaker:]` tags) into a list of
  # TranscriptTurns with each speaker mapped to a real person. Returns
  # [] when there are no speaker tags (caller falls back to flat narrative).
  def visit_transcript_turns(visit)
    text = visit.narrative_raw.to_s.presence || visit.narrative.to_s.presence
    return [] if text.blank?
    return [] unless text.match?(/\[[^\]\n]+:\]/)

    patient   = visit.patient
    clinician = visit.user
    family    = family_members_for(visit)

    split_speaker_segments(text).filter_map do |seg|
      build_turn(seg[:name], tidy_transcript_text(seg[:body]), visit.discipline.to_s, patient, clinician, family)
    end
  end

  # Light, deterministic format-on-display for raw transcript turns. Real
  # Deepgram output is already punctuated (smart_format + punctuate are on),
  # but this keeps capitalization + sentence terminals consistent and tidies
  # web-speech / seeded text that arrives lowercase and unpunctuated. It only
  # normalizes existing structure — it never invents commas mid-sentence.
  def tidy_transcript_text(body)
    s = body.to_s.strip.gsub(/\s+/, " ")
    return s if s.empty?
    s = s.gsub(/\bi\b/, "I") # standalone "i" + contractions (i'm, i'll)
    # Capitalize the first letter and the first letter after . ? !
    s = s.gsub(/(\A|[.?!]\s+)([a-z])/) { "#{Regexp.last_match(1)}#{Regexp.last_match(2).upcase}" }
    s << "." unless s.match?(/[.?!]["')\]]?\z/) # ensure terminal punctuation
    s
  end

  # Like tidy_transcript_text but for a full raw transcript string with
  # [Speaker:] tags — tidies each turn's body while preserving the tags
  # verbatim, since the narrative-link JS parses on them and speaker matching
  # depends on the exact label. One turn per line for the SSR fallback.
  def tidy_transcript_raw(text)
    str = text.to_s
    return str if str.blank?
    return tidy_transcript_text(str) unless str.match?(/\[[^\]\n]+:\]/)

    split_speaker_segments(str).map { |seg|
      body = tidy_transcript_text(seg[:body])
      seg[:name].present? ? "[#{seg[:name]}:] #{body}" : body
    }.join("\n")
  end

  # A directory the narrative-link Stimulus controller uses to render each
  # transcript turn header with the speaker's photo, name, and title. Each
  # entry's `match` is the set of normalized tag labels that resolve to it.
  def visit_speaker_roster(visit)
    patient   = visit.patient
    clinician = visit.user
    roster    = []

    if patient
      roster << {
        match:    normalize_match([ patient.first_name, patient.full_name, "patient" ]),
        name:     patient.first_name.presence || "Patient",
        title:    "Patient",
        color:    ROLE_COLORS["patient"],
        initials: word_initials(patient.full_name) || "PT",
        photoUrl: (patient.has_photo? ? url_for(patient.photo) : nil)
      }
    end

    if clinician
      disc = visit.discipline.to_s
      roster << {
        match:    normalize_match([ clinician.full_name, clinician.full_name.to_s.split.first, disc ] + CLINICIAN_TOKENS),
        name:     clinician.full_name.presence || "Clinician",
        title:    DISCIPLINE_TITLES[disc] || disc.tr("_", " ").upcase.presence || "Clinician",
        color:    ROLE_COLORS["clinician"],
        initials: clinician.initials.presence || "RN",
        photoUrl: (clinician.has_avatar? ? url_for(clinician.avatar) : nil)
      }
    end

    family_members_for(visit).each do |m|
      roster << {
        match:    normalize_match([ m.full_name, m.full_name.to_s.split.first ]),
        name:     m.full_name,
        title:    "Family",
        color:    ROLE_COLORS["family"],
        initials: m.initials.presence || "FM",
        photoUrl: (m.has_avatar? ? url_for(m.avatar) : nil)
      }
    end

    roster << { match: [ "family" ], name: "Family", title: "Family",
                color: ROLE_COLORS["family"], initials: "FM", photoUrl: nil }
    roster
  end

  private

  def normalize_match(values)
    Array(values).map { |s| s.to_s.downcase.strip }.reject(&:blank?).uniq
  end

  def family_members_for(visit)
    return [] if visit.patient_id.blank?
    User.where(patient_id: visit.patient_id, family_access: true, active: true).to_a
  end

  # Split text into { name:, body: } segments on each [Speaker:] tag,
  # preserving any lead text before the first tag.
  def split_speaker_segments(text)
    matches = []
    text.enum_for(:scan, /\[([^\]\n]+):\]/).each do
      m = Regexp.last_match
      matches << { tag_start: m.begin(0), tag_end: m.end(0), name: m[1].strip }
    end
    return [] if matches.empty?

    segments = []
    lead = text[0...matches.first[:tag_start]].to_s.strip
    segments << { name: nil, body: lead } if lead.present?

    matches.each_with_index do |cur, i|
      body_end = matches[i + 1] ? matches[i + 1][:tag_start] : text.length
      body = text[cur[:tag_end]...body_end].to_s.strip
      segments << { name: cur[:name], body: body } if body.present?
    end
    segments
  end

  def build_turn(name, body, discipline, patient, clinician, family)
    return nil if body.blank?

    key, member = classify_speaker(name, patient, clinician, family)
    case key
    when "patient"
      TranscriptTurn.new(
        body: body, role_key: "patient",
        speaker_name: patient&.first_name.presence || "Patient",
        title: "Patient", avatar: (patient.photo if patient&.has_photo?),
        initials: word_initials(patient&.full_name) || "PT",
        color: ROLE_COLORS["patient"]
      )
    when "clinician"
      TranscriptTurn.new(
        body: body, role_key: "clinician",
        speaker_name: clinician&.full_name.presence || name.presence || "Clinician",
        title: DISCIPLINE_TITLES[discipline] || discipline.tr("_", " ").upcase.presence || "Clinician",
        avatar: (clinician.avatar if clinician&.has_avatar?),
        initials: clinician&.initials.presence || word_initials(name) || "RN",
        color: ROLE_COLORS["clinician"]
      )
    when "family"
      TranscriptTurn.new(
        body: body, role_key: "family",
        speaker_name: member&.full_name.presence || name.presence || "Family",
        title: "Family", avatar: (member.avatar if member&.has_avatar?),
        initials: member&.initials.presence || word_initials(name) || "FM",
        color: ROLE_COLORS["family"]
      )
    else
      TranscriptTurn.new(
        body: body, role_key: "other",
        speaker_name: name.presence || "Speaker",
        title: nil, avatar: nil,
        initials: word_initials(name) || "··",
        color: ROLE_COLORS["other"]
      )
    end
  end

  # Returns [role_key, family_user_or_nil].
  def classify_speaker(name, patient, clinician, family)
    norm = name.to_s.downcase.strip
    return [ "other", nil ] if norm.blank?

    return [ "patient", nil ] if norm == "patient" ||
                               same_name?(norm, patient&.first_name) ||
                               same_name?(norm, patient&.full_name)

    member = family.find do |m|
      same_name?(norm, m.full_name) || same_name?(norm, m.full_name.to_s.split.first)
    end
    return [ "family", member ] if member
    return [ "family", nil ] if norm == "family"

    clinician_speaker =
      CLINICIAN_TOKENS.include?(norm) ||
      norm.match?(/\A(rn|md|don|lpn|lvn|np|pa)\b/) ||
      norm.match?(/\b(rn|md|don|lpn|lvn|np|pa|nurse|clinician|doctor|physician)\b/) ||
      same_name?(norm, clinician&.full_name) ||
      same_name?(norm, clinician&.full_name.to_s.split.first)
    return [ "clinician", nil ] if clinician_speaker

    [ "other", nil ]
  end

  def same_name?(norm, candidate)
    c = candidate.to_s.downcase.strip
    c.present? && norm == c
  end

  def word_initials(value)
    parts = value.to_s.split.map(&:first).first(2)
    parts.any? ? parts.join.upcase : nil
  end
end
