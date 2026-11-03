# Architecture (decisions so far)
- Client: React Native + Expo (TypeScript, Expo Router), MapLibre Native. Requires a dev build (not Expo Go).
- Backend: Supabase (Postgres + PostGIS, Auth incl. anonymous sign-in, Realtime, Edge Functions).
- Routing: OSRM first (self-hosted, UK extract from Geofabrik); Valhalla if costing/avoid options need it.
  Note: OSRM has no live traffic; ETAs are free-flow estimates unless a traffic provider is added.
- Tiles/geocoding: provider-agnostic interface. Public OSM tile and Nominatim servers are NOT for production.
- Privacy: `reports` is public and holds no user id; `report_authors` is private and cascades on user deletion.
  Clients cannot write reports/votes directly; only `submit_report` / `vote_report` (rate-limited, security definer).
- Report lifecycle: active -> (cleared by >=3 denials exceeding confirms | expired by TTL) -> purged after 30 days.
  TTLs per category live in `incident_categories`; confirmations extend life up to 3x base TTL.
- Maintenance: `expire_reports()` every minute, `purge_old_data()` daily (pg_cron or scheduled edge function).
