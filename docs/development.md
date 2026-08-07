# Development notes

TrainingPeaks has no public API for this. Everything here was worked out by observing the official web
client, and none of it is documented or guaranteed. This file records what is known so it does not have to be
rediscovered — the last rediscovery took a whole session.

## Layout

| file | holds |
|---|---|
| `app.rb` | the web layer only — two routes, the 502 handler, config wiring |
| `lib/training_peaks.rb` | module namespace and the two error classes |
| `lib/training_peaks/client.rb` | stateless HTTP. Every method makes exactly the request it names |
| `lib/training_peaks/session.rb` | stateful policy: what to cache, how long, and when to retry |
| `lib/training_peaks/workout.rb` | the model, and the only place that knows TrainingPeaks' field names |
| `lib/workout_calendar.rb` | presentation: emoji, title and description formatting, ICS |

The split that matters is **client versus session**: the client knows *how* to make a request, the session
decides *whether* to. The lockout-protection rule lives in the session for that reason.

The other one is **model versus calendar**: `Workout` is what TrainingPeaks said, `WorkoutCalendar` is how we
show it. Emoji belong strictly in the latter — an earlier version encoded `YOGA = 5` as though the API meant
yoga by it, which it does not (5 is Crosstrain).

## The authentication chain

Three steps, three hosts. Getting workout data requires all of them, in order.

```
1. POST https://home.trainingpeaks.com/login          -> sets the Production_tpAuth cookie
2. GET  https://tpapi.trainingpeaks.com/users/v3/token -> exchanges that cookie for a bearer token
3. GET  https://tpapi.trainingpeaks.com/fitness/v7/... -> Authorization: Bearer <token>
```

**`Production_tpAuth` is still the real credential.** It is tempting to conclude that bearer tokens replaced
it — they did not. The token sits *on top of* the cookie: the cookie is what authorises step 2, and step 2 is
the only way to mint a token. Losing sight of this is an easy and expensive mistake.

### Step 1 — the login POST

The login form is ASP.NET MVC with antiforgery protection, so credentials alone are rejected. A `GET` of the
login page sets a `__RequestVerificationToken` cookie *and* embeds a different, cryptographically paired value
in a hidden form field. The `POST` must carry both.

The form fields that work:

| field | value |
|---|---|
| `__RequestVerificationToken` | the hidden-field value from the same GET |
| `Username`, `Password` | credentials |
| `CaptchaHidden` | `"true"` |
| `CaptchaToken`, `Attempts`, `SelectedMfaMethod` | empty strings |

Send a `User-Agent` and `Referer`. **Do not follow the redirect** — on success the response is a `302` to
`app.trainingpeaks.com` and the cookie arrives on the 302 itself.

Field names are capitalised now, but ASP.NET model binding is case-insensitive, so lowercase keys bind fine.
That was never the failure.

### Step 2 — the token exchange

`GET /users/v3/token` with the cookie returns:

```json
{ "success": true,
  "token": { "access_token": "...", "token_type": "bearer", "expires_in": 3600,
             "refresh_token": "...", "scope": "... fitness ...", "expires": "..." } }
```

The `scope` must include `fitness` for step 3 to work.

A `refresh_token` is issued, but **the refresh endpoint has never been observed.** Do not write refresh logic
against a guessed URL. Re-exchanging the cookie is simpler and is known to work.

### Step 3 — the workouts

```
GET /fitness/v7/athletes/{athleteId}/workouts/{startDate}/{endDate}
```

Dates are `YYYY-MM-DD`. The response is a bare JSON array of workout objects.

## Endpoint versions

Version drift is the single most likely way this app breaks again.

| endpoint | status |
|---|---|
| `fitness/v1` … `v5` | **gone** — 404 |
| `fitness/v6`, `fitness/v7` | live; the web client uses v7 |
| `users/v3/user` | live |
| `users/v3/token` | live |

A `404` means the route is gone. A `401` means the route exists and wants credentials. That distinction is how
the above was established — but see [Hazards](#hazards) before probing anything.

## Caching

Three credentials, three lifetimes. Conflating them is what made the original code log in on *every single
request*, which is actively harmful given the lockout counter.

| value | lifetime | where |
|---|---|---|
| athlete id | never changes | cached for the process lifetime |
| access token | 3600 seconds | refreshed 60s early |
| `Production_tpAuth` | long lived; survives logout | re-obtained only when a token exchange is refused |

`TrainingPeaks::Session` in [`lib/training_peaks/session.rb`](../lib/training_peaks/session.rb) implements
this and is mutex-guarded, since puma serves on several threads. `config/puma.rb` deliberately runs `workers 0` — the cache is in process memory, so each extra
worker would maintain its own cookie and token, meaning one login per worker rather than one login overall.

## Hazards

Rules, not trivia. Each of these was learned the hard way.

- **Never auto-retry a failed login.** Every failure increments TrainingPeaks' `Attempts` counter and moves
  the account toward lockout. `Session#exchange` retries only for a *session cookie it obtained itself and
  can replace*, never for a rejected credential.
- **Do not probe endpoints unauthenticated to discover routes.** Sweeping URLs to see what returns 404 versus
  401 is exactly the traffic that gets an IP flagged. The version table above is already the answer; if you
  need more, read it off a real browser session.
- **`Production_tpAuth` is not revoked by logging out.** This was verified: a token exchange using a cookie
  from a logged-out session still succeeded. It is a self-contained encrypted ticket, valid until it expires
  on its own. Treat any leaked cookie as live. What *does* revoke it is unknown; a password change may well
  not.
- **reCAPTCHA v3 is present on the login page but is not currently enforced.** Headless login works today. If
  logins suddenly start failing, this is the first suspect, and the fallback is putting a browser-captured
  cookie in `config.yml` as `auth_cookie`.

## The workout payload

Nine fields drive the calendar. `TrainingPeaks::Workout.from_api` is the **only** place that knows these
names — everything downstream reads the model's accessors, so a renamed API field costs one method:

| API field | model accessor | notes |
|---|---|---|
| `workoutDay` | `date` | `"2026-08-06T00:00:00"`; `Date.parse` handles it |
| `title` | `title` | |
| `workoutTypeValueId` | `sport_id` | see below |
| `workoutSubTypeId` | `subtype_id` | usually nil; a **separate namespace** from `sport_id` |
| `totalTimePlanned` | `planned_duration` | **fractional hours**, not minutes — `0.5` is 30 minutes. Often nil |
| `tssPlanned` | `planned_tss` | float, frequently nil |
| `description` | `description` | plain text, not HTML; multi-line; unicode throughout |
| `completed` | `completed` | nil on planned work |
| `startTime` | `started_at` | nil on planned work; carried only because `completed?` reads it |

`planned_duration` and `planned_tss` are nil often enough that the guards in
`WorkoutCalendar#description_for` are load-bearing, not defensive padding.

`Workout#formatted_duration` renders `"HH:MM"` and **counts past 24 hours**. An earlier version formatted a
`Time`, which wrapped: 25.5 hours came out as `01:30`. It truncates rather than rounds, matching that older
behaviour so existing feeds do not shift by a minute.

### Workout type ids

**Authoritative.** `GET /fitness/v6/workouttypes` (bearer token) returns the whole list. Retrieved
2026-08-06; regenerate it rather than trusting this table:

```ruby
JSON.parse(HTTP.auth("Bearer #{token}")
  .get("https://tpapi.trainingpeaks.com/fitness/v6/workouttypes").to_s)
```

| id | name | subtypes |
|---|---|---|
| 1 | Swim | 1 Open Water, 2 Pool |
| 2 | Bike | 3 Road, 4 Gravel, 5 Track, 6 Indoor, 7 Cyclocross, 8 E-Bike, 9 Hand Cycling, 47 Time Trial, 49 Virtual |
| 3 | Run | 10 Road, 11 Track, 12 Trail, 13 Indoor, 50 Virtual |
| 4 | Brick | — |
| 5 | Crosstrain | — |
| 6 | Race | — |
| 7 | Day Off | — |
| 8 | Mountain Bike | 14 XC, 15 Enduro, 16 Downhill, 17 Short Track, 18 Fat Bike, 19 E-MTB |
| 9 | Strength | — |
| 10 | Custom | — |
| 11 | XC-Ski | 26 Classic, 27 Skate, 28 Alpine, 29 Touring, 30 Mountaineering, 31 Biathlon, 32 Roller, 33 Nordic Combined, 34 Split Board, 46 Cross Country |
| 12 | Rowing | 39 Indoor, 51 Virtual |
| 13 | Walk | 41 Hike, 42 Treadmill, 43 Mountaineering, 44 Hunting |
| 29 | Strength *(newer family)* | 20 Mobility, 21 Functional Fitness, 22 Yoga, 23 Rock Climbing, 24 Hybrid Strength, 25 Stretching |
| 100 | Other | 35 Canoe, 36 SUP, 37 Sailing, 38 Kayak, 40 Surfing, 45 Speed Skating, 48 Equestrian |

Unknown ids must still fall through to the plain title — the list can grow, and an unrecognised id is not an
error.

#### Two traps in the id spaces

**`workoutTypeValueId` and `workoutSubTypeId` are separate namespaces, and they overlap.** Values 1–13 and 29
appear in both, meaning different things: subtype `2` is "Pool Swim" while type `2` is "Bike". Never look up
one in the other's map. `WorkoutCalendar` keeps `SPORT_EMOJI` and `SUBTYPE_EMOJI` separate for exactly this
reason, and `TrainingPeaks::Workout` names them `sport_id` and `subtype_id` so the two cannot be confused at
a call site.

**Subtype ids are globally unique** — 51 subtypes numbered 1–51, with no value reused across parent types.
That is what makes a single flat `SUBTYPE_EMOJI` map correct instead of needing `(type, subtype)` pairs. If
TrainingPeaks ever adds a colliding subtype, that assumption breaks.

#### There is no Yoga type

Yoga is subtype **22 under type 29 (Strength)**. It has never been a top-level type. Note also that *two*
Strength types exist — 9 and 29 — and only 29 carries subtypes.

#### Personal naming conventions, which are not API semantics

`WorkoutCalendar#personal_override` matches on **titles**, not ids, and applies only to this athlete's data:

- Sufferfest files yoga under **Crosstrain (5)** with a `Yoga:` title prefix. Type 5 does not mean yoga.
- Sufferfest files its mental-training modules under **Custom (10)** titled `MTP - …`. Type 10 does not mean
  mental training.

Both were previously encoded as `YOGA = 5` and `MENTAL_TRAINING = 10`, which asserted things about the API
that are false. Keep title-based rules in `personal_override` so the id maps stay honest.

### Completion

`TrainingPeaks::Workout#completed?` marks a workout done if **either** `completed == true` **or** `startTime` is non-nil.

Both are checked because there is no evidence for which one TrainingPeaks populates: the account has no
workout history at all, so every sampled workout has both fields nil. If real completed workouts ever appear,
check which field is actually set and simplify this.

## The date window

Monday of the week 16 weeks back through Sunday of the week 24 weeks ahead — 287 days. This is not arbitrary:
it reproduces the range the TrainingPeaks web client requests, exactly, verified against a live browser
session.

Ruby's `%` returns non-negative results, which is what makes the Sunday edge case work — `(0 - 1) % 7 == 6`,
so a Sunday walks back six days to Monday rather than forward one.

## Tests

```sh
bundle exec rake
```

The whole suite runs with `WebMock.disable_net_connect!`, so it needs no network and no credentials — an
unstubbed request fails the test rather than quietly reaching TrainingPeaks. That is structural, not a
convention to remember.

`test/fixtures/workouts.json` is a **sanitised** copy of a real v7 response: identical keys, identical nil
pattern (1 of 15 has no `totalTimePlanned`, 8 have no `tssPlanned`), identical type distribution, but
invented titles and descriptions. Regenerate it from a real dump rather than editing it by hand — a
hand-written fixture drifts from the nil pattern, which is the part that actually catches bugs.

### What the tests are protecting

Most of them are ordinary, but three encode rules that are easy to "simplify" into breakage:

- **`test_rejected_hand_supplied_cookie_never_attempts_a_login`** — asserts *zero* requests to the login URL.
  A pasted `auth_cookie` cannot be refreshed by logging in, so retrying would burn attempts against the
  `Attempts` lockout counter for nothing.
- **`test_expired_token_is_re_exchanged_without_logging_in_again`** — an expired token needs a new token, not
  a new session. Getting this wrong means one login per hour, forever.
- **`test_subtype_ids_are_not_looked_up_as_sport_ids`** — the two id namespaces overlap; see the traps above.

These assert on **request counts**, not return values, because the damage they prevent is invisible from a
return value.

### Working against real data

Point the same code at a real dump when you need to:

```ruby
require './app'

workouts = JSON.parse(File.read('scratch/workouts.json'))
                .map { |hash| TrainingPeaks::Workout.from_api(hash) }
puts WorkoutCalendar.new(workouts).to_ics
```

Or drive the real thing end to end, which needs credentials in `config.yml`:

```ruby
session = TrainingPeaks::Session.new(TrainingPeaksCalendar.settings.training_peaks)
puts WorkoutCalendar.new(session.workouts).to_ics
```

`scratch/` is gitignored: those dumps are real training data. Capture one from DevTools by copying the
response of the `fitness/v7/.../workouts/...` request.

Round-tripping through `Icalendar::Calendar.parse` is worth doing after any change to rendering — it catches
emoji and line-folding damage that eyeballing the output will not.
