# PROJECT_STATUS (working name: Pathly — placeholder, trademark-check before launch)

## Done and tested (Phase 1 partial + Phase 7/8 data layer)
- `supabase/migrations/0001_core_schema.sql` — profiles, preferences, saved/recent destinations,
  incident categories, reports (+ private report_authors), votes, road_conditions, devices,
  notifications, RLS, rate limiting, dedupe, confidence scoring, expiry, retention, realtime publication.
- `supabase/tests/` — applies migration twice (idempotency) on real Postgres 16 + PostGIS 3.4 with an
  emulated Supabase auth layer, then 10 assertion groups. Run: `bash supabase/tests/run_tests.sh`.

## NOT started
Everything else: Expo app, MapLibre map, GPS, geocoding, routing (OSRM/Valhalla), turn-by-turn,
voice, auth UI, report UI, realtime client, traffic ingest, notifications sender, offline queue,
branding/icon, CI, deployment. See FEATURE_CHECKLIST.md.

## Known limitations / decisions
- Tests ran against an *emulated* Supabase (auth.uid(), roles). Re-run against a real Supabase project
  (`supabase db reset`) before trusting RLS in production. NOT yet verified there.
- Confidence formula is an uncalibrated heuristic. Reputation is a single number on profiles.
- Live driver presence is deliberately NOT stored in the DB (use ephemeral Supabase Realtime presence, opt-in).
- No notification sender exists yet (tables only). pg_cron jobs are scheduled only if the extension exists.
- Report free-text `description` is public: needs moderation/profanity filtering before launch.
- Speed-camera/police reporting legality (UK) needs legal review; not done.
- No live traffic provider chosen; `road_conditions.source_type` separates measured vs estimated.

## Next steps (in order)
1. Re-run DB tests on a real Supabase project. 2. Expo + TypeScript + Expo Router scaffold, design system.
3. MapLibre map + a licensed/self-hosted tile source (never OSM public tiles). 4. Location service.
5. Geocoding (self-hosted Nominatim or a licensed provider) + OSRM routing. 6. Navigation engine + tests.
## Restart
`apt install postgresql postgis`, then `bash supabase/tests/run_tests.sh`.
