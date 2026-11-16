-- Pass där dagen är känd men inte klockslaget, till exempel matcher som förbundet inte har tidsatt.
-- De visas på raden "Tid saknas" och räknas inte i statistiken (year_stats filtrerar på "not untimed").
alter table public.bookings add column untimed boolean not null default false;

create or replace function public.year_stats(p_year int, p_rink uuid, p_exclude date default null) returns jsonb
language sql stable security invoker set search_path = ''
as $$
  with b as (
    select rink_id, week_start, team_ids, (end_min - start_min)::int as m
    from public.bookings
    where extract(isoyear from week_start) = p_year and not untimed
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
