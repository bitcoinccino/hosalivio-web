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
end
