-- Live Anonymous Q&A — Plan C schema.
--
-- Students never touch a table: their only door is public.ask(). The speaker
-- (one Supabase Auth account) has full access to their own sessions and
-- nothing else. Ending a session deletes its row; the cascade removes every
-- question with it.

create table public.sessions (
  id uuid primary key default gen_random_uuid(),
  code text unique not null check (code ~ '^[A-Z2-9]{6}$'),
  owner uuid not null default auth.uid(),
  open boolean not null default true,
  created_at timestamptz not null default now()
);
create table public.questions (
  id bigint generated always as identity primary key,
  session_id uuid not null references public.sessions(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 280),
  answered boolean not null default false,
  -- random id chosen by the student's page, so a retry of a question that
  -- already arrived is ignored. It identifies the question, not the sender.
  client_id uuid unique,
  created_at timestamptz not null default now()
);
create index questions_session_idx on public.questions (session_id, id);

alter table public.sessions  enable row level security;
alter table public.questions enable row level security;

-- students: no table access at all, only this function.
-- Returns 'ok', 'ended' (no open session with that code), 'invalid' (empty or
-- over 280 characters) or 'busy' (the session got 60 questions in the last
-- minute — the spam limit; nothing about the sender is looked at or stored).
create function public.ask(p_code text, p_body text, p_id uuid default null)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_session uuid;
  v_body text := btrim(coalesce(p_body, ''));
begin
  select id into v_session from public.sessions
   where code = upper(btrim(coalesce(p_code, ''))) and open;
  if v_session is null then return 'ended'; end if;
  if char_length(v_body) not between 1 and 280 then return 'invalid'; end if;
  if p_id is not null and exists
     (select 1 from public.questions where client_id = p_id) then
    return 'ok';
  end if;
  -- one ask at a time per session, so the count below can't be raced
  perform pg_advisory_xact_lock(hashtextextended(v_session::text, 0));
  if (select count(*) from public.questions
       where session_id = v_session
         and created_at > now() - interval '1 minute') >= 60 then
    return 'busy';
  end if;
  insert into public.questions (session_id, body, client_id)
  values (v_session, v_body, p_id)
  on conflict (client_id) do nothing;
  return 'ok';
end;
$$;
revoke execute on function public.ask(text, text, uuid) from public;
grant execute on function public.ask(text, text, uuid) to anon, authenticated;

-- speaker: full access to own sessions only
grant select, insert, update, delete on public.sessions, public.questions to authenticated;
create policy own_sessions on public.sessions for all to authenticated
  using (owner = (select auth.uid())) with check (owner = (select auth.uid()));
create policy own_questions on public.questions for all to authenticated
  using (exists (select 1 from public.sessions s
                 where s.id = session_id and s.owner = (select auth.uid())));
alter publication supabase_realtime add table public.questions;

-- backup wipe: any session older than 4 hours is deleted (questions cascade)
create extension if not exists pg_cron;
select cron.schedule('wipe-old-sessions', '*/15 * * * *',
  $$delete from public.sessions where created_at < now() - interval '4 hours'$$);
