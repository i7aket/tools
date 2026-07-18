#!/usr/bin/env bats
# Model selection: --model / CODEX_CHECK_MODEL pin `codex exec -m`; unset means
# no -m at all (Codex's own ~/.codex/config.toml default decides).
load helper

make_plan_repo() {
  repo="$(make_repo)"
  printf 'Ticket: none\n\n## Plan\nx\n' > "$repo/plan.md"
  cd "$repo"
}

@test "M1: default run passes no -m (model comes from Codex config)" {
  make_plan_repo
  run bash "$RUN" plan.md --pre-implementation
  [ "$status" -eq 0 ]
  codex_ran
  args="$(codex_args)"
  [[ "$args" != *" -m "* ]]
}

@test "M2: --model pins codex exec -m" {
  make_plan_repo
  run bash "$RUN" plan.md --pre-implementation --model gpt-flag-model
  [ "$status" -eq 0 ]
  [[ "$(codex_args)" == *"-m gpt-flag-model"* ]]
}

@test "M3: CODEX_CHECK_MODEL env pins the model" {
  make_plan_repo
  CODEX_CHECK_MODEL=gpt-env-model run bash "$RUN" plan.md --pre-implementation
  [ "$status" -eq 0 ]
  [[ "$(codex_args)" == *"-m gpt-env-model"* ]]
}

@test "M4: --model overrides CODEX_CHECK_MODEL" {
  make_plan_repo
  CODEX_CHECK_MODEL=gpt-env-model run bash "$RUN" plan.md --pre-implementation --model gpt-flag-model
  [ "$status" -eq 0 ]
  args="$(codex_args)"
  [[ "$args" == *"-m gpt-flag-model"* ]]
  [[ "$args" != *"gpt-env-model"* ]]
}

@test "M5: --model without a value fails closed" {
  make_plan_repo
  run bash "$RUN" plan.md --pre-implementation --model
  [ "$status" -ne 0 ]
  ! codex_ran
}
