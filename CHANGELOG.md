# Changelog

All notable changes to `ocaml-hexaly` will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project uses [semantic versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-05-31

First release. Working binding for the Hexaly Optimizer 14.5 C++ API.

### Added
- **Core modeling**: bool/int/float decision variables; arithmetic, comparison,
  boolean, conditional, and array operators; constraints; single and
  multi-objective minimize/maximize.
- **Scheduling support**: `interval_var`, `optional_interval_var`,
  `start`/`end_`/`length`/`presence` operators, `interval_value` solution
  readback.
- **Routing support**: `list_var`, `set_var`, `count`/`index_of`/`contains`/
  `partition`/`disjoint`/`distinct`/`find`/`sort`/`intersection`/`union_`/
  `hull` operators, `collection_value` solution readback.
- **Math functions**: sqrt, log, exp, pow, cos, sin, tan, ceil, floor, round.
- **Typed errors**: `Hexaly_error of Error.code * string` with the 9-way
  `HxErrorCode` mirror.
- **Callbacks**: `add_callback` / `remove_callback` with all 7 event types.
  Trampoline manages OCaml runtime lock across Hexaly's worker threads.
- **Inconsistency analysis**: `compute_inconsistency` returning an
  `Inconsistency.t` with `nb_causes`, `cause`, `to_string`.
- **Warm start**: `set_int_value` / `set_float_value` / `set_interval_value`
  on a solution before solve.
- **Advanced parameters**: `set_advanced_int` / `_double` / `_string` for
  Hexaly's named attribute knobs, plus `set_warning_level`,
  `set_time_between_displays`, `set_time_between_ticks`,
  `set_iteration_between_ticks`, objective thresholds, log file.
- **Version / license**: `Version.major` / `minor` / `string` / `platform`,
  programmatic license-path override.
- **Environment save**: `save_environment` writes a `.hxm` Hexaly Modeler
  script (loadable by the Hexaly CLI; round-trip via `load_environment`
  is not currently supported by Hexaly itself).
- **Solver introspection**: `state` (Modeling/Running/Paused/Stopped),
  `running_time`, `nb_iterations`.
- **Pretty printers** for `Error.code`, `State.t`, `Status.t`,
  `Callback_type.t`, `Inconsistency.t`.
- **Mock backend**: auto-selected when Hexaly isn't installed; passes the
  full test suite (interval/list/set/math tests skip on mock).
- **Test suite**: 23 alcotest tests covering core, regression, errors,
  scheduling, routing, math, introspection, callbacks, warm start,
  advanced params, environment, IIS.
- **Examples**: knapsack (optimum 309), TSP via list-var (optimum 24),
  single-machine scheduling via interval-var + pairwise non-overlap
  (optimum makespan 15).
- **Benchmark**: `bench/build_million` measures 1M-expression model build.
- **CI**: GitHub Actions matrix on macOS + Linux × OCaml 4.14 / 5.1 / 5.2
  (mock backend).

### Known limitations
- No `lambdaFunction` / `range` / `array(range, lambda, default)` — the
  Pythonic Hexaly TSP idiom isn't expressible; TSP example unrolls.
- No `HxExternalFunction` (custom evaluation callbacks during search).
- `load_environment` accepts a different format than `save_environment`
  produces — Hexaly's own limitation, documented in the .mli.

### Multi-objective phases (added post 0.1.0 scope)
- `Hexaly.Phase` module bound: `create`, `get`, `nb_phases`,
  `set_time_limit` / `time_limit`, `set_iteration_limit` /
  `iteration_limit`, `set_optimized_objective` / `optimized_objective`,
  `set_enabled` / `is_enabled`, `to_string` / `pp`.
- Lexicographic optimization demonstrated in
  [`examples/multi_objective.ml`](examples/multi_objective.ml):
  bi-objective assignment finds cost-optimal 16, then balances load 3/3
  across two workers.

### Cross-platform build (added post 0.1.0 scope)
- Replaced the POSIX bash `configure.sh` with `src/config/discover.ml`,
  a portable OCaml configurator using `dune-configurator`. The same
  source builds on Linux, macOS, Windows, and *BSD — no shell required.
- Library auto-detection from `$HEXALY_HOME`, `/opt/hexaly_*`,
  `/Library/hexaly_*`, `$HOME/hexaly_*`, `C:/hexaly_*`,
  `$ProgramFiles/hexaly_*`.
- Versioned soname discovery (e.g. `libhexaly145.dylib` →
  `-lhexaly145`) instead of hardcoding `-lhexaly`.
