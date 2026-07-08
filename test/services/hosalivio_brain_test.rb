require "test_helper"

class HosalivioBrainTest < ActiveSupport::TestCase
  def with_env(vals)
    old = {}
    vals.each { |k, v| old[k] = ENV[k]; v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def stubbing(method, impl)
    original = HosalivioBrain.method(method)
    HosalivioBrain.define_singleton_method(method, impl)
    yield
  ensure
    HosalivioBrain.define_singleton_method(method, original)
  end

  test "complete_text falls through to OpenRouter when Claude yields nothing" do
    with_env("ANTHROPIC_API_KEY" => "sk-ant-abcdefghijklmnop",
             "OPENAI_API_KEY" => nil,
             "OPENROUTER_API_KEY" => "or-abcdefghijklmnop") do
      stubbing(:call_claude_plain, ->(**) { nil }) do          # out of credit → nil
        stubbing(:oai_chat, ->(**) { "GLM says hi" }) do
          assert_equal "GLM says hi", HosalivioBrain.complete_text(system: "s", user: "u")
        end
      end
    end
  end

  test "complete_text returns nil when no provider key is valid" do
    with_env("ANTHROPIC_API_KEY" => nil, "OPENAI_API_KEY" => nil, "OPENROUTER_API_KEY" => nil) do
      assert_nil HosalivioBrain.complete_text(system: "s", user: "u")
    end
  end

  test "answer_public_question routes through the full provider chain (complete_text)" do
    # complete_text carries the claude → openai → openrouter fallthrough, so the
    # public chat reaches OpenRouter when Anthropic/OpenAI are dry.
    stubbing(:complete_text, ->(system:, user:) { "Yes — care can happen at home." }) do
      answer = HosalivioBrain.answer_public_question(question: "Can care happen at home?")
      assert_equal "Yes, care can happen at home.", answer   # em-dash scrubbed to ", "
    end
  end

  test "answer_public_question folds prior turns into the user prompt so the ZIP is remembered" do
    seen_user = nil
    history = [
      { "role" => "user",      "content" => "My mom needs help, we're in 33025" },
      { "role" => "assistant", "content" => "Thanks. I found a partner near 33025." }
    ]
    stubbing(:complete_text, ->(system:, user:) { seen_user = user; "Reply" }) do
      HosalivioBrain.answer_public_question(question: "did you find anyone?", history: history)
    end
    assert_includes seen_user, "Conversation so far:"
    assert_includes seen_user, "33025"                     # the earlier ZIP is now visible to the model
    assert_includes seen_user, "Visitor's latest message: did you find anyone?"
  end

  test "answer_public_question with no history passes the bare question" do
    seen_user = nil
    stubbing(:complete_text, ->(system:, user:) { seen_user = user; "Reply" }) do
      HosalivioBrain.answer_public_question(question: "How much does hospice cost?")
    end
    assert_equal "How much does hospice cost?", seen_user
  end
end
