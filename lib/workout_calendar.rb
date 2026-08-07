# frozen_string_literal: true

require 'icalendar'

# Renders workouts as an iCalendar feed.
#
# Everything here is presentation. It reads TrainingPeaks::Workout accessors and
# decides how they should look; it never touches the raw API payload.
class WorkoutCalendar
  # Keyed by workoutTypeValueId, from GET /fitness/v6/workouttypes (see
  # docs/development.md). 10 (Custom) and 100 (Other) are deliberately absent:
  # both are catch-alls, so a plain title says more than a wrong icon would.
  SPORT_EMOJI = {
    1 => '🏊', 2 => '🚴', 3 => '🏃', 4 => '🔁', 5 => '🤸',
    6 => '🏁', 7 => '😴', 8 => '🚵', 9 => '🏋️', 11 => '⛷️',
    12 => '🚣', 13 => '🚶', 29 => '🏋️'
  }.freeze

  # Keyed by workoutSubTypeId, which is a SEPARATE NAMESPACE from the ids above:
  # values 1-13 and 29 exist in both and mean different things (subtype 2 is
  # "Pool Swim", type 2 is "Bike"). Never look one up in the other's map.
  #
  # Yoga is why this exists at all — TrainingPeaks files it as a subtype of
  # Strength (29/22) rather than giving it a type of its own.
  SUBTYPE_EMOJI = {
    20 => '🧘', # Mobility
    22 => '🧘', # Yoga
    23 => '🧗', # Rock Climbing
    25 => '🧘', # Stretching
    41 => '🥾'  # Hike
  }.freeze

  # Sport ids used by the personal naming conventions in `personal_override`.
  CROSSTRAIN = 5
  CUSTOM     = 10

  def initialize(workouts)
    @workouts = workouts
  end

  def to_ics
    calendar = Icalendar::Calendar.new

    @workouts.each do |workout|
      calendar.add_event(event_for(workout))
    end

    calendar.publish
    calendar.to_ical
  end

  def title_for(workout)
    emoji, title = personal_override(workout) || [sport_emoji(workout), workout.title]
    prefixed = emoji ? "#{emoji}: #{title}" : title

    "#{prefixed}#{' ✅' if workout.completed?}"
  end

  def description_for(workout)
    parts = []
    parts << "Time: #{workout.formatted_duration}\n" if workout.formatted_duration
    parts << "TSS: #{workout.planned_tss}\n" if workout.planned_tss
    # Blank line between the metrics block and the body, whenever there are
    # metrics at all — including when there is no body to separate them from.
    parts << "\n" unless parts.empty?
    parts << workout.description if workout.description

    parts.join
  end

  private

  def event_for(workout)
    event = Icalendar::Event.new
    event.dtstart     = Icalendar::Values::Date.new(workout.date)
    event.dtend       = Icalendar::Values::Date.new(workout.date.next_day)
    event.summary     = title_for(workout)
    event.description = description_for(workout)
    event
  end

  # Subtype wins over sport: yoga must not render as generic Strength.
  def sport_emoji(workout)
    SUBTYPE_EMOJI[workout.subtype_id] || SPORT_EMOJI[workout.sport_id]
  end

  # This athlete's own naming conventions, NOT anything the API guarantees.
  # Sufferfest files yoga sessions under Crosstrain with a "Yoga:" title prefix,
  # and its mental-training modules under Custom titled "MTP - ...". Neither
  # sport id means what the title implies, so both are matched on the title and
  # kept well away from the id maps above.
  #
  # Returns [emoji, title], or nil when no personal rule applies.
  def personal_override(workout)
    title = workout.title.to_s

    case workout.sport_id
    when CROSSTRAIN then ['🧘', title.sub('Yoga:', '').strip] if title.start_with?('Yoga:')
    when CUSTOM     then ['🧠', title] if title.start_with?('MTP')
    end
  end
end
