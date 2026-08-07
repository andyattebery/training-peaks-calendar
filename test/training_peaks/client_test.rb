# frozen_string_literal: true

require 'test_helper'

class ClientTest < Minitest::Test
  def setup
    @client = TrainingPeaks::Client.new
  end

  # --- login ---------------------------------------------------------------

  def test_login_sends_both_halves_of_the_antiforgery_pair
    stub_login_page(token: 'form-value')
    stub_login_post(cookie: 'the-session')

    assert_equal 'the-session', @client.login('user', 'pass')

    assert_requested :post, FixtureHelpers::LOGIN_URL do |req|
      body = URI.decode_www_form(req.body).to_h
      body['__RequestVerificationToken'] == 'form-value' &&
        body['Username'] == 'user' &&
        body['Password'] == 'pass' &&
        req.headers['Cookie'].to_s.include?('__RequestVerificationToken=antiforgery-cookie')
    end
  end

  # If the page shape changes, fail before posting credentials rather than after.
  def test_missing_antiforgery_token_raises_without_posting_credentials
    stub_login_page(body: '<html><body>no token here</body></html>')
    stub_login_post

    assert_raises(TrainingPeaks::LoginFailed) { @client.login('user', 'pass') }

    assert_not_requested :post, FixtureHelpers::LOGIN_URL
  end

  def test_login_without_an_auth_cookie_in_the_response_raises
    stub_login_page
    stub_login_post(cookie: nil, status: 200) # the login page re-rendered = rejected

    assert_raises(TrainingPeaks::LoginFailed) { @client.login('user', 'pass') }
  end

  # --- access_token --------------------------------------------------------

  def test_access_token_returns_the_token_and_its_lifetime
    stub_token(access_token: 'abc', expires_in: 3600)

    assert_equal ['abc', 3600], @client.access_token('cookie')

    assert_requested :get, FixtureHelpers::TOKEN_URL do |req|
      req.headers['Cookie'].to_s.include?('Production_tpAuth=cookie')
    end
  end

  def test_rejected_token_exchange_raises_session_expired
    stub_token(status: 401)

    assert_raises(TrainingPeaks::SessionExpired) { @client.access_token('cookie') }
  end

  # --- fetch_athlete_id ----------------------------------------------------

  def test_fetch_athlete_id_reads_the_user_payload
    stub_user(athlete_id: 4242)

    assert_equal 4242, @client.fetch_athlete_id('tok')
  end

  def test_rejected_user_lookup_raises_session_expired
    stub_request(:get, FixtureHelpers::USER_URL).to_return(status: 401)

    assert_raises(TrainingPeaks::SessionExpired) { @client.fetch_athlete_id('tok') }
  end

  # --- workouts ------------------------------------------------------------

  def test_workouts_are_fetched_from_v7_with_a_bearer_token
    stub_workouts(athlete_id: 55)

    items = @client.workouts('tok', 55, Date.new(2026, 4, 13)..Date.new(2027, 1, 24))

    assert_equal 15, items.size
    assert_requested :get,
                     'https://tpapi.trainingpeaks.com/fitness/v7/athletes/55/workouts/2026-04-13/2027-01-24',
                     headers: { 'Authorization' => 'Bearer tok' }
  end

  def test_workouts_are_parsed_into_models
    stub_workouts(athlete_id: 55)

    items = @client.workouts('tok', 55)

    assert items.all?(TrainingPeaks::Workout)
    assert_equal Date.new(2026, 8, 6), items.first.date
  end

  def test_rejected_workout_fetch_raises_session_expired
    stub_request(:get, %r{/fitness/v7/}).to_return(status: 401)

    assert_raises(TrainingPeaks::SessionExpired) { @client.workouts('tok', 1) }
  end

  # --- calendar_window -----------------------------------------------------

  # Reproduces the range the TrainingPeaks web client itself requests.
  def test_window_matches_the_official_web_client
    window = @client.calendar_window(Date.new(2026, 8, 6))

    assert_equal Date.new(2026, 4, 13), window.first
    assert_equal Date.new(2027, 1, 24), window.last
  end

  # Ruby's % returns non-negative, which is what makes the Sunday edge work:
  # (0 - 1) % 7 == 6, so a Sunday walks back six days rather than forward one.
  def test_window_always_spans_monday_to_sunday
    [Date.new(2026, 8, 3),  # Monday
     Date.new(2026, 8, 9),  # Sunday
     Date.new(2026, 8, 6),  # Thursday
     Date.new(2027, 1, 1),  # year boundary
     Date.new(2024, 2, 29)  # leap day
    ].each do |today|
      window = @client.calendar_window(today)

      assert_equal 1, window.first.wday, "#{today} produced a #{window.first.strftime('%A')} start"
      assert_equal 0, window.last.wday,  "#{today} produced a #{window.last.strftime('%A')} end"
      assert_equal 287, window.count, "#{today} produced an odd-length window"
    end
  end
end
