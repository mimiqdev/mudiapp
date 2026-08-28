---
name: rotating-dev-plan
description: >-
  Single-active rotating development plan for this repo (docs/plan/active_plan.md,
  future/, archive/). Each phase specifies tests first, implements second, and
  is done only when those tests pass. Use when planning, implementing, verifying,
  or rotating a development phase; when the user asks what to do next; or before
  adding work that might belong to a future phase.
---

# Rotating dev plan

This repo has one active plan. Future work stays in outline files until it
is promoted. Completed plans are archived, never edited in place.

Every active plan runs in three jobs, in order:

1. **Define tests** — the phase contract, written into `active_plan.md` before
   product code. Then add the automated tests; they must fail for the right
   reason.
2. **Implement** — only the 范围内 / 切片 of this plan. Do not invent tests
   or scope during implementation unless the user agrees to change the plan.
3. **Green** — all automated tests pass, then the manual tests in the plan
   are run. 出口 is not met until both are done.

## Layout

```text
docs/plan/active_plan.md   # the only executable plan
docs/plan/future/          # later phases: outline + exit, no task dump
docs/plan/archive/         # verified, finished plans
```

Do not recreate `docs/DEVELOPMENT_PLAN.md` or put all phases into `active_plan.md`.

## Before doing product work

1. Read `docs/plan/active_plan.md`.
2. Treat 范围内 / 不在本步 / 出口 / 测试 as binding.
3. If 测试 is missing or empty, stop. Fill it with the user before coding.
4. If the requested work is outside the active plan, say so and stop. Move it
   to `docs/plan/future/` only when the user asks to capture it.
5. Do not pull Herdr, Mosh, Ghostty, or polish work into the current step
   because it appears in PRD or `future/`.

## Writing `active_plan.md`

Keep it short. Required sections, in this order:

- **出口** — one testable result
- **范围内**
- **不在本步**
- **测试** — defined before implementation; see below
- **切片** — product implementation only, after tests exist and fail
- **完成后** — archive name and which `future/` file is next

### 测试

Split automated and manual. Automated tests are the implementation gate.
Manual tests cover what this phase cannot automate (device keyboard, LAN SSH).
出口 may require manual tests; it still cannot skip red automated tests.

Name each test by observation, not by UI recipe. Do not start 切片 until:

1. 测试 is written in the plan
2. The automated tests exist in the repo and fail

Do not expand 测试 in the same change as feature code.

## Writing `future/` files

One file per later phase: `NN-short-slug.md`. Include title, 出口, and a
short bullet outline. Do not pre-write 测试, 切片, or estimates.

When promoting, fill 测试 first, confirm with the user, then write 切片.

## Rotating

Rotate only after automated tests are green, manual 测试 are done, the 出口
is verified, **and** the user confirms. Code on `main` is not enough.

1. `git mv docs/plan/active_plan.md docs/plan/archive/NN-short-slug.md`
2. `git mv docs/plan/future/NN-next.md docs/plan/active_plan.md`
3. Expand the new active plan: 范围内 / 不在本步 / 测试 / 切片 / 完成后
4. Stop after 测试 is filled if the user has not confirmed it
5. Leave already-archived files unchanged

If `future/` is empty, write the next active plan with the user. Do not
invent the next phase from PRD alone.

## What not to do

- Do not implement `future/` items "while we are here"
- Do not keep a finished plan in `active_plan.md` as history
- Do not rotate because the code compiled; 测试 in the active plan is the gate
- Do not write feature code before the automated tests exist and fail
