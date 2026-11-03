-- 0001_core_schema.sql
-- Core schema for the navigation app (working name: Pathly).
-- Idempotent: safe to apply repeatedly. Targets Supabase (Postgres 15+, PostGIS).

create schema if not exists extensions;
create extension if not exists postgis with schema extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- helpers
create or replace function public.set_updated_at() returns trigger
language plpgsql set search_path = public as $$
begin new.updated_at = now(); return new; end $$;

-- ---------------------------------------------------------------- profiles
-- One row per auth user (anonymous sign-ins included).
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text check (display_name is null or char_length(display_name) between 2 and 30),
  reputation   numeric(6,2) not null default 0 check (reputation between -100 and 1000),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table if not exists public.user_preferences (
  user_id            uuid primary key references public.profiles(id) on delete cascade,
  map_theme          text not null default 'auto'    check (map_theme in ('auto','light','dark')),
  voice_language     text not null default 'en-GB'   check (char_length(voice_language) between 2 and 10),
  voice_volume       numeric(3,2) not null default 0.80 check (voice_volume between 0 and 1),
  avoid_motorways    boolean not null default false,
  avoid_tolls        boolean not null default false,
  avoid_ferries      boolean not null default false,
  route_type         text not null default 'fastest' check (route_type in ('fastest','shortest','eco')),
  distance_units     text not null default 'miles'   check (distance_units in ('miles','km')),
  speed_units        text not null default 'mph'     check (speed_units in ('mph','kmh')),
  notify_incidents   boolean not null default true,
  notify_radius_m    integer not null default 2000   check (notify_radius_m between 500 and 20000),
  notify_route_changes boolean not null default true,
  share_location     boolean not null default false,  -- opt-in, off by default
  updated_at         timestamptz not null default now()
);

drop trigger if exists trg_profiles_updated on public.profiles;
create trigger trg_profiles_updated before update on public.profiles
  for each row execute function public.set_updated_at();
drop trigger if exists trg_prefs_updated on public.user_preferences;
create trigger trg_prefs_updated before update on public.user_preferences
  for each row execute function public.set_updated_at();

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id) values (new.id) on conflict do nothing;
  insert into public.user_preferences(user_id) values (new.id) on conflict do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ------------------------------------------------- saved / recent destinations
create table if not exists public.saved_destinations (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  kind       text not null default 'favourite' check (kind in ('home','work','favourite')),
  label      text not null check (char_length(label) between 1 and 80),
  address    text check (address is null or char_length(address) <= 300),
  lat        double precision not null check (lat between -90 and 90),
  lng        double precision not null check (lng between -180 and 180),
  created_at timestamptz not null default now()
);
create index if not exists idx_saved_dest_user on public.saved_destinations(user_id);
create unique index if not exists uq_saved_dest_home_work
  on public.saved_destinations(user_id, kind) where kind in ('home','work');

create table if not exists public.recent_destinations (
  id        uuid primary key default gen_random_uuid(),
  user_id   uuid not null references public.profiles(id) on delete cascade,
  label     text not null check (char_length(label) between 1 and 120),
  address   text check (address is null or char_length(address) <= 300),
  lat       double precision not null check (lat between -90 and 90),
  lng       double precision not null check (lng between -180 and 180),
  used_at   timestamptz not null default now()
);
create index if not exists idx_recent_dest_user on public.recent_destinations(user_id, used_at desc);

-- keep only the 50 most recent per user
create or replace function public.prune_recent_destinations() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from public.recent_destinations r
  where r.user_id = new.user_id
    and r.id in (select id from public.recent_destinations
                 where user_id = new.user_id order by used_at desc offset 50);
  return null;
end $$;
drop trigger if exists trg_prune_recent on public.recent_destinations;
create trigger trg_prune_recent after insert on public.recent_destinations
  for each row execute function public.prune_recent_destinations();

-- ------------------------------------------------------ incident categories
create table if not exists public.incident_categories (
  code             text primary key,
  label            text not null,
  ttl_minutes      integer not null check (ttl_minutes > 0),  -- lifetime without confirmation
  dedupe_radius_m  integer not null check (dedupe_radius_m > 0),
  directional      boolean not null default true,
  enabled          boolean not null default true,
  sort_order       smallint not null default 0
);

insert into public.incident_categories(code,label,ttl_minutes,dedupe_radius_m,directional,sort_order) values
  ('police',              'Police',               45,  250, true,  1),
  ('speed_camera',        'Speed camera',         10080,100, true,  2),
  ('accident',            'Accident',             90,  150, true,  3),
  ('road_hazard',         'Road hazard',          120, 100, true,  4),
  ('vehicle_stopped',     'Vehicle stopped',      60,  75,  true,  5),
  ('road_closure',        'Road closure',         480, 100, false, 6),
  ('traffic_congestion',  'Traffic congestion',   30,  400, true,  7),
  ('roadworks',           'Roadworks',            1440,200, false, 8),
  ('object_on_road',      'Object on road',       60,  75,  true,  9),
  ('dangerous_conditions','Dangerous conditions', 120, 300, false, 10)
on conflict (code) do update set
  label = excluded.label, ttl_minutes = excluded.ttl_minutes,
  dedupe_radius_m = excluded.dedupe_radius_m, directional = excluded.directional,
  sort_order = excluded.sort_order;

-- ------------------------------------------------------------------ reports
-- Public table: contains NO user identifier (see report_authors).
create table if not exists public.reports (
  id                uuid primary key default gen_random_uuid(),
  category          text not null references public.incident_categories(code),
  lat               double precision not null check (lat between -90 and 90),
  lng               double precision not null check (lng between -180 and 180),
  geom              extensions.geography(Point,4326) not null,
  heading           smallint check (heading is null or heading between 0 and 359),
  description       text check (description is null or char_length(description) <= 280),
  status            text not null default 'active' check (status in ('active','cleared','expired')),
  confirmations     integer not null default 1 check (confirmations >= 0),
  denials           integer not null default 0 check (denials >= 0),
  confidence        numeric(4,3) not null default 0.5 check (confidence between 0 and 1),
  created_at        timestamptz not null default now(),
  last_confirmed_at timestamptz not null default now(),
  expires_at        timestamptz not null
);
create index if not exists idx_reports_geom   on public.reports using gist (geom);
create index if not exists idx_reports_status on public.reports (status, expires_at);

-- Private: who submitted a report. Deleting a user removes this link,
-- leaving an anonymous report (GDPR erasure without breaking the map).
create table if not exists public.report_authors (
  report_id  uuid primary key references public.reports(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists idx_report_authors_user on public.report_authors(user_id, created_at desc);

create table if not exists public.report_votes (
  report_id  uuid not null references public.reports(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  vote       text not null check (vote in ('confirm','deny')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (report_id, user_id)
);
create index if not exists idx_votes_user_time on public.report_votes(user_id, updated_at desc);

-- ---------------------------------------------------------- road conditions
-- Provider-independent traffic data. Written only by service_role (ingest jobs).
-- source_type keeps measured traffic distinct from crowd reports/static data.
create table if not exists public.road_conditions (
  id          uuid primary key default gen_random_uuid(),
  provider    text not null,
  segment_ref text not null,
  geom        extensions.geography(LineString,4326) not null,
  level       text not null check (level in ('free','moderate','heavy','severe')),
  speed_kph   numeric(5,1) check (speed_kph is null or speed_kph >= 0),
  source_type text not null check (source_type in ('measured','estimated')),
  observed_at timestamptz not null default now(),
  expires_at  timestamptz not null,
  unique (provider, segment_ref)
);
create index if not exists idx_road_cond_geom on public.road_conditions using gist (geom);
create index if not exists idx_road_cond_exp  on public.road_conditions (expires_at);

-- ------------------------------------------------- devices & notifications
create table if not exists public.device_registrations (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  platform   text not null check (platform in ('ios','android')),
  push_token text not null unique check (char_length(push_token) between 10 and 500),
  created_at timestamptz not null default now(),
  last_seen  timestamptz not null default now()
);
create index if not exists idx_devices_user on public.device_registrations(user_id);

create table if not exists public.notifications (
  id        uuid primary key default gen_random_uuid(),
  user_id   uuid not null references public.profiles(id) on delete cascade,
  type      text not null check (type in ('nearby_incident','route_change','road_closure','navigation')),
  title     text not null,
  body      text,
  report_id uuid references public.reports(id) on delete set null,
  created_at timestamptz not null default now(),
  read_at   timestamptz
);
create index if not exists idx_notifications_user on public.notifications(user_id, created_at desc);

-- ------------------------------------------------------------ business logic
-- Heuristic (uncalibrated) confidence in [0,1]: logistic over votes + author reputation.
create or replace function public.compute_confidence(c integer, d integer, rep numeric)
returns numeric language sql immutable set search_path = public as $$
  select round((1 / (1 + exp(-(0.9*c - 1.4*d + 0.05*greatest(least(coalesce(rep,0),10),-10) - 0.5))))::numeric, 3)
$$;

create or replace function public.heading_diff(a smallint, b smallint)
returns integer language sql immutable set search_path = public as $$
  select abs(((a - b + 540) % 360) - 180)
$$;

create or replace function public.vote_report(p_report_id uuid, p_vote text)
returns public.reports language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid();
  v_report public.reports;
  v_author uuid;
  v_prev text;
  v_c int; v_d int; v_rep numeric; v_ttl int; v_old_status text;
begin
  if v_uid is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if p_vote not in ('confirm','deny') then raise exception 'invalid vote' using errcode = '22023'; end if;
  if (select count(*) from public.report_votes
      where user_id = v_uid and updated_at > now() - interval '10 minutes') >= 30 then
    raise exception 'rate limit exceeded' using errcode = '54000';
  end if;

  select * into v_report from public.reports where id = p_report_id for update;
  if not found or v_report.status <> 'active' or v_report.expires_at <= now() then
    raise exception 'report not active' using errcode = 'P0002';
  end if;
  v_old_status := v_report.status;

  select user_id into v_author from public.report_authors where report_id = p_report_id;
  if v_author = v_uid then raise exception 'cannot vote on own report' using errcode = '42501'; end if;

  select vote into v_prev from public.report_votes where report_id = p_report_id and user_id = v_uid;
  insert into public.report_votes(report_id, user_id, vote) values (p_report_id, v_uid, p_vote)
    on conflict (report_id, user_id) do update set vote = excluded.vote, updated_at = now();

  select count(*) filter (where vote='confirm') + 1, count(*) filter (where vote='deny')
    into v_c, v_d from public.report_votes where report_id = p_report_id;
  select coalesce(reputation,0) into v_rep from public.profiles where id = v_author;
  select ttl_minutes into v_ttl from public.incident_categories where code = v_report.category;

  update public.reports set
    confirmations = v_c, denials = v_d,
    confidence = public.compute_confidence(v_c, v_d, v_rep),
    last_confirmed_at = case when p_vote = 'confirm' then now() else last_confirmed_at end,
    -- a confirmation refreshes life, capped at 3x the base TTL from creation
    expires_at = case when p_vote = 'confirm'
                      then least(created_at + make_interval(mins => v_ttl*3), now() + make_interval(mins => v_ttl))
                      else expires_at end,
    status = case when v_d >= 3 and v_d > v_c then 'cleared' else status end
  where id = p_report_id returning * into v_report;

  if v_author is not null then
    if p_vote = 'confirm' and coalesce(v_prev,'') <> 'confirm' then
      update public.profiles set reputation = least(reputation + 0.25, 1000) where id = v_author;
    end if;
    if v_old_status = 'active' and v_report.status = 'cleared' then
      update public.profiles set reputation = greatest(reputation - 1, -100) where id = v_author;
    end if;
  end if;
  return v_report;
end $$;

create or replace function public.submit_report(
  p_category text, p_lat double precision, p_lng double precision,
  p_heading smallint default null, p_description text default null)
returns public.reports language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid uuid := auth.uid();
  v_cat public.incident_categories;
  v_rep numeric;
  v_pt extensions.geography;
  v_existing public.reports;
  v_new public.reports;
begin
  if v_uid is null then raise exception 'authentication required' using errcode = '28000'; end if;
  select * into v_cat from public.incident_categories where code = p_category and enabled;
  if not found then raise exception 'unknown category' using errcode = '22023'; end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'invalid coordinates' using errcode = '22023';
  end if;
  if p_description is not null and char_length(p_description) > 280 then
    raise exception 'description too long' using errcode = '22001';
  end if;

  select reputation into v_rep from public.profiles where id = v_uid;
  if not found then raise exception 'profile missing' using errcode = '28000'; end if;
  if v_rep <= -5 then raise exception 'reporting suspended' using errcode = '42501'; end if;

  -- rate limits: 5 per 10 minutes, 40 per day
  if (select count(*) from public.report_authors
      where user_id = v_uid and created_at > now() - interval '10 minutes') >= 5
  or (select count(*) from public.report_authors
      where user_id = v_uid and created_at > now() - interval '1 day') >= 40 then
    raise exception 'rate limit exceeded' using errcode = '54000';
  end if;

  v_pt := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::extensions.geography;

  -- duplicate detection: same category, nearby, compatible direction
  select * into v_existing from public.reports r
  where r.status = 'active' and r.expires_at > now() and r.category = p_category
    and st_dwithin(r.geom, v_pt, v_cat.dedupe_radius_m)
    and (not v_cat.directional or r.heading is null or p_heading is null
         or public.heading_diff(r.heading, p_heading) <= 90)
  order by st_distance(r.geom, v_pt) limit 1;

  if found then
    if exists (select 1 from public.report_authors where report_id = v_existing.id and user_id = v_uid) then
      return v_existing;
    end if;
    return public.vote_report(v_existing.id, 'confirm');
  end if;

  insert into public.reports(category, lat, lng, geom, heading, description, confidence, expires_at)
  values (p_category, p_lat, p_lng, v_pt, p_heading, nullif(btrim(p_description),''),
          public.compute_confidence(1, 0, v_rep), now() + make_interval(mins => v_cat.ttl_minutes))
  returning * into v_new;
  insert into public.report_authors(report_id, user_id) values (v_new.id, v_uid);
  return v_new;
end $$;

create or replace function public.reports_nearby(
  p_lat double precision, p_lng double precision, p_radius_m integer default 5000)
returns setof public.reports language sql stable security invoker set search_path = public, extensions as $$
  select r.* from public.reports r
  where r.status = 'active' and r.expires_at > now()
    and st_dwithin(r.geom, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::extensions.geography,
                   least(greatest(p_radius_m, 100), 50000))
  order by st_distance(r.geom, st_setsrid(st_makepoint(p_lng, p_lat), 4326)::extensions.geography)
  limit 200
$$;

-- Maintenance (run by pg_cron or an edge function using service_role).
create or replace function public.expire_reports() returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update public.reports set status = 'expired' where status = 'active' and expires_at <= now();
  get diagnostics n = row_count;
  return n;
end $$;

-- Data retention: reports 30d after expiry, recents 180d, notifications 90d,
-- stale traffic rows and device tokens unused for 180d.
create or replace function public.purge_old_data() returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.reports where status <> 'active' and expires_at < now() - interval '30 days';
  delete from public.recent_destinations where used_at < now() - interval '180 days';
  delete from public.notifications where created_at < now() - interval '90 days';
  delete from public.road_conditions where expires_at < now() - interval '1 day';
  delete from public.device_registrations where last_seen < now() - interval '180 days';
end $$;

-- ------------------------------------------------------------ contribution stats
create or replace view public.driver_contribution_stats with (security_invoker = true) as
select p.id as user_id, p.reputation,
  (select count(*) from public.report_authors a where a.user_id = p.id) as reports_submitted,
  (select count(*) from public.report_votes v where v.user_id = p.id and v.vote = 'confirm') as confirmations_given,
  (select count(*) from public.report_votes v where v.user_id = p.id and v.vote = 'deny') as denials_given
from public.profiles p;

-- ------------------------------------------------------------------ security
alter table public.profiles             enable row level security;
alter table public.user_preferences     enable row level security;
alter table public.saved_destinations   enable row level security;
alter table public.recent_destinations  enable row level security;
alter table public.incident_categories  enable row level security;
alter table public.reports              enable row level security;
alter table public.report_authors       enable row level security;
alter table public.report_votes         enable row level security;
alter table public.road_conditions      enable row level security;
alter table public.device_registrations enable row level security;
alter table public.notifications        enable row level security;

drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles for select to authenticated using (id = auth.uid());
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists prefs_own on public.user_preferences;
create policy prefs_own on public.user_preferences for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists saved_own on public.saved_destinations;
create policy saved_own on public.saved_destinations for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists recent_own on public.recent_destinations;
create policy recent_own on public.recent_destinations for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists devices_own on public.device_registrations;
create policy devices_own on public.device_registrations for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists notif_select_own on public.notifications;
create policy notif_select_own on public.notifications for select to authenticated using (user_id = auth.uid());
drop policy if exists notif_update_own on public.notifications;
create policy notif_update_own on public.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists categories_read on public.incident_categories;
create policy categories_read on public.incident_categories for select to anon, authenticated using (enabled);
drop policy if exists reports_read_active on public.reports;
create policy reports_read_active on public.reports for select to anon, authenticated
  using (status = 'active' and expires_at > now());
drop policy if exists authors_read_own on public.report_authors;
create policy authors_read_own on public.report_authors for select to authenticated using (user_id = auth.uid());
drop policy if exists votes_read_own on public.report_votes;
create policy votes_read_own on public.report_votes for select to authenticated using (user_id = auth.uid());
drop policy if exists road_cond_read on public.road_conditions;
create policy road_cond_read on public.road_conditions for select to anon, authenticated
  using (expires_at > now());

-- Table privileges: clients get the minimum; writes to reports/votes only via functions.
revoke all on public.profiles, public.user_preferences, public.saved_destinations,
  public.recent_destinations, public.incident_categories, public.reports, public.report_authors,
  public.report_votes, public.road_conditions, public.device_registrations, public.notifications
  from anon, authenticated;
grant select on public.incident_categories, public.reports, public.road_conditions to anon, authenticated;
grant select on public.report_authors, public.report_votes to authenticated;
grant select on public.profiles to authenticated;
grant update (display_name) on public.profiles to authenticated;
grant select, insert, update, delete on public.user_preferences, public.saved_destinations,
  public.recent_destinations, public.device_registrations to authenticated;
grant select on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;
grant select on public.driver_contribution_stats to authenticated;
-- users may not edit their own reputation (only display_name is column-granted above)

revoke execute on function public.submit_report(text,double precision,double precision,smallint,text) from public, anon;
revoke execute on function public.vote_report(uuid,text) from public, anon;
revoke execute on function public.expire_reports() from public, anon, authenticated;
revoke execute on function public.purge_old_data() from public, anon, authenticated;
grant execute on function public.submit_report(text,double precision,double precision,smallint,text) to authenticated;
grant execute on function public.vote_report(uuid,text) to authenticated;
grant execute on function public.reports_nearby(double precision,double precision,integer) to anon, authenticated;
grant execute on function public.expire_reports(), public.purge_old_data() to service_role;

-- ------------------------------------------------- realtime + scheduling (guarded)
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'reports') then
    alter publication supabase_realtime add table public.reports;
  end if;
end $$;

do $$ begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('expire-reports', '* * * * *', 'select public.expire_reports()');
    perform cron.schedule('purge-old-data', '15 3 * * *', 'select public.purge_old_data()');
  end if;
exception when others then
  raise notice 'pg_cron scheduling skipped: %', sqlerrm;
end $$;
