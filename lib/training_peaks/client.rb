# frozen_string_literal: true

require 'date'
require 'http'
require 'json'

module TrainingPeaks
  # Stateless HTTP against TrainingPeaks. Every method performs exactly the
  # request it names and caches nothing — deciding *when* to call these is
  # Session's job.
  class Client
    LOGIN_URL  = 'https://home.trainingpeaks.com/login'
    API_HOST   = 'https://tpapi.trainingpeaks.com'
    USER_AGENT = 'training-peaks-calendar'

    # The range the official web client asks for: the Monday 16 weeks back
    # through the Sunday 24 weeks ahead.
    WEEKS_BACK    = 16
    WEEKS_FORWARD = 24

    # Logs in and returns the Production_tpAuth session cookie.
    #
    # The login form is ASP.NET MVC with antiforgery protection: a GET sets a
    # __RequestVerificationToken cookie and embeds a different, cryptographically
    # paired value in a hidden field. The POST must carry both — posting
    # credentials alone is rejected.
    def login(username, password)
      page   = HTTP.headers('User-Agent' => USER_AGENT).get(LOGIN_URL)
      cookie = page.cookies.find { |c| c.name == '__RequestVerificationToken' }
      field  = page.to_s[/name="__RequestVerificationToken"[^>]*value="([^"]+)"/, 1]
      raise LoginFailed, 'no antiforgery token on the login page' unless cookie && field

      response =
        HTTP.cookies(__RequestVerificationToken: cookie.value)
            .headers('User-Agent' => USER_AGENT, 'Referer' => LOGIN_URL)
            .post(LOGIN_URL,
                  form: {
                    '__RequestVerificationToken' => field,
                    'Username' => username,
                    'Password' => password,
                    # reCAPTCHA v3 is on the page but not currently enforced.
                    # If logins start failing, suspect this first.
                    'CaptchaHidden' => 'true',
                    'CaptchaToken' => '',
                    'Attempts' => '',
                    'SelectedMfaMethod' => ''
                  })

      # The cookie arrives on the 302 itself, so the redirect is not followed.
      auth = response.cookies.find { |c| c.name == 'Production_tpAuth' }
      raise LoginFailed, "login rejected (HTTP #{response.status})" unless auth

      auth.value
    end

    # Exchanges the session cookie for a bearer token. Returns [token, seconds].
    def access_token(auth_cookie)
      response = HTTP.cookies(Production_tpAuth: auth_cookie).get("#{API_HOST}/users/v3/token")
      unless response.status.success?
        raise SessionExpired, "token exchange refused (HTTP #{response.status})"
      end

      token = JSON.parse(response.to_s)['token']
      [token['access_token'], token['expires_in'].to_i]
    end

    # Named for the request it makes, so call sites can see it costs a
    # round-trip — unlike Session#athlete_id, which is cached.
    def fetch_athlete_id(access_token)
      response = authorized(access_token).get("#{API_HOST}/users/v3/user")
      raise SessionExpired, "user lookup refused (HTTP #{response.status})" unless response.status.success?

      JSON.parse(response.to_s)['user']['userId']
    end

    def workouts(access_token, athlete_id, window = calendar_window)
      response = authorized(access_token)
                 .get("#{API_HOST}/fitness/v7/athletes/#{athlete_id}/workouts/#{window.first}/#{window.last}")
      unless response.status.success?
        raise SessionExpired, "workout fetch refused (HTTP #{response.status})"
      end

      JSON.parse(response.to_s).map { |hash| Workout.from_api(hash) }
    end

    # Monday of the week WEEKS_BACK ago through Sunday of the week
    # WEEKS_FORWARD ahead. Ruby's % returns non-negative, so a Sunday walks
    # back six days to Monday rather than forward one.
    def calendar_window(today = Date.today)
      first  = today - (WEEKS_BACK * 7)
      first -= (first.wday - 1) % 7
      last   = today + (WEEKS_FORWARD * 7)
      last  += (7 - last.wday) % 7
      first..last
    end

    private

    def authorized(access_token) = HTTP.auth("Bearer #{access_token}")
  end
end
