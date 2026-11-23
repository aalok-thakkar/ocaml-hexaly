# hexaly

[![opam](https://img.shields.io/badge/opam-hexaly-blue)](https://opam.ocaml.org/packages/hexaly/)
[![CI](https://img.shields.io/github/actions/workflow/status/aalok-thakkar/ocaml-hexaly/ci.yml?branch=main)](https://github.com/aalok-thakkar/ocaml-hexaly/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Documentation](https://img.shields.io/badge/docs-online-blue)](https://aalok-thakkar.github.io/ocaml-hexaly)

OCaml bindings for **[Hexaly Optimizer](https://www.hexaly.com/)** (formerly
LocalSolver), a commercial mathematical optimization solver. Hexaly handles
mixed-integer linear and nonlinear programming and constraint programming,
and has interval, list and set decision variables for scheduling and
routing problems.

```ocaml
let opt = Hexaly.create () in
let m   = Hexaly.model opt in

let route = Hexaly.list_var m n in              (* distinct values from 0..n-1 *)
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

## Features

- **Modeling.** Bool, int, float, interval, list and set decisions;
  arithmetic, math, comparison, boolean, conditional, array, collection
  and interval operators; constraints; single- and multi-objective
  optimization; warm start; inconsistency analysis; callbacks; model
  export. See [Not yet bound](#not-yet-bound) for what is missing.
  Expression construction is batched, so a 1000-operand sum crosses the
  FFI once.
- **OCaml interface.** Typed errors (`Hexaly_error of Error.code * string`),
  pretty printers for every enum, handles whose lifetimes the GC manages,
  and an operator-syntax submodule.
- **Tests.** 77 alcotest cases pass on Hexaly 14.5; 56 of them also run on
  a bundled mock backend, so contributors without a license can build and
  test.
- **Build.** The configurator is plain OCaml using `dune-configurator`.

## Status

| Aspect                       | State                                     |
| ---------------------------- | ----------------------------------------- |
| Hexaly version supported     | 14.5                                      |
| Tests                        | 77 alcotest cases (real) / 56 (mock)      |
| Tested platforms             | macOS arm64 (real and mock); Linux and macOS in CI (mock) |
| Windows                      | The configurator looks for Windows installs; untested |
| API stability                | 0.1.1, pre-1.0; expect additions          |

## Installation

```sh
opam install hexaly
```

The build looks for a Hexaly install. If it finds one it links the real
solver; otherwise it builds the bundled **mock backend**. The mock is a
brute-force test double for small models, not a solver. `Hexaly.backend ()`
reports which one you got, and `Hexaly.create` prints a one-time warning on
the mock unless `HEXALY_BACKEND=mock` is set.

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

The configurator also searches `/opt/hexaly_*`, `/Library/hexaly_*`,
`/usr/local/hexaly_*`, `$HOME/hexaly_*`, `C:/hexaly_*` and
`$ProgramFiles/hexaly_*`, so `HEXALY_HOME` is optional if Hexaly is in a
default location. Set `HEXALY_BACKEND=real` to make the build fail instead
of falling back to the mock.

To force the mock backend:
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
let pe = list_var m 10 in              (* routing: an ordered list *)
let s  = set_var m 10 in               (* a subset *)

(* Arithmetic, math, logical and conditional operators. *)
let e = if_ m
  (gt m y (int_const m 50))
  (mul m x y)
  (sum m [x; y])
in
add_constraint m (leq m e (int_const m 1000));
add_constraint m (leq m (count m s) (int_const m 3));

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
  Array.iter (Printf.printf " %d") (collection_value sol pe);
  print_newline ();
  Array.iter (Printf.printf " %d") (collection_value sol s);
  print_newline ()
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
  | Hexaly.Error.Model    -> Printf.eprintf "Modeling bug: %s\n" msg
  | Hexaly.Error.Solver   -> Printf.eprintf "Solver gave up: %s\n" msg
  | Hexaly.Error.Api      -> Printf.eprintf "API misuse: %s\n" msg
  | _ -> Printf.eprintf "Hexaly error: %s\n" msg
```

The 9 codes mirror Hexaly's `HxErrorCode`:
`Api | File | Model | Callback | License | Solver | Internal | Modeler | Cloud`.
The code is whatever Hexaly reports. In 14.5, a missing license file makes
`Hexaly.create` raise `Internal` (with a "Cannot open file" message), not
`License`.

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

Measured with `bench/build_million.ml` on an Apple Silicon Mac with
Hexaly 14.5 (timings vary by about 30% between runs):

| Operation                                       | Time       | Per unit           |
| ----------------------------------------------- | ---------- | ------------------ |
| Create 1000 int vars                            | < 1 ms     | < 1 µs / var       |
| Build 1M expression nodes                       | 190–240 ms | ~190–240 ns / node |
| `close` (Hexaly model compilation)              | 540–800 ms | one-shot           |
| Solve (1 sec time limit)                        | 40–60 ms   | depends on model   |

Expression construction goes through hand-written C stubs with a batched
`create_expression`, so a sum over 1000 operands crosses the FFI once.

Reproduce on your machine:
```sh
dune exec bench/build_million.exe
```

## Architecture

```
OCaml user code
   │  one record + custom-block per derived handle
   ▼
src/hexaly.ml + .mli              OCaml API + Error / State / Status /
   │                              Op / Callback_type / Inconsistency /
   │                              Phase / Version / Syntax modules
   ▼
src/hexaly_stubs.c                OCaml↔C glue: custom blocks, finalizers,
   │                              typed-exception raising, callback trampoline
   │                              that takes the OCaml runtime lock
   ▼
src/hexaly_shim_{real,mock}.cpp   extern "C" surface; catches every C++
   │                              exception into a thread-local (code, msg);
   │                              real links libhexaly, mock self-contained
   ▼
libhexaly14X.dylib / .so / .dll   Shipped with the Hexaly install
```

**Why a C shim.** Hexaly is C++ only and has no C ABI, so any OCaml binding
needs a thin `extern "C"` layer. It also gives two other things:

1. C++ exceptions are caught before they can reach the OCaml stack.
2. A self-contained mock backend implements the same ABI, so CI and
   contributors without a Hexaly license can build and test.

**Lifetimes.** Each derived handle (`model`, `param`, `solution`, `expr`,
`Inconsistency.t`, `Phase.t`, `callback`) is an OCaml record that holds its
parent. Holding any descendant keeps the optimizer alive; once nothing
refers to the optimizer or its descendants, the GC frees all of them. The
optimizer owns its callbacks, so a callback whose closure captures the
optimizer does not keep it alive.

**Callbacks across threads.** `solve` releases the OCaml runtime lock so
other OCaml threads can run and so Hexaly threads can call back into OCaml.
The trampoline registers the calling thread with the OCaml runtime,
acquires the lock, calls the closure with `caml_callback_exn` and releases
the lock. An exception raised by a closure is printed to stderr and
dropped, because it cannot propagate through Hexaly's C++ code. Do not call
`remove_callback` from inside a callback.

For the design rationale (how `HxOperator` drift is caught at compile time,
how the build picks the library on each platform, and how the
`static_assert` sentinels work), see [`docs/design.md`](docs/design.md).

## Documentation

- [API reference (odoc)](https://aalok-thakkar.github.io/ocaml-hexaly)
- [Design notes](docs/design.md): architecture, lifetime invariants,
  callback locking, ABI drift checks, cross-platform build.
- [Changelog](CHANGELOG.md)
- [Contributing guide](CONTRIBUTING.md)

## Comparison with the official bindings

Hexaly has official bindings for Python, Java, C# and C++. This binding
covers the same modeling surface in OCaml, with these differences:

- **Static typing.** Operators, parameters and errors are typed, so some
  model-building mistakes that Python reports at runtime are compile
  errors here.
- **GC-managed lifetimes.** An expression cannot outlive its optimizer. In
  C++ you keep the optimizer alive yourself.
- **Testing without a license.** The mock backend lets CI and contributors
  run most of the suite without Hexaly installed.

### Not yet bound

- `lambdaFunction` / `range` (the Python `m.array(m.range(0, n), lambda i: ...)`
  TSP idiom). The TSP example unrolls the sum instead.
- `HxExternalFunction` (custom evaluators called per iteration).

## Roadmap

- 0.2.0: `HxExternalFunction`, `lambdaFunction` and `range`.
- 0.3.0: more tuning helpers (Hexaly Studio import, surrogate parameters,
  named parameter accessors).
- 1.0.0: API freeze after a stability window.

## Contributing

Pull requests welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for how to
extend each of the four layers and how to handle Hexaly version changes.

If you use this binding, please open an issue saying what works and what
does not; that feedback will guide the 1.0.0 API.

## License

This binding is MIT licensed (see [`LICENSE`](LICENSE)).

The Hexaly Optimizer itself is proprietary and requires a separate license
from <https://www.hexaly.com/>. Free academic and trial licenses are
available. The OCaml binding needs no license; the solver does.

## Acknowledgments

Thanks to the Hexaly team for the C++ documentation the binding was checked
against.
