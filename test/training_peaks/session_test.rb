# frozen_string_literal: true

require 'test_helper'

# The rules encoded here are about *not making requests*. They assert on request
# counts rather than return values, because the failure they guard against —
# hammering TrainingPeaks' login endpoint — is invisible from a return value.
class SessionTest < Minitest::Test
  def session(**overrides)
    TrainingPeaks::Session.new(config(**overrides))
  end

  # The most important test in the suite.
  #
  # A hand-supplied auth_cookie cannot be refreshed by logging in — we were given
  # it, we cannot regenerate it. Retrying the login would burn attempts against
  # TrainingPeaks' `Attempts` lockout counter to no purpose whatsoever.
  def test_rejected_hand_supplied_cookie_never_attempts_a_login
    stub_login_page
    stub_login_post
    stub_token(status: 401)

    assert_raises(TrainingPeaks::SessionExpired) do
      session(auth_cookie: 'stale-pasted-cookie').workouts
    end

    assert_not_requested :get,  FixtureHelpers::LOGIN_URL
    assert_not_requested :post, FixtureHelpers::LOGIN_URL
  end

  # A cookie we obtained ourselves *can* be replaced, so exactly one retry is
  # correct — and exactly one, not a loop.
  def test_rejected_self_obtained_cookie_triggers_exactly_one_relogin
    stub_login_page
    stub_login_post
    stub_workouts
    stub_request(:get, FixtureHelpers::TOKEN_URL).to_return(
      { status: 401 },
      { status: 200, body: { 'token' => { 'access_token' => 'fresh', 'expires_in' => 3600 } }.to_json }
    )

    assert_equal 15, session(athlete_id: 1_234_567).workouts.size

    assert_requested :post, FixtureHelpers::LOGIN_URL, times: 2 # initial + one retry
    assert_requested :get,  FixtureHelpers::TOKEN_URL, times: 2
  end

  def test_a_second_failure_after_relogin_propagates_rather_than_looping
    stub_login_page
    stub_login_post
    stub_token(status: 401)

    assert_raises(TrainingPeaks::SessionExpired) { session.workouts }

    assert_requested :post, FixtureHelpers::LOGIN_URL, times: 2
  end

  def test_token_is_cached_within_its_lifetime
    stub_full_chain
    tp = session(athlete_id: 1_234_567)

    3.times { tp.workouts }

    assert_requested :post, FixtureHelpers::LOGIN_URL, times: 1
    assert_requested :get,  FixtureHelpers::TOKEN_URL, times: 1
  end

  # An expired token needs a new token, not a new session. Logging in again here
  # would mean one login per hour forever.
  def test_expired_token_is_re_exchanged_without_logging_in_again
    stub_login_page
    stub_login_post
    stub_workouts
    stub_token(expires_in: 0) # already past the safety margin
    tp = session(athlete_id: 1_234_567)

    2.times { tp.workouts }

    assert_requested :get,  FixtureHelpers::TOKEN_URL, times: 2
    assert_requested :post, FixtureHelpers::LOGIN_URL, times: 1
  end

  # Was `test_athlete_id_comes_from_config_without_any_lookup`. athlete_id is
  # private now, so this drives #workouts — the assertion is unchanged.
  def test_configured_athlete_id_skips_the_user_lookup_entirely
    stub_full_chain(athlete_id: 999)

    session(athlete_id: 999).workouts

    assert_not_requested :get, FixtureHelpers::USER_URL
    assert_requested :get, %r{/fitness/v7/athletes/999/workouts/}
  end

  # Was `test_athlete_id_is_looked_up_once_and_then_cached`.
  def test_athlete_id_is_looked_up_once_and_then_cached
    stub_full_chain(athlete_id: 4242)
    stub_user(athlete_id: 4242)
    tp = session # no athlete_id configured

    3.times { tp.workouts }

    assert_requested :get, FixtureHelpers::USER_URL, times: 1
    assert_requested :get, %r{/fitness/v7/athletes/4242/workouts/}, times: 3
  end

  def test_workouts_are_returned_as_models_not_hashes
    stub_full_chain

    result = session(athlete_id: 1_234_567).workouts

    assert result.all?(TrainingPeaks::Workout), 'expected TrainingPeaks::Workout instances'
  end
end
