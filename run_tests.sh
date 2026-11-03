#!/usr/bin/env bash
# Applies the migrations twice (idempotency check) to a throwaway Postgres+PostGIS DB
# with a minimal emulation of Supabase's auth schema/roles, then runs assertions.
# Usage: ./run_tests.sh   (needs postgresql + postgis installed; run as root or postgres)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PSQL="psql -X -v ON_ERROR_STOP=1 -q -d pathly_test"
as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -c "$*"; else bash -c "$*"; fi; }

as_pg "pg_ctlcluster 16 main start 2>/dev/null || true"; sleep 2
as_pg "psql -X -q -c 'drop database if exists pathly_test' -c 'create database pathly_test'"

cat > /tmp/shim.sql <<'SQL'
do $$ begin
  create role anon nologin; exception when duplicate_object then null; end $$;
do $$ begin
  create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin
  create role service_role nologin bypassrls; exception when duplicate_object then null; end $$;
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key default gen_random_uuid(), email text);
create or replace function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth, public, extensions to anon, authenticated, service_role;
grant select on auth.users to service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
SQL
as_pg "$PSQL -c 'create schema if not exists extensions'"
as_pg "$PSQL -f /tmp/shim.sql"
as_pg "$PSQL -f $HERE/../migrations/0001_core_schema.sql"
echo "migration pass 1 OK"
as_pg "$PSQL -f $HERE/../migrations/0001_core_schema.sql"
echo "migration pass 2 (idempotent) OK"
as_pg "$PSQL -f $HERE/db_tests.sql"
echo "ALL DB TESTS PASSED"
