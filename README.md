# training-peaks-calendar

Serves your TrainingPeaks planned workouts as an iCalendar feed, so you can subscribe to your training plan
from Apple Calendar, Google Calendar, or anything else that speaks `.ics`. It logs into TrainingPeaks on your
behalf, fetches a rolling window of workouts, and renders them as calendar events.

## Setup

Create `config.yml` in the project root:

```yaml
training_peaks:
  username: your_trainingpeaks_username
  password: your_trainingpeaks_password
```

That is the whole configuration. Your athlete id is looked up automatically.

`config.yml` is gitignored. Keep it that way — see [Security](#security).

<details>
<summary>Optional overrides</summary>

```yaml
training_peaks:
  username: your_trainingpeaks_username
  password: your_trainingpeaks_password

  # Skip the athlete-id lookup. Only useful if the lookup ever breaks.
  athlete_id: 1234567

  # Skip logging in and use a Production_tpAuth cookie captured from a browser
  # session. A fallback in case TrainingPeaks starts enforcing its CAPTCHA on
  # scripted logins. See docs/development.md.
  auth_cookie: "V0011x0J..."
```
</details>

## Running it

```sh
bundle install
bundle exec puma
```

Then subscribe your calendar client to:

```
http://localhost:50990/
```

`http://localhost:50990/training-peaks.ics` serves the same feed, if your client wants a `.ics` extension.

Set `PORT`, `BIND`, `MIN_THREADS` or `MAX_THREADS` to change how it listens.

## Running it in Docker

A published multi-arch image (amd64 and arm64) is available, or you can build your own:

```sh
# Use the published image
docker pull ghcr.io/andyattebery/training-peaks-calendar:latest

# …or build locally
docker build -t training-peaks-calendar .
```

Either way, run it with `config.yml` mounted:

```sh
docker run --rm -p 50990:50990 \
  -v "$PWD/config.yml:/app/config.yml:ro" \
  ghcr.io/andyattebery/training-peaks-calendar:latest
```

`config.yml` is **mounted, not copied into the image.** It holds credentials, and the TrainingPeaks session
cookie derived from them cannot be revoked on demand — logging out of the website does not invalidate it.
Anything baked into an image layer stays in that layer, so the file is excluded via `.dockerignore` and
supplied at run time instead. Mounting it `:ro` keeps the container from writing to it.

### Docker Compose

For anything long-running, Compose is easier — a calendar feed wants to come back after a reboot:

```yaml
services:
  training-peaks-calendar:
    image: ghcr.io/andyattebery/training-peaks-calendar:latest
    # Swap the line above for `build: .` to run your own build instead.
    ports:
      - "50990:50990"
    volumes:
      - ./config.yml:/app/config.yml:ro
    restart: unless-stopped
```

```sh
docker compose up -d
docker compose logs -f
```

Then subscribe to `http://<host>:50990/`.

Pin to a version tag rather than `:latest` if you would rather upgrade deliberately — `:latest` only ever
points at a non-prerelease release.

### Configuration

Both forms accept the same environment variables:

| variable | default | |
|---|---|---|
| `PORT` | `50990` | port inside the container |
| `BIND` | `0.0.0.0` | interface to listen on |
| `MIN_THREADS` | `1` | puma thread floor |
| `MAX_THREADS` | `5` | puma thread ceiling |
| `RACK_ENV` | `production` | |

Run one instance. The app caches its TrainingPeaks session in process memory, so each extra replica means
another login — and failed logins count against an account lockout counter.

## What the feed contains

A rolling window of roughly four months back to six months ahead, aligned to whole weeks — the same range the
TrainingPeaks web app itself requests.

Each workout becomes an all-day event, prefixed by its sport:

| | | | | | |
|---|---|---|---|---|---|
| 🏊 | Swim | 🚵 | Mountain Bike | 🚣 | Rowing |
| 🚴 | Bike | 🏋️ | Strength | 🚶 | Walk |
| 🏃 | Run | ⛷️ | XC-Ski | 🧘 | Yoga, Mobility, Stretching |
| 🔁 | Brick | 🏁 | Race | 🧗 | Rock Climbing |
| 🤸 | Crosstrain | 😴 | Day Off | 🥾 | Hike |

Custom and Other workouts get no prefix, as do sports TrainingPeaks adds in future. A ✅ is appended to
workouts you have completed.

Two extras specific to a Sufferfest plan: Crosstrain sessions titled `Yoga: …` are shown as 🧘 with the
prefix stripped, and Custom `MTP - …` mental-training modules as 🧠.

The event description carries planned duration and TSS where TrainingPeaks provides them, followed by the
workout's full description.

## Security

`config.yml` contains your TrainingPeaks password. It is gitignored and excluded from Docker builds, and it
should never be committed or copied into an image.

Be aware that the session cookie this app obtains **survives logging out of the TrainingPeaks website.** If
one leaks, logging out will not revoke it; it stays valid until it expires on its own.

## Development

```sh
bundle exec rake
```

The test suite needs no network and no credentials — every HTTP call is stubbed, and an unstubbed one fails
the test rather than reaching TrainingPeaks.

See [docs/development.md](docs/development.md) for how the TrainingPeaks API is reached, which endpoints are
current, the workout type ids, and the rules the tests exist to protect.
