-- Statistiken visas bara för inloggade planerare.
revoke execute on function public.year_stats(int, uuid, date) from anon;
