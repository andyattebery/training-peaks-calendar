# frozen_string_literal: true

module TrainingPeaks
  # Decides *when* to call the API, and caches what comes back.
  #
  # TrainingPeaks issues three credentials with three very different lifetimes,
  # and conflating them is what made an earlier version log in on every request:
  #
  #   Production_tpAuth  long lived; survives logging out of the website
  #   access token       3600 seconds
  #   athlete id         never changes
  #
  # Puma serves on multiple threads, so the cache is mutex guarded.
  #
  # `config` is read with STRING keys. sinatra-contrib parses config.yml into an
  # IndifferentHash where either would work, but a plain Hash — what
  # `set :training_peaks, {...}` or a bare YAML.load_file gives — only has
  # string keys, and symbol lookups against one fail silently: the cookie looks
  # absent and the app logs in with nil credentials instead.
  class Session
    EXPIRY_MARGIN = 60 # refresh slightly early rather than race the clock

    def initialize(config, client: Client.new)
      @config = config
      @client = client
      @mutex  = Mutex.new
    end

    # The only method the web layer needs: the full token -> athlete id -> fetch
    # chain, with each step cached on its own schedule.
    def workouts
      token = access_token
      client.workouts(token, athlete_id(token))
    end

    private

    attr_reader :config, :client

    def access_token
      @mutex.synchronize do
        return @access_token if @access_token && Time.now < @expires_at

        token, ttl    = exchange
        @access_token = token
        @expires_at   = Time.now + ttl - EXPIRY_MARGIN
        token
      end
    end

    # `token` rather than `access_token` — the latter would shadow the private
    # method of that name inside this body.
    def athlete_id(token)
      @mutex.synchronize do
        @athlete_id ||= config['athlete_id'] || client.fetch_athlete_id(token)
      end
    end

    # Retries once, and only for a session cookie we obtained ourselves and can
    # therefore replace. A *failed login* is never retried: each failure
    # increments TrainingPeaks' Attempts counter toward account lockout.
    def exchange
      client.access_token(session_cookie)
    rescue SessionExpired
      raise if config['auth_cookie'] # supplied by hand; we cannot refresh it

      @cookie = nil
      client.access_token(session_cookie)
    end

    def session_cookie
      @cookie ||= config['auth_cookie'] ||
                  client.login(config['username'], config['password'])
    end
  end
end
