-- Förberedelser för export till kommunens bokningssystem (Actor Smartbook):
-- hallregister med objekt-id, kundregister med kundnummer, lagens Smartbook-typer,
-- bokningsnummer, exportlogg samt roller med behörighet per hall.

-- 1. Hallregister
alter table public.rinks add column actor_id integer, add column actor_name text;
update public.rinks set actor_id = 3, actor_name = 'Ishall A' where name = 'Hive Arena';
update public.rinks set name = 'Björknäs uterink', actor_id = 6, actor_name = 'Uterink' where name = 'Uterinken';

-- 2. Kundregister. Lagens fält "org" är kundens namn. Nya namn får en kundrad automatiskt.
create sequence public.customer_no_seq start 9001;
create table public.customers (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (char_length(name) between 1 and 40),
  kund_nr integer not null unique default nextval('public.customer_no_seq'),
  created_at timestamptz not null default now()
);
insert into public.customers (name) select org from (select distinct org from public.teams where org <> '') s order by org;

create function private.ensure_customer() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.org <> '' then
    insert into public.customers (name) values (new.org) on conflict (name) do nothing;
  end if;
  return new;
end $$;
create trigger teams_ensure_customer after insert or update of org on public.teams
  for each row execute function private.ensure_customer();

-- 3. Lagens typer i Smartbook. Förifyllda gissningar som ska gås igenom.
alter table public.teams add column actor_activity text not null default 'Ishockey', add column actor_group text;
update public.teams set
  actor_activity = case when name ~* 'konståk' then 'Konståkning' when name ~* 'isvård|ispistvård|stängd' then 'Övrig aktivitet' else 'Ishockey' end,
  actor_group = case
    when name ~* 'gymnasi' then 'Skolverksamhet'
    when name ~* 'U19D|dam' then 'Jun dam'
    when name ~* 'U18|U20|J18|J20' then 'Jun herr'
    when name ~* 'a-lag' then 'Senior herr'
    when name ~* '^U ?(9|1[0-6])$|U15|U8|skills' then 'Ungd. pojk'
    when name ~* 'hockeyskola' then 'Ungdom upp till 16 år'
    else 'Blandad ålder' end;

-- 4. Bokningsnummer: ett löpnummer per pass som följer med i exporten.
create sequence public.booking_no_seq start 100001;
alter table public.bookings add column booking_no bigint;
update public.bookings b set booking_no = s.no
from (select id, 100000 + row_number() over (order by week_start, day, start_min, id) as no from public.bookings) s
where s.id = b.id;
select setval('public.booking_no_seq', (select coalesce(max(booking_no), 100000) from public.bookings));
alter table public.bookings alter column booking_no set default nextval('public.booking_no_seq'), alter column booking_no set not null;
create unique index bookings_booking_no_idx on public.bookings (booking_no);
grant usage on sequence public.booking_no_seq to authenticated;

-- 5. Roller och behörighet per hall. super och kommun når alla hallar, planerare de tilldelade.
alter table public.editors drop constraint editors_role_check;
alter table public.editors add constraint editors_role_check check (role in ('super','kommun','editor'));
alter table public.editors add column rink_ids uuid[] not null default '{}';
update public.editors set rink_ids = (select array_agg(id) from public.rinks) where role = 'editor';

create function private.can_edit_rink(p_rink uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from auth.users u join public.editors e on e.email = lower(u.email)
    where u.id = (select auth.uid()) and u.email_confirmed_at is not null
      and (e.role in ('super','kommun') or p_rink = any(e.rink_ids))
  );
$$;
create function private.is_manager() returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from auth.users u join public.editors e on e.email = lower(u.email)
    where u.id = (select auth.uid()) and u.email_confirmed_at is not null and e.role in ('super','kommun')
  );
$$;
create function private.my_access() returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object('role', e.role, 'rinks', case when e.role = 'editor' then to_jsonb(e.rink_ids) else null end)
  from auth.users u join public.editors e on e.email = lower(u.email)
  where u.id = (select auth.uid()) and u.email_confirmed_at is not null;
$$;
revoke all on function private.can_edit_rink(uuid), private.is_manager(), private.my_access() from public, anon;
grant execute on function private.can_edit_rink(uuid), private.is_manager(), private.my_access() to authenticated;

create function public.my_access() returns jsonb
language sql stable security invoker set search_path = ''
as $$ select private.my_access(); $$;
revoke all on function public.my_access() from public, anon;
grant execute on function public.my_access() to authenticated;

drop policy "Admin lägger till pass" on public.bookings;
drop policy "Admin ändrar pass" on public.bookings;
drop policy "Admin tar bort pass" on public.bookings;
create policy "Planerare lägger till pass i sina hallar" on public.bookings for insert to authenticated with check ((select private.can_edit_rink(rink_id)));
create policy "Planerare ändrar pass i sina hallar" on public.bookings for update to authenticated using ((select private.can_edit_rink(rink_id))) with check ((select private.can_edit_rink(rink_id)));
create policy "Planerare tar bort pass i sina hallar" on public.bookings for delete to authenticated using ((select private.can_edit_rink(rink_id)));

-- Planerare får ändra öppettider i sina hallar, men inte namn eller Smartbook-uppgifter.
drop policy "Admin ändrar hallar" on public.rinks;
create policy "Planerare ändrar sina hallar" on public.rinks for update to authenticated using ((select private.can_edit_rink(id))) with check ((select private.can_edit_rink(id)));
revoke update on public.rinks from authenticated;
grant update (open_hours, buffer_min, default_len) on public.rinks to authenticated;

create function public.set_rink_actor(p_rink uuid, p_actor_id integer, p_actor_name text) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.is_manager() then raise exception 'not allowed' using errcode = '42501'; end if;
  update public.rinks set actor_id = p_actor_id, actor_name = nullif(btrim(p_actor_name), '') where id = p_rink;
end $$;
revoke all on function public.set_rink_actor(uuid, integer, text) from public, anon;
grant execute on function public.set_rink_actor(uuid, integer, text) to authenticated;

-- Kundregistret: inloggade läser, super och kommun ändrar.
alter table public.customers enable row level security;
revoke all on public.customers from anon, authenticated;
grant select, update on public.customers to authenticated;
create policy "Inloggade läser kunder" on public.customers for select to authenticated using (true);
create policy "Super och kommun ändrar kunder" on public.customers for update to authenticated using ((select private.is_manager())) with check ((select private.is_manager()));

-- 6. Exportlogg: vad som senast skickades till Smartbook för varje pass.
-- Ett pass är nytt om det saknas här, ändrat om signaturen skiljer sig och borttaget om passet inte finns kvar.
create table public.exports (
  booking_id uuid primary key,
  booking_no bigint not null,
  rink_id uuid not null,
  day_date date not null,
  start_min smallint not null,
  end_min smallint not null,
  summary text not null default '',
  sig text not null,
  exported_at timestamptz not null default now()
);
alter table public.exports enable row level security;
revoke all on public.exports from anon, authenticated;
grant select, insert, update, delete on public.exports to authenticated;
create policy "Super och kommun läser exportloggen" on public.exports for select to authenticated using ((select private.is_manager()));
create policy "Super och kommun skriver exportloggen" on public.exports for insert to authenticated with check ((select private.is_manager()));
create policy "Super och kommun uppdaterar exportloggen" on public.exports for update to authenticated using ((select private.is_manager())) with check ((select private.is_manager()));
create policy "Super och kommun rensar exportloggen" on public.exports for delete to authenticated using ((select private.is_manager()));
