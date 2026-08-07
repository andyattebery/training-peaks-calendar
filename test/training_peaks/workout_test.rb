# frozen_string_literal: true

require 'test_helper'

class WorkoutTest < Minitest::Test
  # `.from_api` is the only place that knows TrainingPeaks' field names, so this
  # is the test that catches a renamed or mistyped field.
  def test_from_api_maps_every_field
    parsed = TrainingPeaks::Workout.from_api(
      'workoutDay' => '2026-08-06T00:00:00',
      'title' => 'Sample Ride',
      'workoutTypeValueId' => 2,
      'workoutSubTypeId' => 6,
      'totalTimePlanned' => 1.5,
      'tssPlanned' => 85.0,
      'description' => 'Body text',
      'completed' => true,
      'startTime' => '2026-08-06T07:30:00'
    )

    assert_equal Date.new(2026, 8, 6), parsed.date
    assert_equal 'Sample Ride', parsed.title
    assert_equal 2,    parsed.sport_id
    assert_equal 6,    parsed.subtype_id
    assert_in_delta 1.5, parsed.planned_duration
    assert_in_delta 85.0, parsed.planned_tss
    assert_equal 'Body text', parsed.description
    assert_equal true, parsed.completed
    assert_equal '2026-08-06T07:30:00', parsed.started_at
  end

  # Every optional field is nil somewhere in real data; parsing must not raise.
  def test_absent_optional_fields_become_nil
    parsed = TrainingPeaks::Workout.from_api('workoutDay' => '2026-08-06T00:00:00', 'title' => 'Bare')

    assert_nil parsed.subtype_id
    assert_nil parsed.planned_duration
    assert_nil parsed.planned_tss
    assert_nil parsed.description
    assert_nil parsed.completed
    assert_nil parsed.started_at
  end

  def test_the_real_fixture_parses_completely
    assert_equal 15, workouts.size
    assert workouts.all?(TrainingPeaks::Workout)
    assert_equal 1, workouts.count { |w| w.planned_duration.nil? }
    assert_equal 8, workouts.count { |w| w.planned_tss.nil? }
  end

  # --- completed? ----------------------------------------------------------

  # Both signals are checked because there is no evidence which one
  # TrainingPeaks populates — this account has no completed workouts at all.
  def test_completion_accepts_either_signal
    assert workout(completed: true, started_at: nil).completed?
    assert workout(completed: nil, started_at: '2026-08-06T07:30:00').completed?
    assert workout(completed: true, started_at: '2026-08-06T07:30:00').completed?
    refute workout(completed: nil, started_at: nil).completed?
  end

  # --- formatted_duration --------------------------------------------------

  def test_duration_formats_fractional_hours
    assert_equal '00:05', workout(planned_duration: 0.08333333333333333).formatted_duration
    assert_equal '00:30', workout(planned_duration: 0.5).formatted_duration
    assert_equal '01:30', workout(planned_duration: 1.5).formatted_duration
  end

  # The old implementation formatted a Time, which wrapped at midnight: 24 hours
  # rendered as "00:00" and 25.5 as "01:30".
  def test_duration_counts_past_twenty_four_hours_instead_of_wrapping
    assert_equal '23:54', workout(planned_duration: 23.9).formatted_duration
    assert_equal '24:00', workout(planned_duration: 24.0).formatted_duration
    assert_equal '25:30', workout(planned_duration: 25.5).formatted_duration
    assert_equal '30:00', workout(planned_duration: 30.0).formatted_duration
  end

  # Truncates rather than rounds, matching the previous Time-based behaviour:
  # 30m50s is "00:30". Rounding would change feeds already in use.
  def test_duration_truncates_seconds
    assert_equal '00:30', workout(planned_duration: 0.5138888888888888).formatted_duration
  end

  # nil is 1 in 15 in real data. The calendar treats nil as "omit the line", so
  # raising here would break every render.
  def test_duration_is_nil_when_nothing_was_planned
    assert_nil workout(planned_duration: nil).formatted_duration
  end
end
