-- Istidsplanerare: tabeller, regler och statistik.
-- Körs en gång i ett nytt Supabase-projekt. Lägg sedan till admin-adresser i public.admin_emails.

create schema if not exists private;

create table public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 40),
  org text not null default '' check (char_length(org) <= 40),
  color text not null default '#7C8794' check (color ~ '^#[0-9a-fA-F]{6}$'),
  created_at timestamptz not null default now()
);

-- Ett pass. week_start är veckans måndag, day är 0 (måndag) till 6 (söndag),
-- tiderna är minuter efter midnatt.
create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  week_start date not null check (extract(isodow from week_start) = 1),
  day smallint not null check (day between 0 and 6),
  start_min smallint not null check (start_min between 0 and 1430),
  end_min smallint not null check (end_min between 10 and 1440),
  type text not null default 'traning' check (type in ('traning','match','ovrigt')),
  note text not null default '' check (char_length(note) <= 120),
  team_ids uuid[] not null default '{}',
  updated_at timestamptz not null default now(),
  check (end_min > start_min)
);
create index bookings_week_idx on public.bookings (week_start);

create table public.settings (
  id smallint primary key default 1 check (id = 1),
  open_hours jsonb not null,
  buffer_min smallint not null default 10 check (buffer_min between 0 and 60),
  default_len smallint not null default 50 check (default_len between 10 and 240)
);

-- E-postadresser som får ändra schemat. Läses bara av private.is_admin().
create table public.admin_emails (
  email text primary key check (email = lower(email))
);

alter table public.teams enable row level security;
alter table public.bookings enable row level security;
alter table public.settings enable row level security;
alter table public.admin_emails enable row level security;

create function private.is_admin() returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from auth.users u
    join public.admin_emails a on a.email = lower(u.email)
    where u.id = (select auth.uid()) and u.email_confirmed_at is not null
  );
$$;
revoke all on function private.is_admin() from public, anon;
grant usage on schema private to authenticated;
grant execute on function private.is_admin() to authenticated;

create function public.am_i_admin() returns boolean
language sql stable security invoker set search_path = ''
as $$ select private.is_admin(); $$;
revoke all on function public.am_i_admin() from public, anon;
grant execute on function public.am_i_admin() to authenticated;

-- Pass och minuter per lag för ett ISO-år. p_exclude utelämnar en vecka,
-- som sidan i stället räknar själv så att siffrorna följer med direkt vid ändringar.
create function public.year_stats(p_year int, p_exclude date default null) returns jsonb
language sql stable security invoker set search_path = ''
as $$
  with b as (
    select team_ids, (end_min - start_min)::int as m
    from public.bookings
    where extract(isoyear from week_start) = p_year
      and (p_exclude is null or week_start <> p_exclude)
  ), t as (
    select tid, count(*) as p, sum(b.m) as m
    from b, unnest(b.team_ids) as tid
    group by tid
  )
  select jsonb_build_object(
    'teams', coalesce((select jsonb_object_agg(tid, jsonb_build_object('p', p, 'm', m)) from t), '{}'::jsonb),
    'total', (select jsonb_build_object('p', count(*), 'm', coalesce(sum(m), 0)) from b)
  );
$$;
revoke all on function public.year_stats(int, date) from public;
grant execute on function public.year_stats(int, date) to anon, authenticated;

revoke all on public.teams, public.bookings, public.settings, public.admin_emails from anon, authenticated;
grant select on public.teams, public.bookings, public.settings to anon, authenticated;
grant insert, update, delete on public.teams, public.bookings, public.settings to authenticated;

create policy "Alla får läsa lag" on public.teams for select to anon, authenticated using (true);
create policy "Admin lägger till lag" on public.teams for insert to authenticated with check ((select private.is_admin()));
create policy "Admin ändrar lag" on public.teams for update to authenticated using ((select private.is_admin())) with check ((select private.is_admin()));
create policy "Admin tar bort lag" on public.teams for delete to authenticated using ((select private.is_admin()));

create policy "Alla får läsa pass" on public.bookings for select to anon, authenticated using (true);
create policy "Admin lägger till pass" on public.bookings for insert to authenticated with check ((select private.is_admin()));
create policy "Admin ändrar pass" on public.bookings for update to authenticated using ((select private.is_admin())) with check ((select private.is_admin()));
create policy "Admin tar bort pass" on public.bookings for delete to authenticated using ((select private.is_admin()));

create policy "Alla får läsa inställningar" on public.settings for select to anon, authenticated using (true);
create policy "Admin lägger till inställningar" on public.settings for insert to authenticated with check ((select private.is_admin()));
create policy "Admin ändrar inställningar" on public.settings for update to authenticated using ((select private.is_admin())) with check ((select private.is_admin()));

insert into public.settings (id, open_hours)
values (1, '[[420,1350],[420,1350],[420,1350],[420,1350],[420,1350],[420,1350],[420,1350]]'::jsonb);
