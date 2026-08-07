# frozen_string_literal: true

require 'date'

module TrainingPeaks
  # A single planned or completed workout.
  #
  # This is the only place that knows TrainingPeaks' field names. Everything
  # downstream reads these accessors, so a renamed API field costs exactly one
  # change in `.from_api` rather than a hunt through string-keyed hash lookups.
  #
  # Deliberately knows nothing about emoji or iCalendar — it models what
  # TrainingPeaks said, not how it is displayed.
  Workout = Data.define(:date, :title, :sport_id, :subtype_id, :planned_duration,
                        :planned_tss, :description, :completed, :started_at) do
    def self.from_api(hash)
      new(date: Date.parse(hash['workoutDay']),
          title: hash['title'],
          sport_id: hash['workoutTypeValueId'],
          subtype_id: hash['workoutSubTypeId'],
          planned_duration: hash['totalTimePlanned'], # fractional HOURS, not minutes
          planned_tss: hash['tssPlanned'],
          description: hash['description'],
          completed: hash['completed'],
          started_at: hash['startTime'])
    end

    # Both signals are checked because there is no evidence which one
    # TrainingPeaks populates: this account has no completed workouts at all,
    # so every observed workout has both fields nil.
    def completed? = completed == true || !started_at.nil?

    # "HH:MM", counting past 24 hours rather than wrapping. The previous
    # implementation formatted a Time, which silently wrapped: 25.5 hours
    # rendered as "01:30".
    #
    # Truncates rather than rounds, matching what the Time-based version did —
    # 0.5139 h (30m50s) is "00:30", not "00:31". Rounding would arguably be more
    # accurate but would change every feed already in someone's calendar.
    #
    # nil when nothing was planned — common enough to matter (1 of 15 workouts
    # in the test fixture). Callers treat nil as "omit the line", so returning
    # nil preserves that contract instead of raising on `nil * 60`.
    def formatted_duration
      return nil if planned_duration.nil?

      minutes = (planned_duration * 60).floor
      format('%02d:%02d', minutes / 60, minutes % 60)
    end
  end
end
