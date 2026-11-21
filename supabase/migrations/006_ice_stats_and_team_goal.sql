-- Mål per lag: träningspass per vecka. Tomt betyder inget mål.
alter table public.teams add column goal_per_week numeric(3,1) check (goal_per_week between 0 and 20);

-- Statistik för en period. Träningar är istid, matcher och övrigt redovisas för sig.
-- Tidiga: börjar före 16:00. Sena: slutar efter 20:00 (går före tidig). Mellan: resten.
-- Delade pass räknas fullt för varje lag, men en gång per förening och en gång i totalen.
create function public.ice_stats(p_from date, p_to date, p_rink uuid default null) returns jsonb
language sql stable security invoker set search_path = ''
as $$
  with b as (
    select id, team_ids, type, untimed, week_start, (end_min - start_min)::int as m,
      case when end_min > 1200 then 'late' when start_min < 960 then 'early' else 'mid' end as slot,
      cardinality(team_ids) > 1 as shared
    from public.bookings
    where (week_start + day) between p_from and p_to and (p_rink is null or rink_id = p_rink)
  ), bt as (
    select b.*, u.tid from b cross join lateral unnest(b.team_ids) as u(tid)
  ), t as (
    select tid,
      count(*) filter (where type = 'traning' and not untimed) as tp,
      coalesce(sum(m) filter (where type = 'traning' and not untimed), 0) as tm,
      count(*) filter (where type = 'traning' and not untimed and slot = 'early') as early,
      count(*) filter (where type = 'traning' and not untimed and slot = 'mid') as mid,
      count(*) filter (where type = 'traning' and not untimed and slot = 'late') as late,
      count(*) filter (where type = 'traning' and not untimed and shared) as shared,
      count(*) filter (where type = 'match') as mp,
      coalesce(sum(m) filter (where type = 'match' and not untimed), 0) as mm,
      count(*) filter (where type = 'ovrigt' and not untimed) as op,
      coalesce(sum(m) filter (where type = 'ovrigt' and not untimed), 0) as om
    from bt group by tid
  ), bo as (
    select distinct bt.id, bt.type, bt.untimed, bt.m, tm.org
    from bt join public.teams tm on tm.id = bt.tid
  ), o as (
    select org,
      count(*) filter (where type = 'traning' and not untimed) as tp,
      coalesce(sum(m) filter (where type = 'traning' and not untimed), 0) as tm,
      count(*) filter (where type = 'match') as mp,
      coalesce(sum(m) filter (where type = 'match' and not untimed), 0) as mm,
      count(*) filter (where type = 'ovrigt' and not untimed) as op,
      coalesce(sum(m) filter (where type = 'ovrigt' and not untimed), 0) as om
    from bo group by org
  ), tot as (
    select
      count(*) filter (where type = 'traning' and not untimed) as tp,
      coalesce(sum(m) filter (where type = 'traning' and not untimed), 0) as tm,
      count(*) filter (where type = 'match') as mp,
      coalesce(sum(m) filter (where type = 'match' and not untimed), 0) as mm,
      count(*) filter (where type = 'ovrigt' and not untimed) as op,
      coalesce(sum(m) filter (where type = 'ovrigt' and not untimed), 0) as om
    from b
  )
  select jsonb_build_object(
    'teams', coalesce((select jsonb_object_agg(tid, to_jsonb(t) - 'tid') from t), '{}'::jsonb),
    'orgs', coalesce((select jsonb_object_agg(org, to_jsonb(o) - 'org') from o), '{}'::jsonb),
    'total', (select to_jsonb(tot) from tot),
    'weeks', (select count(distinct week_start) from b where type = 'traning' and not untimed)
  );
$$;
revoke all on function public.ice_stats(date, date, uuid) from public, anon;
grant execute on function public.ice_stats(date, date, uuid) to authenticated;
