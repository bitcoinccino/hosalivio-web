require "test_helper"

class Cms::CoverageApiTest < ActiveSupport::TestCase
  test "cached_hospice_lcds falls back to the verified baked-in set when cache is empty" do
    Rails.cache.delete(Cms::CoverageApi::CACHE_KEY)
    lcds = Cms::CoverageApi.cached_hospice_lcds
    assert_includes lcds.map { |l| l["id"] }, "L34538"
    assert lcds.all? { |l| l["url"].to_s.start_with?("https://www.cms.gov/") }
  end

  test "fetch_hospice_lcds keeps only hospice rows from the live report" do
    report = { "data" => [
      { "document_display_id" => "L34548", "title" => "Hospice Cardiopulmonary Conditions", "url" => "https://x/34548" },
      { "document_display_id" => "L99999", "title" => "Some Other Coverage Topic",          "url" => "https://x/99999" }
    ] }.to_json

    with_stub(:license_token, "tok") do
      with_stub(:get, report) do
        lcds = Cms::CoverageApi.fetch_hospice_lcds
        assert_equal %w[L34548], lcds.map { |l| l["id"] }
        assert_equal "Hospice Cardiopulmonary Conditions", lcds.first["title"]
      end
    end
  end

  test "refresh returns the live hospice list" do
    report = { "data" => [ { "document_display_id" => "L34538", "title" => "Hospice Determining Terminal Status", "url" => "https://x/34538" } ] }.to_json
    result = with_stub(:license_token, "tok") { with_stub(:get, report) { Cms::CoverageApi.refresh_hospice_lcds! } }
    assert_equal %w[L34538], result.map { |l| l["id"] }
  ensure
    Rails.cache.delete(Cms::CoverageApi::CACHE_KEY)
  end

  private

  # Override a CoverageApi class method for the block (no mock dependency).
  def with_stub(name, ret)
    sclass = Cms::CoverageApi.singleton_class
    orig   = sclass.instance_method(name)
    sclass.send(:define_method, name) { |*, **| ret }
    yield
  ensure
    sclass.send(:define_method, name, orig)
  end
end
