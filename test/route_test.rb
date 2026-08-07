# frozen_string_literal: true

require 'test_helper'

class RouteTest < Minitest::Test
  include Rack::Test::Methods

  def app = TrainingPeaksCalendar

  # Injecting a fresh session per test is the whole point of holding it in
  # settings rather than a constant — the previous version had to
  # remove_const(:AUTH) to stop state leaking between tests.
  def setup
    TrainingPeaksCalendar.set :session, TrainingPeaks::Session.new(config(athlete_id: 1_234_567))
  end

  def test_serves_the_calendar_at_both_paths
    stub_full_chain

    ['/', '/training-peaks.ics'].each do |path|
      get path

      assert_equal 200, last_response.status, path
      assert_match %r{^text/calendar}, last_response.headers['content-type']
      assert_includes last_response.headers['content-disposition'], 'training-peaks.ics'
      assert last_response.body.start_with?('BEGIN:VCALENDAR')
      assert_equal workouts.size, last_response.body.scan('BEGIN:VEVENT').size
    end
  end

  # A broken session should surface as a readable error, not a stack trace or a
  # 500 that looks like a bug in this app.
  def test_authentication_failure_renders_a_502
    stub_login_page
    stub_login_post
    stub_token(status: 401)

    get '/'

    assert_equal 502, last_response.status
    assert_match %r{^text/plain}, last_response.headers['content-type']
    assert_includes last_response.body, 'TrainingPeaks authentication failed'
  end

  def test_login_failure_renders_a_502
    stub_login_page(body: '<html>no antiforgery token</html>')

    get '/'

    assert_equal 502, last_response.status
    assert_includes last_response.body, 'TrainingPeaks authentication failed'
  end

  # One login and one token exchange should serve many calendar requests.
  def test_repeated_requests_reuse_the_cached_session
    stub_full_chain

    3.times { get '/' }

    assert_requested :post, FixtureHelpers::LOGIN_URL, times: 1
    assert_requested :get,  FixtureHelpers::TOKEN_URL, times: 1
  end
end
