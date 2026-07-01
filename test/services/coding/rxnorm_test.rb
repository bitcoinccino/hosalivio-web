require "test_helper"

module Coding
  class RxNormTest < ActiveSupport::TestCase
    test "maps comfort-kit ingredients by generic or brand name" do
      assert_equal "7052", Coding::RxNorm.lookup("Roxanol (morphine concentrate) 30 mL bottle").rxcui
      assert_equal "6470", Coding::RxNorm.lookup("Ativan (lorazepam) Tablets").rxcui
      assert_equal "8704", Coding::RxNorm.lookup("Compazine (prochlorperazine) Suppositories").rxcui
      assert_equal "1223", Coding::RxNorm.lookup("Atropine 1% Ophthalmic Solution").rxcui
      assert_equal "Morphine", Coding::RxNorm.lookup("morphine sulfate").name
    end

    test "returns nil for unknown or blank drugs" do
      assert_nil Coding::RxNorm.lookup("Mystery Drug")
      assert_nil Coding::RxNorm.lookup(nil)
      assert_nil Coding::RxNorm.lookup("")
    end
  end
end
