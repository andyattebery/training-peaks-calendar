require 'date'
require 'icalendar'
require 'http'
require 'json'
require 'sinatra/base'
require 'sinatra/config_file'
require 'sinatra/multi_route'

class TrainingPeaksCalendar < Sinatra::Base
  register Sinatra::ConfigFile
  register Sinatra::MultiRoute

  config_file 'config.yml'

  LOGIN_URL  = 'https://home.trainingpeaks.com/login'.freeze
  API_HOST   = 'https://tpapi.trainingpeaks.com'.freeze
  USER_AGENT = 'training-peaks-calendar'.freeze

  # The range the official web client asks for: the Monday 16 weeks back
  # through the Sunday 24 weeks ahead.
  WEEKS_BACK    = 16
  WEEKS_FORWARD = 24

  # Workout type ids as observed in live responses. TrainingPeaks publishes no
  # list of these, so it is incomplete by construction — unknown ids fall
  # through to the plain title rather than being treated as an error.
  BIKE            = 2
  YOGA            = 5
  MENTAL_TRAINING = 10

  class LoginFailed    < StandardError; end
  class SessionExpired < StandardError; end

  # TrainingPeaks issues three credentials with three very different lifetimes,
  # and conflating them is what made the old code log in on every request:
  #
  #   Production_tpAuth  long lived; survives logging out of the website
  #   access token       3600 seconds
  #   athlete id         never changes
  #
  # Puma serves on multiple threads, so the cache is mutex guarded.
  class AuthCache
    EXPIRY_MARGIN = 60 # refresh slightly early rather than race the clock

    def initialize
      @mutex = Mutex.new
    end

    def access_token(config)
      @mutex.synchronize do
        return @access_token if @access_token && Time.now < @expires_at

        token, ttl    = exchange(config)
        @access_token = token
        @expires_at   = Time.now + ttl - EXPIRY_MARGIN
        token
      end
    end

    def athlete_id(config, access_token)
      @mutex.synchronize do
        @athlete_id ||= config[:athlete_id] ||
                        TrainingPeaksCalendar.get_user_id(access_token)
      end
    end

    private

    # Retries once, and only for a session cookie we obtained ourselves and can
    # therefore replace. A *failed login* is never retried: each failure
    # increments TrainingPeaks' Attempts counter toward account lockout.
    def exchange(config)
      TrainingPeaksCalendar.get_access_token(session_cookie(config))
    rescue SessionExpired
      raise if config[:auth_cookie] # supplied by hand; we cannot refresh it

      @cookie = nil
      TrainingPeaksCalendar.get_access_token(session_cookie(config))
    end

    def session_cookie(config)
      @cookie ||= config[:auth_cookie] ||
                  TrainingPeaksCalendar.get_auth_cookie(config[:username], config[:password])
    end
  end

  AUTH = AuthCache.new

  get "/", "/training-peaks.ics" do
    content_type "text/calendar"
    attachment "training-peaks.ics"

    config = settings.training_peaks
    token  = AUTH.access_token(config)
    items  = self.class.get_calendar_items(token, AUTH.athlete_id(config, token))

    get_calendar(items)
  end

  error LoginFailed, SessionExpired do
    status 502
    content_type "text/plain"
    "TrainingPeaks authentication failed: #{env['sinatra.error'].message}"
  end

  # Everything that talks to TrainingPeaks. These are class methods because the
  # auth cache calls them outside of any request.
  class << self
    # Logs in and returns the Production_tpAuth session cookie.
    #
    # The login form is ASP.NET MVC with antiforgery protection: a GET sets a
    # __RequestVerificationToken cookie and embeds a different, cryptographically
    # paired value in a hidden field. The POST must carry both. Posting
    # credentials alone — which is what this method used to do — is rejected.
    def get_auth_cookie(username, password)
      page   = HTTP.headers('User-Agent' => USER_AGENT).get(LOGIN_URL)
      cookie = page.cookies.find { |c| c.name == '__RequestVerificationToken' }
      field  = page.to_s[/name="__RequestVerificationToken"[^>]*value="([^"]+)"/, 1]
      raise LoginFailed, 'no antiforgery token on the login page' unless cookie && field

      response =
        HTTP.cookies(:__RequestVerificationToken => cookie.value)
            .headers('User-Agent' => USER_AGENT, 'Referer' => LOGIN_URL)
            .post(LOGIN_URL,
              :form => {
                '__RequestVerificationToken' => field,
                'Username'                   => username,
                'Password'                   => password,
                # reCAPTCHA v3 is on the page but not currently enforced. If
                # logins start failing, suspect this first.
                'CaptchaHidden'              => 'true',
                'CaptchaToken'               => '',
                'Attempts'                   => '',
                'SelectedMfaMethod'          => ''
              })

      # The cookie arrives on the 302 itself, so the redirect is not followed.
      auth = response.cookies.find { |c| c.name == 'Production_tpAuth' }
      raise LoginFailed, "login rejected (HTTP #{response.status})" unless auth

      auth.value
    end

    # Exchanges the session cookie for a bearer token. Returns [token, seconds].
    def get_access_token(auth_cookie)
      response = HTTP.cookies(:Production_tpAuth => auth_cookie)
                     .get("#{API_HOST}/users/v3/token")
      unless response.status.success?
        raise SessionExpired, "token exchange refused (HTTP #{response.status})"
      end

      token = JSON.parse(response.to_s)['token']
      [token['access_token'], token['expires_in'].to_i]
    end

    def get_user_id(access_token)
      response = authorized(access_token).get("#{API_HOST}/users/v3/user")
      unless response.status.success?
        raise SessionExpired, "user lookup refused (HTTP #{response.status})"
      end

      JSON.parse(response.to_s)['user']['userId']
    end

    def get_calendar_items(access_token, athlete_id, window = calendar_window)
      first, last = window
      response = authorized(access_token)
                   .get("#{API_HOST}/fitness/v7/athletes/#{athlete_id}/workouts/#{first}/#{last}")
      unless response.status.success?
        raise SessionExpired, "workout fetch refused (HTTP #{response.status})"
      end

      JSON.parse(response.to_s)
    end

    # Monday of the week WEEKS_BACK ago through Sunday of the week
    # WEEKS_FORWARD ahead. Ruby's % returns non-negative, so a Sunday walks
    # back six days to Monday rather than forward one.
    def calendar_window(today = Date.today)
      first  = today - WEEKS_BACK * 7
      first -= (first.wday - 1) % 7
      last   = today + WEEKS_FORWARD * 7
      last  += (7 - last.wday) % 7
      [first, last]
    end

    private

    def authorized(access_token)
      HTTP.auth("Bearer #{access_token}")
    end
  end

  helpers do
    def get_calendar(items)
      cal = Icalendar::Calendar.new
      items.each do |i|
        event = Icalendar::Event.new

        workout_date = Date.parse(i['workoutDay'])
        event.dtstart     = Icalendar::Values::Date.new(workout_date)
        event.dtend       = Icalendar::Values::Date.new(workout_date.next_day)
        event.summary     = get_title(i)
        event.description = get_description(i)

        cal.add_event(event)
      end

      cal.publish

      cal.to_ical
    end

    def get_title(item)
      title = case item['workoutTypeValueId']
              when BIKE            then "🚴‍: #{item['title']}"
              when YOGA            then "🧘‍: #{item['title'].sub('Yoga:', '').strip}"
              when MENTAL_TRAINING then "🧠: #{item['title']}"
              else item['title']
              end

      "#{title}#{" ✅" if completed?(item)}"
    end

    # Both fields are checked because this account has no completed workouts,
    # so there is no evidence for which one TrainingPeaks actually populates.
    def completed?(item)
      item['completed'] == true || !item['startTime'].nil?
    end

    def get_description(item)
      description = String.new
      description << "Time: #{get_time(item['totalTimePlanned'])}\n" if item['totalTimePlanned']
      description << "TSS: #{item['tssPlanned']}\n" if item['tssPlanned']
      description << "\n" if !description.empty?
      description << item['description'] if item['description']

      description
    end

    def get_time(fractional_hours)
      Time.at(fractional_hours * 3600).utc.strftime("%H:%M")
    end
  end
end
