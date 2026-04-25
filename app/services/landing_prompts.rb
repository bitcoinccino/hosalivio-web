# Landing-page prompt tree.
# Clicking a chip yields a warm, specific answer from HosAlivio plus
# 2–3 follow-up chips and a soft CTA. No persistence; privacy wall holds.
#
# Add/edit prompts here only — the view and Stimulus controller render
# whatever structure this exposes.

module LandingPrompts
  PROMPTS = {
    "include" => {
      label: "What does hospice care include?",
      icon:  "ri-team-line",
      answer: <<~TXT,
        Hospice isn't a place — it's a team that comes to wherever your loved one is. Typically you get:

        • A nurse case manager (your main point of contact, available 24/7)
        • A hospice physician and medical director
        • A social worker for family support and benefits help
        • A chaplain — non-denominational, focused on meaning and comfort
        • Certified home health aides for personal care and bathing
        • All medications, equipment, and supplies related to the illness
        • Bereavement support for the family for up to 13 months after

        The idea is that no one has to face this alone — and the family gets as much support as the patient.
      TXT
      followups: %w[eligible when doctor]
    },

    "eligible" => {
      label: "How do we know if we're eligible?",
      icon:  "ri-shield-check-line",
      answer: <<~TXT,
        Two things need to be true — and nothing else is required:

        1. A physician certifies that the illness, left to run its course, has a prognosis of six months or less.
        2. The patient chooses comfort-focused care over curative treatment for that illness.

        You don't need to stop all care — you don't have to sign anything scary — and if someone lives longer than six months (many do), they can be re-certified. Saying yes to hospice isn't saying no to living. Many families describe the weeks after hospice starts as the calmest they've had in a long time.
      TXT
      followups: %w[when cost doctor]
    },

    "cost" => {
      label: "Who pays for it?",
      icon:  "ri-bank-card-line",
      answer: <<~TXT,
        In almost every case — nothing comes out of pocket.

        • **Medicare Part A** covers 100% of the hospice benefit (visits, meds, equipment, supplies, bereavement).
        • **Medicaid** covers it in every state.
        • **Most private insurers** mirror the Medicare benefit.

        That includes the hospital bed, oxygen, comfort medications, nursing visits, and the full team. Money is almost never the reason a family holds off — but people often assume it is. We'll help verify coverage before anything starts.
      TXT
      followups: %w[include eligible speak]
    },

    "when" => {
      label: "When should we consider it?",
      icon:  "ri-time-line",
      answer: <<~TXT,
        Sooner than most families do. The hardest words we hear are *"I wish we'd called you months ago."*

        Signs it may be time:

        • Frequent hospital or ER visits
        • Noticeable weight loss or less interest in food
        • More time sleeping, less time engaged
        • Increasing pain or breathing difficulty
        • A gut sense that treatment is doing more harm than good

        There's no penalty for calling to ask. A conversation costs nothing and often brings clarity, whether hospice is right today or later.
      TXT
      followups: %w[eligible include speak]
    },

    "doctor" => {
      label: "Can we keep our current doctor?",
      icon:  "ri-stethoscope-line",
      answer: <<~TXT,
        Yes. Your primary physician stays on — and directs care alongside the hospice medical director.

        Many families find this part unexpectedly comforting: their trusted doctor is still there, and the hospice team handles day-to-day symptom management, late-night questions, and the messier logistics. It's additive, not replacement.
      TXT
      followups: %w[include eligible speak]
    },

    "near" => {
      label: "Find care near me",
      icon:  "ri-map-pin-line",
      answer: <<~TXT,
        We'll match you with a local, licensed hospice team — usually same-day.

        Give us a zip code and how to reach you, and an admissions coordinator will call with options specific to where your loved one is (home, a facility, or another state). We never share your information and there's no obligation.
      TXT
      followups: %w[speak],
      open_capture: true   # surfaces the mini zip/contact form
    },

    "kit" => {
      label: "What's a 'comfort kit'?",
      icon:  "ri-capsule-line",
      answer: <<~TXT,
        A comfort kit is a small box of emergency symptom medications the hospice delivers to the home — so you're never stuck waiting on a pharmacy at 2am.

        It typically includes medicine for pain, shortness of breath, anxiety, and secretions. Nobody opens the box unless a nurse says to. It's peace of mind, in a drawer.
      TXT
      followups: %w[include near speak]
    },

    "speak" => {
      label: "I'd like to speak with an admissions coordinator",
      icon:  "ri-customer-service-2-line",
      answer: <<~TXT,
        Of course. The fastest way is a quick call — leave a zip code and a way to reach you, and a coordinator (not a call-center) will call back within a few hours, usually much sooner.

        If it's urgent right now, call us directly at **(305) 555-0100**.
      TXT
      followups: [],
      open_capture: true
    }
  }.freeze

  # Entry chips shown first, in order.
  STARTERS = %w[include eligible cost when doctor near].freeze

  def self.starters = STARTERS.map { |k| PROMPTS.fetch(k).merge(id: k) }
  def self.all      = PROMPTS.transform_values.with_index { |v, i| v.merge(id: PROMPTS.keys[i]) }

  # Pass to the view as JSON so the Stimulus controller can look up any prompt by id.
  def self.as_json_payload
    PROMPTS.each_with_object({}) do |(id, data), h|
      h[id] = {
        id:           id,
        label:        data[:label],
        icon:         data[:icon],
        answer:       data[:answer],
        followups:    data[:followups] || [],
        open_capture: data[:open_capture] || false
      }
    end
  end
end
