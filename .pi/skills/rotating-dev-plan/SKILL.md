---
name: rotating-dev-plan
description: >-
  Single-active rotating development plan for this repo (docs/plan/active_plan.md,
  future/, archive/). Use when planning, implementing, verifying, or rotating a
  development phase; when the user asks what to do next; or before adding work
  that might belong to a future phase.
---

# Rotating dev plan

This repo has one active plan. Future work stays in outline files until it
is promoted. Completed plans are archived, never edited in place.

## Layout

```text
docs/plan/active_plan.md   # the only executable plan
docs/plan/future/          # later phases: outline + exit, no task dump
docs/plan/archive/         # verified, finished plans
```

Do not recreate `docs/DEVELOPMENT_PLAN.md` or put all phases into `active_plan.md`.

## Before doing product work

1. Read `docs/plan/active_plan.md`.
2. Treat its 范围内 / 不在本步 / 出口 as binding.
3. If the requested work is outside the active plan, say so and stop. Move it
   to `docs/plan/future/` only when the user asks to capture it.
4. Do not pull Herdr, Mosh, Ghostty, or polish work into the current step
   because it appears in PRD or `future/`.

## Writing `active_plan.md`

Keep it short. Required sections:

- **出口** — one testable result
- **范围内**
- **不在本步**
- **切片** — ordered, small enough to implement
- **验证** — observations, not implementation recipes
- **完成后** — archive name and which `future/` file is next

When promoting a future file, expand slices and verification. Do not start
implementation against an outline that has no 验证.

## Writing `future/` files

One file per later phase: `NN-short-slug.md`. Include title, 出口, and a
short bullet outline. Do not pre-write slices, estimates, or verification
for phases that are not active.

## Rotating

Rotate only after the active 出口 is verified **and** the user confirms.
Code on `main` is not enough.

1. `git mv docs/plan/active_plan.md docs/plan/archive/NN-short-slug.md`
2. `git mv docs/plan/future/NN-next.md docs/plan/active_plan.md`
3. Expand the new active plan with 范围内 / 不在本步 / 切片 / 验证 / 完成后
4. Leave already-archived files unchanged

If `future/` is empty, write the next active plan with the user. Do not
invent the next phase from PRD alone.

## What not to do

- Do not implement `future/` items "while we are here"
- Do not keep a finished plan in `active_plan.md` as history
- Do not rotate because the code compiled; 验证 in the active plan is the gate
