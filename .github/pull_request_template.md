## What & why

## Checklist
- [ ] Smoke suite green locally (`scripts/smoke-*.sh`, export `ANON`/`SERVICE`)
- [ ] If WASM engine touched: `cd web && npm run build:wasm` and committed `web/public/orderbook.wasm`
- [ ] New engine functions are covered by `9900_lockdown` (deny-by-default)
- [ ] Privileged migration steps self-skip on hosted Supabase (best-effort `DO` blocks)
- [ ] Docs updated if behavior changed

## Notes
By contributing you agree your changes are licensed under AGPL-3.0.
