# frozen_string_literal: true

require 'sinatra/base'
require 'sinatra/config_file'
require 'sinatra/multi_route'

require_relative 'lib/training_peaks'
require_relative 'lib/workout_calendar'

# The web layer, and nothing else: fetch workouts, render them, report auth
# failures as 502s.
class TrainingPeaksCalendar < Sinatra::Base
  register Sinatra::ConfigFile
  register Sinatra::MultiRoute

  config_file 'config.yml'

  # Built lazily and kept, because the session caches credentials across
  # requests. Two things it must not be:
  #
  #   set :session, -> { ... }   Sinatra re-evaluates procs on every read, so
  #                              every request would get a fresh, empty cache.
  #   set :session, Session.new  config.yml is gitignored, so CI loads this file
  #                              without it and `settings.training_peaks` would
  #                              not exist yet.
  #
  # Tests inject their own with `set :session, ...`.
  set :session, nil

  get '/', '/training-peaks.ics' do
    content_type 'text/calendar'
    attachment 'training-peaks.ics'

    WorkoutCalendar.new(session.workouts).to_ics
  end

  error TrainingPeaks::LoginFailed, TrainingPeaks::SessionExpired do
    status 502
    content_type 'text/plain'
    "TrainingPeaks authentication failed: #{env['sinatra.error'].message}"
  end

  helpers do
    def session
      self.class.session ||= TrainingPeaks::Session.new(settings.training_peaks)
    end
  end
end
