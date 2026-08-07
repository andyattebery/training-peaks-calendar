# frozen_string_literal: true

# Everything that knows TrainingPeaks exists.
#
# TrainingPeaks publishes no public API for this; see docs/development.md for
# how the three-step auth chain and the endpoint versions were established.
module TrainingPeaks
  # The login POST was rejected. Never retried automatically — each failure
  # increments TrainingPeaks' Attempts counter toward account lockout.
  class LoginFailed < StandardError; end

  # A session cookie was refused. Recoverable by logging in again, but only if
  # we obtained the cookie ourselves; see Session#exchange.
  class SessionExpired < StandardError; end
end

require_relative 'training_peaks/workout'
require_relative 'training_peaks/client'
require_relative 'training_peaks/session'
