require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  # Anchored to a fixed "today" so the week-boundary cases can't drift with the
  # calendar — travel_to keeps Date.current stable inside each block.
  TODAY = Date.new(2026, 7, 16) # a Thursday

  test "today and yesterday stand alone" do
    travel_to TODAY do
      assert_equal "Today",     relative_date_label(TODAY)
      assert_equal "Yesterday", relative_date_label(TODAY - 1)
    end
  end

  test "a weekday inside the last week carries its date" do
    travel_to TODAY do
      # A bare "Monday" can't be told from any other Monday — the date resolves it.
      assert_equal "Monday · July 13", relative_date_label(TODAY - 3)
      assert_equal "Friday · July 10", relative_date_label(TODAY - 6)
    end
  end

  test "past the weekday window it falls back to a plain date" do
    travel_to TODAY do
      assert_equal "July 9", relative_date_label(TODAY - 7)
    end
  end

  test "a different year keeps the year" do
    travel_to TODAY do
      assert_equal "December 20, 2025", relative_date_label(Date.new(2025, 12, 20))
    end
  end

  test "it accepts a time, not just a date, and tolerates nil" do
    travel_to TODAY do
      assert_equal "Today", relative_date_label(TODAY.to_time)
      assert_equal "",      relative_date_label(nil)
    end
  end
end
