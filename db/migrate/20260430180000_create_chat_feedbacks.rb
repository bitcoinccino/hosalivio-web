class CreateChatFeedbacks < ActiveRecord::Migration[8.1]
  # Public-chat reaction log. Each row captures one visitor
  # tap on the "Did this help?" widget under an AI reply, with
  # the question + the answer that prompted it so we can train
  # against the actual conversation, not just an anonymized
  # rating. Anonymous (no user_id) since the chat is unauth'd;
  # IP and user_agent are kept for spam triage only.
  def change
    create_table :chat_feedbacks, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string  :rating,    null: false  # "helpful" | "not_helpful"
      t.string  :audience               # "family" | "partner"
      t.text    :question,  null: false
      t.text    :answer,    null: false
      t.text    :comment
      t.string  :ip_address
      t.string  :user_agent
      t.timestamps
    end
    add_index :chat_feedbacks, :rating
    add_index :chat_feedbacks, :created_at
  end
end
