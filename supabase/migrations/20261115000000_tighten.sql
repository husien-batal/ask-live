-- Tighten access: least-privilege grants for the speaker, and private
-- Realtime channels for the projector.

-- ── Speaker grants ──────────────────────────────────────────────────────────
-- The speaker page only ever: creates a session (choosing its code), reads and
-- deletes its sessions, reads its questions and flips `answered`. Everything
-- else is taken away. In particular the speaker can no longer set a session's
-- owner/open/created_at (created_at drives the 4-hour wipe), insert questions
-- directly, or rewrite a question's text.
revoke insert, update on public.sessions  from authenticated;
revoke insert, update on public.questions from authenticated;
grant insert (code)     on public.sessions  to authenticated;
grant update (answered) on public.questions to authenticated;

-- ── Projector channels ──────────────────────────────────────────────────────
-- The projector page follows the speaker over Realtime broadcast channels:
--   proj-<random key>  what to show (QR code, or the opened question)
--   pair-<code>        hands the key to a projector on another device
-- These are now private channels. Anyone may listen (the projector is not
-- signed in), but only a signed-in user may send. With sign-ups off that is
-- the speaker alone, so nobody else can push content or a pairing key to the
-- projector. Client broadcasts are relayed, not stored in this table; the
-- policies are only consulted to authorise the channel.
create policy projector_listen on realtime.messages
  for select to anon, authenticated
  using (
    extension = 'broadcast'
    and (realtime.topic() like 'proj-%' or realtime.topic() like 'pair-%')
  );

create policy speaker_send on realtime.messages
  for insert to authenticated
  with check (
    extension = 'broadcast'
    and (realtime.topic() like 'proj-%' or realtime.topic() like 'pair-%')
  );
