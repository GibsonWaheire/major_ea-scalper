# FlipTrail_EA_v2 — LOCKED

**DO NOT MODIFY THIS FILE.**

`FlipTrail_EA_v2.mq5` is locked at v2.20 and is considered stable/production-ready.

Any new features or experiments must go into a new version file (v3, v4, etc.).

## What this EA does
- HFT basket scalper — New York session only (13:00–22:00 server time)
- Entry: M1 bar body direction → blasts N trades as one basket
- Exit 1: Profit target — X% of trades hit minimum price change %
- Exit 2: Dynamic SL — adapts from historical basket % changes, floored at minimum %
- No individual SL/TP on trades — bulk-close only
- Magic number: 112234
