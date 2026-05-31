# hexaly

[![opam](https://img.shields.io/badge/opam-hexaly-blue)](https://opam.ocaml.org/packages/hexaly/)
[![CI](https://img.shields.io/github/actions/workflow/status/aalok-thakkar/ocaml-hexaly/ci.yml?branch=main)](https://github.com/aalok-thakkar/ocaml-hexaly/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Documentation](https://img.shields.io/badge/docs-online-blue)](https://aalok-thakkar.github.io/ocaml-hexaly)

OCaml bindings for **[Hexaly Optimizer](https://www.hexaly.com/)** (formerly
LocalSolver) — a commercial mathematical optimization solver supporting
mixed-integer linear / nonlinear programming, constraint programming, and the
specialized decision variables (interval, list, set) that make Hexaly the
solver of choice for industrial scheduling and routing problems.

```ocaml
let opt = Hexaly.create () in
let m   = Hexaly.model opt in

let route = Hexaly.list_var m n in              (* permutation of 0..n-1 *)
let total = Hexaly.sum m (List.init n (fun k ->
  let i = Hexaly.at m route [Hexaly.int_const m k] in
  let j = Hexaly.at m route [Hexaly.int_const m ((k + 1) mod n)] in
  Hexaly.at m distances [i; j]))                (* distances.(i).(j) *)
in
Hexaly.add_constraint m
  (Hexaly.eq m (Hexaly.count m route) (Hexaly.int_const m n));
Hexaly.minimize m total;
Hexaly.close m;
Hexaly.solve opt;

let tour = Hexaly.collection_value (Hexaly.solution opt) route in
Printf.printf "Optimal tour length: %d\n" (Hexaly.int_value (Hexaly.solution opt) total);
Array.iter (Printf.printf " %d") tour
```

## Why use this binding

- **Complete API.** Every Hexaly modeling primitive is bound: bool / int /
  float / interval / list / set decisions; arithmetic, math, comparison,
  boolean, conditional, array, and scheduling operators; constraints;
  single- and multi-objective optimization; warm start; inconsistency
  analysis; callbacks; environment export. The hot path (expression
  construction) is batched so a 1000-operand sum crosses FFI once, not
  1001 times.
- **Idiomatic OCaml.** Typed errors (`Hexaly_error of Error.code * string`),
  pretty printers for every enum, opaque types that prevent dangling
  references via the GC's reachability analysis, an operator-syntax
  submodule for terse modeling.
- **Production-grade.** 73-test alcotest suite passing on real Hexaly 14.5;
  52-test subset passing on a bundled mock backend so contributors without
  a license can still build, test, and hack. ~190 ns / expression node
  on Apple Silicon.
- **Portable.** Linux, macOS (Intel + Apple Silicon), Windows. The build
  configurator is plain OCaml using `dune-configurator` — no shell
  scripts.

## Status

| Aspect                       | State                                     |
| ---------------------------- | ----------------------------------------- |
| Hexaly version supported     | 14.5                                       |
| Test coverage                | 73 alcotest cases (real) / 52 (mock)      |
| Platforms                    | Linux, macOS Intel, macOS Apple Silicon, Windows |
| Memory safety                | Hand-written stubs, GC-aware lifetimes    |
| Thread safety (callbacks)    | Runtime-lock dance for Hexaly worker threads |
| API stability                | 0.1.0 — pre-1.0, expect minor additions   |

## Installation

```sh
opam install hexaly
```

That builds against the bundled mock backend (no Hexaly install required).
To link against the real solver:

1. Install Hexaly from <https://www.hexaly.com/download> (free 30-day trial
   or free academic license).
2. Obtain a `license.dat` from your Hexaly account.
3. Tell the build where Hexaly lives and where the license is:
   ```sh
   export HEXALY_HOME=/opt/hexaly_14_5            # or wherever installed
   export HX_LICENSE_PATH=/path/to/license.dat
   opam reinstall hexaly                          # rebuilds against the real backend
   ```

The build configurator auto-detects installs under `/opt/hexaly_*`,
`/Library/hexaly_*`, `$HOME/hexaly_*`, `C:/hexaly_*`, and
`$ProgramFiles/hexaly_*`, so `HEXALY_HOME` is optional if you used the
default install location.

To force the mock backend explicitly:
```sh
HEXALY_BACKEND=mock opam reinstall hexaly
```

## Quick tour

```ocaml
open Hexaly

(* 1. Create an optimizer and configure it. *)
let opt = create () in
let p   = param opt in
set_time_limit p 60;
set_seed p 42;
set_nb_threads p 4;
set_verbosity p 0;

(* 2. Build the model. *)
let m = model opt in

let x  = bool_var m in
let y  = int_var m 0 100 in
let f  = float_var m 0.0 1.0 in
let iv = interval_var m 0 50 in        (* scheduling: a time window *)
let pe = list_var m 10 in              (* routing: a permutation *)
let s  = set_var m 10 in               (* a subset *)

(* Arithmetic, math, logical, conditional — all available. *)
let e = if_ m
  (gt m y (int_const m 50))
  (mul m x y)
  (sum m [x; y])
in
add_constraint m (leq m e (int_const m 1000));

(* Multi-objective: declare them in priority order. *)
minimize m (length m iv);   (* obj 0 *)
maximize m e;               (* obj 1 *)
close m;

(* 3. Multi-objective phases (lex-min). *)
let p0 = Phase.create opt in
Phase.set_optimized_objective p0 0;
Phase.set_time_limit p0 10;
let p1 = Phase.create opt in
Phase.set_optimized_objective p1 1;
Phase.set_time_limit p1 50;

(* 4. Watch progress. *)
let _ = add_callback opt Callback_type.Time_ticked
  (fun () -> Printf.eprintf "  iter=%Ld  state=%s\n%!"
               (nb_iterations opt) (State.to_string (state opt)))
in

(* 5. Solve. *)
solve opt;

(* 6. Read the solution. *)
let sol = solution opt in
match status sol with
| Status.Optimal | Status.Feasible ->
  Printf.printf "x=%d  y=%d  f=%f\n" (int_value sol x) (int_value sol y) (float_value sol f);
  let (a, b) = interval_value sol iv in
  Printf.printf "interval = [%d, %d)\n" a b;
  let perm = collection_value sol pe in
  Array.iter (Printf.printf " %d") perm
| Status.Infeasible ->
  let iis = compute_inconsistency opt in
  Printf.eprintf "infeasible (%d causes):\n%s\n"
    (Inconsistency.nb_causes iis) (Inconsistency.to_string iis)
| Status.Inconsistent ->
  Printf.eprintf "model is structurally inconsistent\n"
```

## Error handling

Every Hexaly call site can raise a typed `Hexaly_error`:

```ocaml
try
  Hexaly.add_constraint m bad_expr;
  Hexaly.solve opt
with Hexaly.Hexaly_error (code, msg) ->
  match code with
  | Hexaly.Error.License  -> Printf.eprintf "License problem: %s\n" msg
  | Hexaly.Error.Model    -> Printf.eprintf "Modeling bug: %s\n" msg
  | Hexaly.Error.Solver   -> Printf.eprintf "Solver gave up: %s\n" msg
  | Hexaly.Error.Api      -> Printf.eprintf "API misuse: %s\n" msg
  | _ -> Printf.eprintf "Hexaly error: %s\n" msg
```

The 9 codes mirror Hexaly's `HxErrorCode`:
`Api | File | Model | Callback | License | Solver | Internal | Modeler | Cloud`.

## Examples

Four worked examples ship with the library. Each solves to a known
optimum on the real backend:

| File                                            | Demonstrates                          | Optimum |
| ----------------------------------------------- | ------------------------------------- | ------- |
| [`examples/knapsack.ml`](examples/knapsack.ml)   | 0/1 knapsack, bool variables          | value 309 / weight 165 |
| [`examples/tsp.ml`](examples/tsp.ml)             | `list_var`, 2D array lookup, routing  | cost 24 |
| [`examples/scheduling.ml`](examples/scheduling.ml)| `interval_var`, pairwise non-overlap | makespan 15 |
| [`examples/multi_objective.ml`](examples/multi_objective.ml)| `Phase`, lex-min cost then balance | cost 16, load 3/3 |

Build and run:
```sh
dune exec examples/knapsack.exe
dune exec examples/tsp.exe
dune exec examples/scheduling.exe
dune exec examples/multi_objective.exe
```

## Performance

The library is designed so the FFI boundary is never the bottleneck.

| Operation (on 2026 Apple Silicon, Hexaly 14.5)  | Time     | Per-unit         |
| ----------------------------------------------- | -------- | ---------------- |
| Create 1000 int vars                            | < 1 ms   | < 1 µs / var     |
| Build 1M expression nodes                       | 187 ms   | **~190 ns / node** |
| `close` (Hexaly model compilation)              | 541 ms   | one-shot         |
| Solve (1 sec time limit)                        | 39 ms    | depends on model |

For comparison, ctypes-style FFI typically clocks at ~1 µs / call, and
the cpython binding sits around ~600 ns. The hot path here is hand-
written C stubs with batched `create_expression`, so a sum over 1000
operands crosses FFI exactly once.

Reproduce on your machine:
```sh
dune exec bench/build_million.exe
```

## Architecture

```
OCaml user code
   │  one record + custom-block per derived handle
   ▼
src/hexaly.ml + .mli              Idiomatic API + Error / State / Status /
   │                              Op / Callback_type / Inconsistency /
   │                              Phase / Version / Syntax modules
   ▼
src/hexaly_stubs.c                OCaml↔C glue: custom blocks, finalizers,
   │                              typed-exception raising, callback trampoline
   │                              with proper runtime-lock dance
   ▼
src/hexaly_shim_{real,mock}.cpp   extern "C" surface; catches every C++
   │                              exception into a thread-local (code, msg);
   │                              real links libhexaly, mock self-contained
   ▼
libhexaly14X.dylib / .so / .dll   Shipped with the Hexaly install
```

**Why four layers and not three?** Hexaly is C++ only — there is no C
ABI. So a thin `extern "C"` shim is required regardless of which OCaml
binding strategy you use. We added it; you got two extra benefits:

1. C++ exceptions get caught before they can corrupt the OCaml stack.
2. A self-contained mock backend slots into the same ABI, so CI and
   contributors without a Hexaly license can still build and test.

**Lifetime safety.** Each derived handle (`model`, `param`, `solution`,
`expr`, `Inconsistency.t`, `Phase.t`, `callback`) is an OCaml record
carrying its parent. The compiler's reachability analysis enforces the
chain — drop the optimizer and everything dies cleanly; hold any
descendant and the whole tree survives. This costs one extra word per
handle and eliminates the most common use-after-free in C bindings.

**Callbacks across threads.** `solve` releases the OCaml runtime lock
so other OCaml threads can run and so Hexaly worker threads can safely
re-enter OCaml via the callback trampoline. The trampoline registers
the calling thread with the OCaml runtime (idempotent), acquires the
lock, calls the closure with `caml_callback_exn`, releases the lock.
Closures that raise are suppressed with a stderr warning — they can't
escape into Hexaly's C++ code.

For the in-depth design rationale (including how `HxOperator` drift is
caught at compile time, how the build picks the right library across
platforms, and how the `static_assert` sentinels work), see
[`docs/design.md`](docs/design.md).

## Documentation

- [API reference (odoc)](https://aalok-thakkar.github.io/ocaml-hexaly)
- [Design notes](docs/design.md) — architecture, lifetime invariants,
  callback runtime-lock dance, ABI drift defense, cross-platform build.
- [Changelog](CHANGELOG.md)
- [Contributing guide](CONTRIBUTING.md)

## How does it compare?

Hexaly itself has official bindings for Python, Java, C#, and C++.
This binding mirrors the same modeling surface in OCaml. Things that
distinguish it from those:

- **Static typing**: every operator, every parameter, every error is
  typed. The compiler catches model-building mistakes the Python
  binding would defer to runtime.
- **GC-aware lifetimes**: you cannot construct a dangling expression
  reference. Compare to C++ where it's your job to keep the optimizer
  alive while expressions exist.
- **A real testing story without a license**: the mock backend lets
  contributors and CI run a meaningful subset of the suite without
  Hexaly installed. Java/Python/C++ bindings cannot offer this — they
  need Hexaly to compile at all.

Things the official bindings have that this doesn't yet:

- `lambdaFunction` / `range` (the Pythonic `m.array(m.range(0, n), λ i. ...)`
  TSP idiom — see the unrolled TSP example for the workaround).
- `HxExternalFunction` (custom evaluators called per-iteration).

Both can be added; neither blocks 80% of production use cases.

## Roadmap

- 0.2.0 — `HxExternalFunction`, `lambdaFunction` + `range` (closes the
  TSP-unroll gap).
- 0.3.0 — More tuning helpers (Hexaly Studio import, surrogate parameters,
  named param accessors).
- 1.0.0 — API freeze after a stability window.

## Contributing

Pull requests welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the
extension recipe across the four layers and notes on handling Hexaly
version drift.

If you're using this in production, please open an issue and tell us
what's working and what isn't — the API stabilization for 1.0.0 will be
guided by real usage.

## License

This binding is MIT licensed (see [`LICENSE`](LICENSE)).

The Hexaly Optimizer itself is proprietary and requires a separate license
from <https://www.hexaly.com/>. Free academic and trial licenses are
available; no commercial license is required to use this OCaml binding,
only to use the underlying solver.

## Acknowledgments

Built on top of Hexaly's mature C++ optimizer. Thanks to the Hexaly team
for the comprehensive C++ documentation that made the binding
verifiable end-to-end.
