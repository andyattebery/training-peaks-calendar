# frozen_string_literal: true

ENV['RACK_ENV'] = 'production'

# http-cookie 1.0.5 trips Ruby 3.4's chilled-string warning on every cookie
# parse, burying real test output. Warning[:deprecated] does not cover this
# category, so filter it by message. Only third-party paths are silenced.
module SilenceDependencyWarnings
  def warn(message, category: nil)
    return if message.include?('literal string will be frozen') && message.include?('/gems/')

    super
  end
end
Warning.extend(SilenceDependencyWarnings)

require 'minitest/autorun'
require 'rack/test'
require 'webmock/minitest'
require 'json'

# Any request that is not explicitly stubbed fails the test. This is what makes
# "the suite needs no network" structural rather than merely asserted — and it
# keeps a bug in the session from quietly hitting TrainingPeaks for real.
WebMock.disable_net_connect!

require './app'

module FixtureHelpers
  FIXTURE_PATH = File.expand_path('fixtures/workouts.json', __dir__)

  LOGIN_URL = 'https://home.trainingpeaks.com/login'
  TOKEN_URL = 'https://tpapi.trainingpeaks.com/users/v3/token'
  USER_URL  = 'https://tpapi.trainingpeaks.com/users/v3/user'

  # Sanitised copy of a real v7 response: same keys, same nil pattern, same
  # type distribution, invented titles and descriptions. See docs/development.md.
  def raw_workouts
    @raw_workouts ||= JSON.parse(File.read(FIXTURE_PATH))
  end

  def workouts
    @workouts ||= raw_workouts.map { |hash| TrainingPeaks::Workout.from_api(hash) }
  end

  # A single workout with fields overridden by name. Compare with the old
  # helper, which merged raw API keys — a typo there was a silent nil.
  def workout(**overrides)
    workouts.first.with(**overrides)
  end

  def calendar(items = workouts) = WorkoutCalendar.new(items)

  # --- request stubs -------------------------------------------------------

  def login_page_body(token: 'antiforgery-form-value')
    <<~HTML
      <html><body><form method="post">
      <input name="__RequestVerificationToken" type="hidden" value="#{token}" />
      <input name="Username" type="text" />
      </form></body></html>
    HTML
  end

  def stub_login_page(token: 'antiforgery-form-value', body: nil)
    stub_request(:get, LOGIN_URL).to_return(
      status: 200,
      body: body || login_page_body(token: token),
      headers: { 'Set-Cookie' => '__RequestVerificationToken=antiforgery-cookie; path=/; HttpOnly' }
    )
  end

  def stub_login_post(cookie: 'session-cookie', status: 302)
    headers = {}
    headers['Set-Cookie'] = "Production_tpAuth=#{cookie}; path=/" if cookie
    stub_request(:post, LOGIN_URL).to_return(status: status, headers: headers)
  end

  def stub_token(access_token: 'bearer-token', expires_in: 3600, status: 200)
    stub_request(:get, TOKEN_URL).to_return(
      status: status,
      body: {
        'success' => true,
        'token' => {
          'access_token' => access_token,
          'token_type' => 'bearer',
          'expires_in' => expires_in,
          'scope' => 'fitness users'
        }
      }.to_json
    )
  end

  def stub_user(athlete_id: 1_234_567)
    stub_request(:get, USER_URL)
      .to_return(status: 200, body: { 'user' => { 'userId' => athlete_id } }.to_json)
  end

  def stub_workouts(athlete_id: 1_234_567, items: nil)
    stub_request(:get, %r{/fitness/v7/athletes/#{athlete_id}/workouts/})
      .to_return(status: 200, body: (items || raw_workouts).to_json)
  end

  # Everything a session needs to reach the API without logging in.
  def stub_full_chain(athlete_id: 1_234_567)
    stub_login_page
    stub_login_post
    stub_token
    stub_workouts(athlete_id: athlete_id)
  end

  def config(**overrides)
    { 'username' => 'user', 'password' => 'pass' }.merge(overrides.transform_keys(&:to_s))
  end
end

module Minitest
  class Test
    include FixtureHelpers
  end
end
