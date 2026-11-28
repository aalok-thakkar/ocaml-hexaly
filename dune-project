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
 (synopsis "OCaml bindings for the Hexaly Optimizer")
 (description
   "Bindings to the C++ API of the Hexaly Optimizer (formerly LocalSolver), a \
commercial optimization solver. Covers boolean, integer, float, interval, list \
and set decision variables, the expression operators, multi-objective phases, \
callbacks, and inconsistency analysis.\n\
\n\
Hexaly is proprietary and is not installed by this package. Get a license \
(academic, trial or commercial) from https://www.hexaly.com/ and point \
HEXALY_HOME at the install. If no install is found, the package builds a \
small brute-force mock instead, so that it compiles and its tests run without \
Hexaly. The mock is not a solver: Hexaly.create prints a warning when it is \
in use (unless HEXALY_BACKEND=mock), Hexaly.backend () reports which backend was built, and setting \
HEXALY_BACKEND=real makes the build fail instead of falling back.")
 (depends
  (ocaml (>= 4.14))
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
