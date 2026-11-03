\set ON_ERROR_STOP 1
-- Test users (a..g). Inserting into auth.users fires the profile trigger.
insert into auth.users(id,email)
select ('00000000-0000-0000-0000-00000000000' || x)::uuid, x || '@test.local'
from unnest(array['a','b','c','d','e','f','1']) x
on conflict do nothing;

create or replace function pg_temp.as_user(uid text, r text default 'authenticated') returns void
language plpgsql as $$ begin
  perform set_config('request.jwt.claim.sub', coalesce(uid,''), true);
  execute format('set local role %I', r);
end $$;

-- 1. profile + preferences auto-created; share_location defaults to off
do $$ begin
  assert (select count(*) from public.profiles) = 7, 'profiles not created';
  assert (select count(*) from public.user_preferences where share_location = false) = 7, 'prefs/share default wrong';
end $$;

-- 2. anon cannot submit
do $$ begin
  perform pg_temp.as_user(null, 'anon');
  begin perform public.submit_report('police', 51.5, -0.12);
    raise exception 'anon submit should fail';
  exception when insufficient_privilege then null; end;
end $$;

-- 3. submit, dedupe, self-vote block, confirmations
do $$
declare r1 public.reports; r2 public.reports; r3 public.reports; mins numeric;
begin
  perform pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
  r1 := public.submit_report('police', 51.5074, -0.1278, 90::smallint, 'Mobile unit');
  assert r1.status = 'active' and r1.confirmations = 1, 'new report wrong';
  mins := extract(epoch from (r1.expires_at - now()))/60;
  assert mins between 44 and 46, 'police TTL not ~45m: ' || mins;

  perform pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
  r2 := public.submit_report('police', 51.5076, -0.1278, 100::smallint);   -- ~22m away, similar heading
  assert r2.id = r1.id and r2.confirmations = 2, 'dedupe failed';

  -- opposite direction is NOT a duplicate for directional categories
  r3 := public.submit_report('police', 51.5074, -0.1278, 270::smallint);
  assert r3.id <> r1.id, 'opposite-direction report wrongly deduped';
  perform set_config('test.r1', r1.id::text, false);
  perform set_config('test.r3', r3.id::text, false);

  perform pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
  r1 := public.submit_report('police', 51.5074, -0.1278, 90::smallint);    -- own dup: no-op
  assert r1.confirmations = 2, 'author resubmit changed counts';
  begin perform public.vote_report(r1.id, 'confirm'); raise exception 'self vote allowed';
  exception when insufficient_privilege then null; end;
end $$;

-- 4. denials clear a report; reputation effects; no votes on inactive reports
do $$
declare rid uuid := current_setting('test.r1')::uuid; r public.reports; rep numeric;
begin
  perform pg_temp.as_user('00000000-0000-0000-0000-00000000000c'); r := public.vote_report(rid,'deny');
  perform pg_temp.as_user('00000000-0000-0000-0000-00000000000d'); r := public.vote_report(rid,'deny');
  assert r.status = 'active', 'cleared too early';
  perform pg_temp.as_user('00000000-0000-0000-0000-00000000000e'); r := public.vote_report(rid,'deny');
  assert r.status = 'cleared' and r.denials = 3, 'not cleared after 3 denials';
  begin perform public.vote_report(rid,'confirm'); raise exception 'vote on cleared allowed';
  exception when no_data_found then null; end;
  reset role;
  select reputation into rep from public.profiles where id = '00000000-0000-0000-0000-00000000000a';
  assert rep = -0.75, 'author reputation expected -0.75 got ' || rep;
end $$;

-- 5. rate limit: 5 reports / 10 min
do $$ declare i int; begin
  perform pg_temp.as_user('00000000-0000-0000-0000-00000000000f');
  for i in 1..5 loop perform public.submit_report('road_hazard', 52.0 + i*0.1, -1.0); end loop;
  begin perform public.submit_report('road_hazard', 53.0, -1.0); raise exception 'rate limit not enforced';
  exception when program_limit_exceeded then null; end;
end $$;

-- 6. RLS / privileges
do $$ begin
  perform pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
  begin insert into public.reports(category,lat,lng,geom,expires_at)
        values ('police',0,0,'POINT(0 0)'::extensions.geography, now()+interval '1h');
        raise exception 'direct insert allowed';
  exception when insufficient_privilege then null; end;
  begin update public.profiles set reputation = 100 where id = auth.uid();
        raise exception 'reputation self-edit allowed';
  exception when insufficient_privilege then null; end;
  assert (select count(*) from public.user_preferences) = 1, 'prefs leak across users';
  assert (select count(*) from public.report_authors) <= 1, 'authors leak across users';
  perform pg_temp.as_user(null, 'anon');
  begin perform 1 from public.report_authors; raise exception 'anon read report_authors';
  exception when insufficient_privilege then null; end;
  begin perform public.expire_reports(); raise exception 'anon ran expire_reports';
  exception when insufficient_privilege then null; end;
end $$;

-- 7. privacy: public reports table has no user identifier
do $$ begin
  assert (select count(*) from information_schema.columns
          where table_schema='public' and table_name='reports' and column_name like '%user%') = 0,
         'reports exposes user id';
end $$;

-- 8. nearby query, expiry job, retention purge
do $$ declare n int; begin
  perform pg_temp.as_user(null, 'anon');
  select count(*) into n from public.reports_nearby(52.1, -1.0, 2000); assert n >= 1, 'nearby missed report';
  select count(*) into n from public.reports_nearby(55.0, -3.0, 2000); assert n = 0, 'nearby false positive';
  reset role;
  update public.reports set expires_at = now() - interval '1 minute' where category = 'road_hazard';
  perform pg_temp.as_user(null, 'service_role');
  assert public.expire_reports() >= 5, 'expire_reports did nothing';
  reset role;
  assert (select count(*) from public.reports where category='road_hazard' and status='expired') >= 5, 'not expired';
  update public.reports set expires_at = now() - interval '31 days' where status = 'expired';
  perform pg_temp.as_user(null, 'service_role'); perform public.purge_old_data(); reset role;
  assert (select count(*) from public.reports where status = 'expired') = 0, 'purge failed';
end $$;

-- 9. recent destinations capped at 50
do $$ declare i int; begin
  perform pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
  for i in 1..55 loop
    insert into public.recent_destinations(user_id,label,lat,lng,used_at)
    values (auth.uid(), 'Place ' || i, 51.5, -0.1, now() - make_interval(secs => 60-i));
  end loop;
  assert (select count(*) from public.recent_destinations) = 50, 'recents not pruned to 50';
end $$;

-- 10. GDPR erasure: deleting a user keeps the report, drops the link
do $$ declare rid uuid; begin
  perform pg_temp.as_user('00000000-0000-0000-0000-000000000001');
  rid := (public.submit_report('accident', 54.0, -2.0)).id;
  reset role;
  delete from auth.users where id = '00000000-0000-0000-0000-000000000001';
  assert exists (select 1 from public.reports where id = rid), 'report lost on user delete';
  assert not exists (select 1 from public.report_authors where report_id = rid), 'author link survived erasure';
end $$;

select 'db tests: all assertions passed' as result;
