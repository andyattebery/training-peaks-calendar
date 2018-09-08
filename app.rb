require 'icalendar'
require 'http'
require 'json'
require 'sinatra/base'
require 'sinatra/config_file'

class TrainingPeaksCalendar < Sinatra::Base
  register Sinatra::ConfigFile

  config_file 'config.yml'

  get "/" do
    get_calendar(get_calendar_items)
  end

  def get_calendar_items
    response = 
      HTTP.cookies(:Production_tpAuth => settings.training_peaks[:cookie])
          .get("https://tpapi.trainingpeaks.com/fitness/v1/athletes/#{settings.training_peaks[:athlete_id]}/workouts/2018-07-23/2019-02-24")

    JSON.parse(response.to_s)
  end

  def get_calendar items
    cal = Icalendar::Calendar.new
    items.each do |i|
      event = Icalendar::Event.new
      
      workoutDate = Date.parse(i['workoutDay'])
      event.dtstart     = Icalendar::Values::Date.new(workoutDate)
      event.dtend       = Icalendar::Values::Date.new(workoutDate.next_day)
      event.summary     = get_title(i)
      event.description = get_description(i)

      cal.add_event(event)
    end

    cal.publish

    cal.to_ical
  end

  def get_title item
    title = if item['workoutTypeValueId'] == 2
      "🚴‍: #{item['title']}"
    elsif item['workoutTypeValueId'] == 5
      "🧘‍: #{item['title'].sub('Yoga:', '')}"
    else
      item['title']
    end

    "#{title}#{if item['startTime'] then " ✅" end}"
  end

  def get_description item
    description = String.new
    description << "Time: #{get_time(item['totalTimePlanned'])}\n" if item['totalTimePlanned'] 
    description << "TSS: #{item['tssPlanned']}\n" if item['tssPlanned'] 
    description << "\n" if !description.empty?
    description << item['description'] if item['description']

    description
  end

  def get_time fractional_hours
    Time.at(fractional_hours * 3600).utc.strftime("%H:%M")
  end

end

