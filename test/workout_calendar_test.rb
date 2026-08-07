# frozen_string_literal: true

require 'test_helper'

class WorkoutCalendarTest < Minitest::Test
  def title(**overrides) = calendar.title_for(workout(**overrides))

  # --- sport emoji ---------------------------------------------------------

  def test_every_mapped_sport_gets_its_emoji
    {
      1 => '🏊', 2 => '🚴', 3 => '🏃', 4 => '🔁', 5 => '🤸', 6 => '🏁',
      7 => '😴', 8 => '🚵', 9 => '🏋️', 11 => '⛷️', 12 => '🚣', 13 => '🚶', 29 => '🏋️'
    }.each do |sport_id, emoji|
      assert_equal "#{emoji}: Session",
                   title(sport_id: sport_id, subtype_id: nil, title: 'Session'),
                   "sport #{sport_id}"
    end
  end

  # Custom and Other are catch-alls; an icon would assert more than we know.
  def test_catch_all_and_unknown_sports_render_a_plain_title
    [10, 100, 999].each do |sport_id|
      assert_equal 'Session',
                   title(sport_id: sport_id, subtype_id: nil, title: 'Session'),
                   "sport #{sport_id} should have no prefix"
    end
  end

  # --- subtypes ------------------------------------------------------------

  def test_subtype_wins_over_its_parent_sport
    assert_equal '🧘: Evening Flow',
                 title(sport_id: 29, subtype_id: 22, title: 'Evening Flow')
    assert_equal '🏋️: Deadlifts',
                 title(sport_id: 29, subtype_id: nil, title: 'Deadlifts')
  end

  # sport_id and subtype_id are SEPARATE namespaces whose values overlap:
  # subtype 2 is "Pool Swim", sport 2 is "Bike". This test fails loudly if
  # anyone collapses SPORT_EMOJI and SUBTYPE_EMOJI into one lookup.
  def test_subtype_ids_are_not_looked_up_as_sport_ids
    assert_equal '🏊: Pool Session',
                 title(sport_id: 1, subtype_id: 2, title: 'Pool Session')
  end

  def test_unmapped_subtype_falls_back_to_the_parent_sport
    assert_equal '🚴: Road Miles',
                 title(sport_id: 2, subtype_id: 3, title: 'Road Miles')
  end

  # --- personal naming conventions ----------------------------------------

  def test_sufferfest_yoga_and_mtp_conventions_are_honoured
    assert_equal '🧘: Evening Flow',
                 title(sport_id: 5, subtype_id: nil, title: 'Yoga: Evening Flow')
    assert_equal '🧠: MTP - Focus',
                 title(sport_id: 10, subtype_id: nil, title: 'MTP - Focus')
  end

  # The conventions are title-based and must not colour the whole sport.
  def test_personal_conventions_do_not_leak_to_other_workouts_of_the_same_sport
    assert_equal '🤸: Elliptical', title(sport_id: 5, subtype_id: nil, title: 'Elliptical')
    assert_equal 'Something Else', title(sport_id: 10, subtype_id: nil, title: 'Something Else')
  end

  # --- completion ----------------------------------------------------------

  def test_completed_workouts_are_suffixed
    assert_equal '🚴: Session ✅',
                 title(sport_id: 2, subtype_id: nil, title: 'Session', completed: true)
  end

  # --- description ---------------------------------------------------------

  def test_description_includes_planned_time_and_tss
    text = calendar.description_for(
      workout(planned_duration: 1.5, planned_tss: 85.0, description: 'Body')
    )

    assert_includes text, "Time: 01:30\n"
    assert_includes text, "TSS: 85.0\n"
    assert_includes text, 'Body'
  end

  # These nils are common in real data, not hypothetical: 1 of 15 fixture
  # workouts has no planned time and 8 have no planned TSS.
  def test_missing_metrics_are_omitted_rather_than_raising
    text = calendar.description_for(
      workout(planned_duration: nil, planned_tss: nil, description: 'Body')
    )

    refute_includes text, 'Time:'
    refute_includes text, 'TSS:'
    assert_equal 'Body', text
  end

  def test_metrics_are_separated_from_the_body_by_a_blank_line
    text = calendar.description_for(
      workout(planned_duration: 1.0, planned_tss: nil, description: 'Body')
    )

    assert_equal "Time: 01:00\n\nBody", text
  end

  # --- ics rendering -------------------------------------------------------

  def test_calendar_renders_one_event_per_workout
    parsed = Icalendar::Calendar.parse(calendar.to_ics).first

    assert_equal workouts.size, parsed.events.size
  end

  def test_events_are_all_day_and_span_a_single_day
    event = Icalendar::Calendar.parse(calendar(workouts.first(1)).to_ics).first.events.first

    assert_equal Date.new(2026, 8, 6), event.dtstart.to_date
    assert_equal Date.new(2026, 8, 7), event.dtend.to_date
  end

  # ICS folds lines at 75 octets, which is exactly where multi-byte characters
  # get mangled if the library gets it wrong.
  def test_emoji_and_multiline_descriptions_survive_a_round_trip
    parsed = Icalendar::Calendar.parse(calendar.to_ics).first

    assert parsed.events.any? { |e| e.summary.to_s.start_with?('🚴') }
    assert parsed.events.any? { |e| e.summary.to_s.start_with?('🧠') }
    assert parsed.events.all? { |e| e.description.to_s.include?("\n") }
    assert parsed.events.any? { |e| e.description.to_s.include?('✭') }
  end

  def test_calendar_is_published
    assert_includes calendar(workouts.first(1)).to_ics, 'METHOD:PUBLISH'
  end
end
