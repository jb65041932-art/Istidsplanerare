-- Två hallar med egna öppettider, och inbjudna planerare i stället för öppen registrering.

create table public.rinks (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (char_length(name) between 1 and 40),
  sort smallint not null default 0,
  open_hours jsonb not null default '[[420,1350],[420,1350],[420,1350],[420,1350],[420,1350],[420,1350],[420,1350]]'::jsonb,
  buffer_min smallint not null default 10 check (buffer_min between 0 and 60),
  default_len smallint not null default 50 check (default_len between 10 and 240)
);
insert into public.rinks (name, sort, open_hours, buffer_min, default_len)
  select 'Hive Arena', 1, open_hours, buffer_min, default_len from public.settings where id = 1;
insert into public.rinks (name, sort) values ('Uterinken', 2);

alter table public.bookings add column rink_id uuid references public.rinks(id);
update public.bookings set rink_id = (select id from public.rinks where name = 'Hive Arena');
alter table public.bookings alter column rink_id set not null;
drop index public.bookings_week_idx;
create index bookings_rink_week_idx on public.bookings (rink_id, week_start);

drop table public.settings;

alter table public.rinks enable row level security;
revoke all on public.rinks from anon, authenticated;
grant select on public.rinks to anon, authenticated;
grant update on public.rinks to authenticated;

-- Vilka som får ändra schemat. Hanteras bara av edge-funktionen "editors" (service role).
create table public.editors (
  email text primary key check (email = lower(email)),
  role text not null default 'editor' check (role in ('super','editor')),
  invited_by text,
  created_at timestamptz not null default now()
);
insert into public.editors (email, role) select email, 'super' from public.admin_emails;
alter table public.editors enable row level security;
revoke all on public.editors from anon, authenticated;
grant all on public.editors to service_role;

create or replace function private.is_admin() returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from auth.users u
    join public.editors e on e.email = lower(u.email)
    where u.id = (select auth.uid()) and u.email_confirmed_at is not null
  );
$$;

create function private.my_role() returns text
language sql stable security definer set search_path = ''
as $$
  select e.role from auth.users u
  join public.editors e on e.email = lower(u.email)
  where u.id = (select auth.uid()) and u.email_confirmed_at is not null;
$$;
revoke all on function private.my_role() from public, anon;
grant execute on function private.my_role() to authenticated;

create function public.my_role() returns text
language sql stable security invoker set search_path = ''
as $$ select private.my_role(); $$;
revoke all on function public.my_role() from public, anon;
grant execute on function public.my_role() to authenticated;

drop function public.am_i_admin();
drop table public.admin_emails;

create policy "Alla får läsa hallar" on public.rinks for select to anon, authenticated using (true);
create policy "Admin ändrar hallar" on public.rinks for update to authenticated using ((select private.is_admin())) with check ((select private.is_admin()));

-- Statistik för vald hall (utan p_exclude-veckan) och för övriga hallar under samma ISO-år.
drop function public.year_stats(int, date);
create function public.year_stats(p_year int, p_rink uuid, p_exclude date default null) returns jsonb
language sql stable security invoker set search_path = ''
as $$
  with b as (
    select rink_id, week_start, team_ids, (end_min - start_min)::int as m
    from public.bookings
    where extract(isoyear from week_start) = p_year
  ), mine as (
    select * from b where rink_id = p_rink and (p_exclude is null or week_start <> p_exclude)
  ), other as (
    select * from b where rink_id <> p_rink
  ), t as (
    select tid, count(*) as p, sum(mine.m) as m from mine, unnest(mine.team_ids) as tid group by tid
  ), o as (
    select tid, count(*) as p, sum(other.m) as m from other, unnest(other.team_ids) as tid group by tid
  )
  select jsonb_build_object(
    'teams', coalesce((select jsonb_object_agg(tid, jsonb_build_object('p', p, 'm', m)) from t), '{}'::jsonb),
    'total', (select jsonb_build_object('p', count(*), 'm', coalesce(sum(m), 0)) from mine),
    'other_teams', coalesce((select jsonb_object_agg(tid, jsonb_build_object('p', p, 'm', m)) from o), '{}'::jsonb),
    'other_total', (select jsonb_build_object('p', count(*), 'm', coalesce(sum(m), 0)) from other)
  );
$$;
revoke all on function public.year_stats(int, uuid, date) from public;
grant execute on function public.year_stats(int, uuid, date) to anon, authenticated;
