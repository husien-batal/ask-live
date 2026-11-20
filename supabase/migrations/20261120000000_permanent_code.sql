-- Permanent code per speaker.
--
-- Each speaker account owns one room with a code that never changes (unless
-- the speaker changes it), so a QR code can be printed once and reused.
-- A printed code is not a way in: ask() only accepts a question while that
-- speaker has a session running, exactly as before. Between sessions the
-- link answers 'ended' and nothing is stored.
--
-- Sessions are now created only by start_session(), which always uses the
-- caller's own room code. The speaker can no longer insert a session with a
-- code of their choosing, so nobody can open a session under someone else's
-- code.

create extension if not exists pgcrypto with schema extensions;

create table public.rooms (
  owner uuid primary key references auth.users(id) on delete cascade,
  code text unique not null check (code ~ '^[A-Z2-9]{6}$'),
  created_at timestamptz not null default now()
);
alter table public.rooms enable row level security;
grant select on public.rooms to authenticated;
create policy own_room on public.rooms for select to authenticated
  using (owner = (select auth.uid()));

-- 6 characters, no look-alikes (0/O, 1/I/L). Rejection sampling keeps every
-- character equally likely. Skips codes in use by any room or live session.
create function public.random_code() returns text
language plpgsql volatile set search_path = '' as $$
declare
  abc constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  b bytea;
  i int;
  c text;
begin
  loop
    c := '';
    while char_length(c) < 6 loop
      b := extensions.gen_random_bytes(16);
      i := 0;
      while i < 16 and char_length(c) < 6 loop
        if get_byte(b, i) < 248 then
          c := c || substr(abc, get_byte(b, i) % 31 + 1, 1);
        end if;
        i := i + 1;
      end loop;
    end loop;
    exit when not exists (select 1 from public.rooms where code = c)
          and not exists (select 1 from public.sessions where code = c);
  end loop;
  return c;
end;
$$;

-- The caller's permanent code; creates their room on first use.
create function public.my_room() returns text
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  c text;
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  select code into c from public.rooms where owner = me;
  if c is null then
    insert into public.rooms (owner, code) values (me, public.random_code())
    on conflict (owner) do nothing;
    select code into c from public.rooms where owner = me;
  end if;
  return c;
end;
$$;

-- Starts a session under the caller's permanent code. If one is already
-- running (say, in another tab) it is returned instead of starting a second.
create function public.start_session() returns public.sessions
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  s public.sessions;
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  select * into s from public.sessions
   where owner = me order by created_at desc limit 1;
  if found then return s; end if;
  insert into public.sessions (code, owner)
  values (public.my_room(), me)
  returning * into s;
  return s;
end;
$$;

-- Replaces the caller's code, for when a printed code has been misused.
-- Only between sessions, so a running session never changes code mid-class.
create function public.new_room_code() returns text
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  c text;
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  if exists (select 1 from public.sessions where owner = me) then
    raise exception 'End the running session before changing the code.';
  end if;
  perform public.my_room();
  c := public.random_code();
  update public.rooms set code = c where owner = me;
  return c;
end;
$$;

-- Supabase grants execute on new functions to anon and authenticated by
-- default, so revoke explicitly.
revoke execute on function public.random_code()   from public, anon, authenticated;
revoke execute on function public.my_room()       from public, anon;
revoke execute on function public.start_session() from public, anon;
revoke execute on function public.new_room_code() from public, anon;
grant  execute on function public.my_room()       to authenticated;
grant  execute on function public.start_session() to authenticated;
grant  execute on function public.new_room_code() to authenticated;

-- Sessions are created only through start_session().
revoke insert (code) on public.sessions from authenticated;
revoke insert        on public.sessions from authenticated;

-- Lets the student page show whether a code is live before anyone types, and
-- keep Send disabled until it is. Reveals nothing ask() does not already
-- reveal; ask() still refuses questions on its own when no session runs.
create function public.session_status(p_code text) returns text
language sql stable security definer set search_path = '' as $$
  select case when exists (
    select 1 from public.sessions
     where code = upper(btrim(coalesce(p_code, ''))) and open
  ) then 'open' else 'closed' end;
$$;
revoke execute on function public.session_status(text) from public;
grant  execute on function public.session_status(text) to anon, authenticated;
