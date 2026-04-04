# Visual Verification

Use Playwright for repeatable verification of:

- showcase artifact rendering
- PostGIS-backed map behavior
- proxy/service reachability through the dashboard origin

## Preferred Commands

### map-only showcase

```powershell
pixi run showcase
pixi run serve-map
pixi run verify-map
```

### full stack

```powershell
pixi run up
pixi run verify-browser
```

## Test Structure

| File | Scope | Requires |
|------|-------|----------|
| `tests/map-visual.spec.ts` | showcase map, source switching, popup behavior, dashboard rendering | static server on `:8081` |
| `tests/map-proxy.spec.ts` | Martin, pg_featureserv, pg_tileserv, Maputnik proxy checks | full stack on `:8080` |

## Verification Checklist

- map canvas becomes visible
- source selector defaults correctly
- status messaging does not contain `error` or `failed`
- parcel layers load
- popup rendering works for clicked parcels
- dashboard service cards render
- proxied endpoints respond through the single-origin nginx surface

## Output

Screenshots are written to `tests/output/` and are intentionally not committed.
