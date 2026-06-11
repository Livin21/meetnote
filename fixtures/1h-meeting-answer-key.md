# Answer key — fixtures/1h-meeting-transcript.md

Synthetic 58-min meeting (fictional company/product) for grading summarization
quality. The note owner is addressed as "Sam" in dialogue, so run with:

```sh
MEETNOTE_OWNER=Sam MEETNOTE_DIR=/tmp/meetnote-test meetnote summarize fixtures/1h-meeting-transcript.md
```

Participants (names only inferable from dialogue): Sam (Me), Dana (chair/eng
lead), Mei (PM), Ravi (backend), Noor (SRE, joins ~13:30).

## Decisions (8)
1. Duplicate-payment alert to production at 0.5% (was 2%), Friday, gated on pager routing
2. PR 214 splits: idempotency fix this week, logging refactor follow-up
3. End-to-end tests use synthetic orders, not anonymized production data
4. Beacon tenant menu-config freeze until July 25 review; observability changes exempt
5. Contractor approved: 3 months, integrations backlog only, no prod access
6. Image vendor pilot on staging only, 2-week bake; abort if >1% processing failures in first 3 days
7. Weekly moves to Thursdays 09:30 from August
8. v1 menu-sync API retires September 30

## Action items (16)
- Noor: pager routing by Thursday · capacity report in 2 weeks
- Sam: 0.5% threshold + Friday deploy · generator spike demo next weekly ·
  interview rubric question by end of next week · eval report template with
  netted egress line · half the eval spot-check during bake
- Ravi: split PR 214, idempotency part reviewable tomorrow · vendor pilot
  setup Wednesday next week
- Dana: review split Thursday · Thursday invite before end of week · calendar
  marker when pilot live
- Mei: confirm Beacon July 25 date this week · SOW to finance Monday ·
  retirement notice next week · 20 eval photos during bake

## Open questions (3)
- Beacon loyalty enablement (pending their legal review)
- Issue 132 fix ownership (parked to next sprint planning)
- Vendor EU data residency (pending their compliance team, no ETA)

## Planted STT garbles (must not leak into notes)
"item potency" → idempotency · "post grass" → Postgres ·
"cough-ka" → Kafka · "ess oh double you" → SOW

## Reference results (2026-06-11, google/gemma-4-26b-a4b, M5 Pro 48GB)
Single pass @16k context: 59s wall. 8/8 decisions, 14/16 actions (missed the
calendar-marker and spot-check-half soft items), 3/3 open questions, all
names inferred, no garble leaks, no hallucinations. Known quirk: spoken
"two-fourteen" may be rendered as "PR 2414".
