require "test_helper"

module Coding
  class RxNormTest < ActiveSupport::TestCase
    test "maps comfort-kit ingredients by generic or brand name" do
      assert_equal "7052", Coding::RxNorm.lookup("Roxanol (morphine concentrate) 30 mL bottle").rxcui
      assert_equal "6470", Coding::RxNorm.lookup("Ativan (lorazepam) Tablets").rxcui
      assert_equal "8704", Coding::RxNorm.lookup("Compazine (prochlorperazine) Suppositories").rxcui
      assert_equal "1223", Coding::RxNorm.lookup("Atropine 1% Ophthalmic Solution").rxcui
      assert_equal "1596", Coding::RxNorm.lookup("Dulcolax (bisacodyl) Suppositories").rxcui, "bisacodyl is RXCUI 1596 per RxNav (not 1594)"
      assert_equal "161",  Coding::RxNorm.lookup("Acetaminophen Suppositories").rxcui
      assert_equal "Morphine", Coding::RxNorm.lookup("morphine sulfate").name
    end

    test "returns nil for unknown or blank drugs" do
      assert_nil Coding::RxNorm.lookup("Mystery Drug")
      assert_nil Coding::RxNorm.lookup(nil)
      assert_nil Coding::RxNorm.lookup("")
    end

    test "the live RxNav fallback is dormant in test (offline-safe)" do
      refute Coding::RxNorm.live_enabled?, "live lookup must never fire in test/CI"
      # Unknown drug → nil (no network); known kit drug → static hit.
      assert_nil Coding::RxNorm.lookup("Some Obscure Drug 9000")
      assert_equal "7052", Coding::RxNorm.lookup("morphine sulfate").rxcui
    end

    # The live path is wiring around two pure parsers; test those with canned
    # RxNav JSON so there's no network in CI.
    test "parses the approximate-match RXCUI from RxNav JSON" do
      json = { "approximateGroup" => { "candidate" => [ { "rxcui" => "1049630", "score" => "75" } ] } }
      assert_equal "1049630", Coding::RxNorm.parse_approx_rxcui(json)
      assert_nil Coding::RxNorm.parse_approx_rxcui(nil)
      assert_nil Coding::RxNorm.parse_approx_rxcui({ "approximateGroup" => { "candidate" => [] } })
    end

    test "parses the ingredient (TTY=IN) from an RxNav related concept" do
      related = { "relatedGroup" => { "conceptGroup" => [
        { "tty" => "SCD", "conceptProperties" => [] },
        { "tty" => "IN",  "conceptProperties" => [ { "rxcui" => "3616", "name" => "Diphenhydramine" } ] }
      ] } }
      assert_equal({ "rxcui" => "3616", "name" => "Diphenhydramine" }, Coding::RxNorm.parse_ingredient(related))
      assert_nil Coding::RxNorm.parse_ingredient(nil)
      assert_nil Coding::RxNorm.parse_ingredient({ "relatedGroup" => { "conceptGroup" => [] } })
    end
  end
end
