# ask-live

Live anonymous Q&A for a class. Students scan a QR code and send a question;
it appears on the speaker's screen straight away. Ending the session deletes
every question.

Static pages + Supabase (Postgres, Auth, Realtime). No server code.

| File | Who opens it | What it does |
| --- | --- | --- |
| `index.html` | Speaker | Sign in, start a session, live question list, mark answered, end |
| `p.html` | Projector | Opened from the speaker page. Shows the QR code, then only the question the speaker opens |
| `s.html` | Students | One small page (about 2.5 KB gzipped): type a question, send |
| `supabase/migrations/` | — | Tables, security policies, the `ask` function, the 4-hour cleanup job |

## How it fits together

- Students have no table access. Their only door is the `ask(p_code, p_body, p_id)`
  database function, called with the project's publishable key.
- `p_id` is a random id the student page makes per question, so an automatic
  retry on a bad connection never adds the question twice.
- Spam limit: 60 questions per minute per session. Nothing about the sender is
  read or stored.
- The speaker signs in with one Supabase Auth account. Row-level security
  limits them to their own sessions. The sign-in is kept in `sessionStorage`
  (that tab only).
- End deletes the session row; questions go with it (`on delete cascade`).
  A `pg_cron` job deletes any session older than 4 hours.
- The projector window gets its content from the speaker page over a
  `BroadcastChannel`, so both must be windows of the same browser.

## Run locally

```sh
npx supabase start          # API on :55321, database on :55322
npx serve .                 # or any static file server
```

Create a local speaker account (sign-ups are off):

```sh
npx supabase status -o env  # copy SERVICE_ROLE_KEY
curl -X POST http://127.0.0.1:55321/auth/v1/admin/users \
  -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"email":"speaker@example.com","password":"choose-one","email_confirm":true}'
```

The pages pick the back end by hostname: `localhost`, `127.*`, `10.*` and
`192.168.*` use the local stack; anything else uses the hosted project. The
URL and publishable key for both are at the top of each page's script.

## Hosted project

- Schema changes: add a file under `supabase/migrations/`, then `npx supabase db push`.
- Authentication → Users: add the speaker account.
- Authentication → Sign In / Providers: turn off "Allow new users to sign up".
- Free projects pause after about 7 days without activity. Open the dashboard
  before class if it has been a while.
