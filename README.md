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

```sh
docker build -t training-peaks-calendar .
docker run --rm -p 50990:50990 \
  -v "$PWD/config.yml:/app/config.yml:ro" \
  training-peaks-calendar
```

`config.yml` is **mounted, not copied into the image.** It holds credentials, and the TrainingPeaks session
cookie derived from them cannot be revoked on demand — logging out of the website does not invalidate it.
Anything baked into an image layer stays in that layer, so the file is excluded via `.dockerignore` and
supplied at run time instead.

## What the feed contains

A rolling window of roughly four months back to six months ahead, aligned to whole weeks — the same range the
TrainingPeaks web app itself requests.

Each workout becomes an all-day event:

| | |
|---|---|
| 🚴 | Bike workouts |
| 🧘 | Yoga |
| 🧠 | Mental training |
| *(no prefix)* | Everything else, including rest days |
| ✅ | Suffixed to workouts you have completed |

The event description carries planned duration and TSS where TrainingPeaks provides them, followed by the
workout's full description.

## Security

`config.yml` contains your TrainingPeaks password. It is gitignored and excluded from Docker builds, and it
should never be committed or copied into an image.

Be aware that the session cookie this app obtains **survives logging out of the TrainingPeaks website.** If
one leaks, logging out will not revoke it; it stays valid until it expires on its own.

## Development

See [docs/development.md](docs/development.md) for how the TrainingPeaks API is reached, which endpoints are
current, and how to work on the calendar logic offline without credentials.
