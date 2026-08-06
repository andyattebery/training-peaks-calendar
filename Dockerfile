# Pinned to a minor version. `ruby:3` floats across major-version-adjacent
# releases and silently changed under this project once already.
ARG RUBY_VERSION=3.4-slim

FROM ruby:${RUBY_VERSION} AS builder

# http, puma, nio4r and unf_ext all build native extensions. These packages are
# needed to compile them and are deliberately left behind in the builder stage.
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config set --local frozen true \
 && bundle config set --local without development:test \
 && bundle install --jobs 4 --retry 3 \
 && rm -rf /usr/local/bundle/cache


FROM ruby:${RUBY_VERSION}

ENV APP_HOME=/app \
    BUNDLE_FROZEN=true \
    RACK_ENV=production \
    PORT=50990

WORKDIR $APP_HOME

COPY --from=builder /usr/local/bundle /usr/local/bundle

# COPY, not ADD — ADD also unpacks archives and fetches URLs, neither of which
# is wanted here. .dockerignore keeps config.yml out of this layer.
COPY . $APP_HOME

RUN useradd --create-home --shell /usr/sbin/nologin app \
 && chown -R app:app $APP_HOME
USER app

EXPOSE 50990

# puma discovers config/puma.rb and config.ru on its own. Not `rackup`: rack 3
# moved that binary into a separate gem which this project does not depend on.
CMD ["bundle", "exec", "puma"]
