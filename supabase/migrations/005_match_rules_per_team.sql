-- Matchregler per lag: hur mycket istid en match tar före och efter matchstart.
alter table public.teams
  add column match_before smallint not null default 30 check (match_before between 0 and 240),
  add column match_after smallint not null default 180 check (match_after between 0 and 480);
update public.teams set match_after = 120 where name in ('U13', 'U14');

-- Matchstart sparas för sig, så att istiden kan räknas ut från lagets regel.
alter table public.bookings add column match_start smallint check (match_start between 0 and 1439);
update public.bookings
set match_start = substring(note from 'matchstart (\d\d)\.\d\d')::int * 60 + substring(note from 'matchstart \d\d\.(\d\d)')::int,
    note = regexp_replace(note, ',? ?matchstart \d\d\.\d\d', '')
where type = 'match' and note ~ 'matchstart \d\d\.\d\d';
