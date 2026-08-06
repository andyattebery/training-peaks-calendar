# Development notes

TrainingPeaks has no public API for this. Everything here was worked out by observing the official web
client, and none of it is documented or guaranteed. This file records what is known so it does not have to be
rediscovered — the last rediscovery took a whole session.

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

`AuthCache` in [`app.rb`](../app.rb) implements this and is mutex-guarded, since puma serves on several
threads. `config/puma.rb` deliberately runs `workers 0` — the cache is in process memory, so each extra
worker would maintain its own cookie and token, meaning one login per worker rather than one login overall.

## Hazards

Rules, not trivia. Each of these was learned the hard way.

- **Never auto-retry a failed login.** Every failure increments TrainingPeaks' `Attempts` counter and moves
  the account toward lockout. `AuthCache#exchange` retries only for a *session cookie it obtained itself and
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

Seven fields drive the calendar. All were confirmed present on live v7 responses:

| field | notes |
|---|---|
| `workoutDay` | `"2026-08-06T00:00:00"`; `Date.parse` handles it |
| `title` | |
| `workoutTypeValueId` | see below |
| `totalTimePlanned` | **fractional hours**, not minutes — `0.5` is 30 minutes. Often nil |
| `tssPlanned` | float, frequently nil |
| `description` | plain text, not HTML; multi-line; unicode throughout |
| `startTime` | nil on planned work |

`totalTimePlanned` and `tssPlanned` are nil often enough that the guards in `get_description` are load-bearing,
not defensive padding.

### Workout type ids

**Observed, not documented, and certainly incomplete.** Unknown ids fall through to the plain title, which is
the correct behaviour — do not turn an unrecognised id into an error.

| id | meaning |
|---|---|
| 2 | Bike |
| 5 | Yoga |
| 7 | Rest |
| 10 | Mental training (the `MTP - …` entries) |

Type 5 has never appeared in a live response for this account; the yoga branch is carried on the strength of
the original author having written it, not on evidence.

### Completion

`get_title` marks a workout done if **either** `completed == true` **or** `startTime` is non-nil.

Both are checked because there is no evidence for which one TrainingPeaks populates: the account has no
workout history at all, so every sampled workout has both fields nil. If real completed workouts ever appear,
check which field is actually set and simplify this.

## The date window

Monday of the week 16 weeks back through Sunday of the week 24 weeks ahead — 287 days. This is not arbitrary:
it reproduces the range the TrainingPeaks web client requests, exactly, verified against a live browser
session.

Ruby's `%` returns non-negative results, which is what makes the Sunday edge case work — `(0 - 1) % 7 == 6`,
so a Sunday walks back six days to Monday rather than forward one.

## Testing offline

The calendar logic needs no network and no credentials. Save a real v7 response and render it directly:

```ruby
require './app'
app   = TrainingPeaksCalendar.new!          # new! gets the raw instance, not the Rack wrapper
items = JSON.parse(File.read('scratch/workouts.json'))
puts app.get_calendar(items)
```

Useful checks:

```ruby
app.get_title(items.first)                                   # emoji branch
app.completed?(items.first.merge('completed' => true))       # done marker
TrainingPeaksCalendar.calendar_window(Date.new(2026, 8, 6))  # => 2026-04-13 .. 2027-01-24
```

`scratch/` is gitignored: those dumps are real training data. Capture one from DevTools by copying the
response of the `fitness/v7/.../workouts/...` request.

Round-tripping through `Icalendar::Calendar.parse` is worth doing after any change to the rendering — it
catches emoji and line-folding damage that eyeballing the output will not.
