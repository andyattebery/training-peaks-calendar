# `bind` only. Setting `port` as well would be a second listener on the same
# port, and puma collides with itself (EADDRINUSE).
bind "tcp://#{ENV.fetch('BIND', '0.0.0.0')}:#{ENV.fetch('PORT', 50990)}"

environment ENV.fetch("RACK_ENV", "production")

threads Integer(ENV.fetch("MIN_THREADS", 1)), Integer(ENV.fetch("MAX_THREADS", 5))

# Single process on purpose. The auth cache in app.rb lives in process memory,
# so each extra worker would keep its own cookie and token — one login per
# worker instead of one login overall.
workers 0
