(lang dune 3.0)
(name hexaly)
(version 0.1.1)

(generate_opam_files true)
(implicit_transitive_deps false)

(source (github aalok-thakkar/ocaml-hexaly))
(license MIT)
(authors "Aalok Thakkar")
(maintainers "Aalok Thakkar <thakkar@ashoka.edu.in>")
(documentation "https://aalok-thakkar.github.io/ocaml-hexaly")

(package
 (name hexaly)
 (synopsis
   "OCaml bindings for Hexaly Optimizer (interval, list, set variables included)")
 (description
   "Idiomatic OCaml interface to the Hexaly Optimizer (formerly LocalSolver), a commercial \
mathematical optimization solver. Binds the C++ HexalyOptimizer/HxModel/HxExpression API \
through a thin extern \"C\" shim and hand-written OCaml C stubs for near-zero per-call \
overhead.\n\
\n\
Features:\n\
- Bool, int, float, interval, list, and set decision variables.\n\
- Full arithmetic, math, logical, comparison, array, and scheduling operators.\n\
- Lexicographic multi-objective optimization via HxPhase.\n\
- Callbacks with proper OCaml runtime-lock handling for solver-worker threads.\n\
- Typed errors (Hexaly_error of Error.code * string) mirroring HxErrorCode.\n\
- Inconsistency analysis (IIS) for diagnosing infeasible models.\n\
- Warm-start hints via initial-solution setters.\n\
- A bundled mock backend so the library builds and the test suite runs \
without a Hexaly install (useful for CI and contributors without a license).\n\
\n\
The Hexaly Optimizer itself is proprietary; obtain a free academic license, \
30-day trial, or commercial license from https://www.hexaly.com/.")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.0))
  dune-configurator
  conf-c++
  (alcotest (and (>= 1.5) :with-test))
  (fmt (and (>= 0.9) :with-test))
  (odoc :with-doc))
 (tags
  ("optimization"
   "solver"
   "constraint-programming"
   "operations-research"
   "milp"
   "scheduling"
   "routing"
   "hexaly"
   "localsolver")))
