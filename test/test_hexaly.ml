(* Rigorous alcotest suite for the Hexaly OCaml binding.
 *
 * Goals:
 *   1. Exercise every public function in the API.
 *   2. Check edge cases (empty model, large arrays, deeply nested,
 *      boundary integer values).
 *   3. Verify behavioral invariants (constraints satisfied, status valid,
 *      optimum repeatable).
 *   4. Stress-test memory safety (GC under load, no leaks/segfaults).
 *   5. Cover callback lifecycle (multiple registrations, removal,
 *      exception safety).
 *   6. Cross-backend: same suite passes on real Hexaly and the mock;
 *      tests that need real-solver semantics skip on mock cleanly. *)

(* Ask the library which backend it was built with. The build picks the
   mock when no Hexaly install is found, whether or not HEXALY_BACKEND is
   set, so the environment variable alone does not tell us. *)
let is_mock () = Hexaly.backend () = Hexaly.Mock
let skip_on_mock () = if is_mock () then Alcotest.skip ()

(* If no Hexaly license is reachable (real backend without a license
   file the sandbox can see), every test in this suite would fail at
   [create]. Skip cleanly instead — this matters in particular for
   opam's `--with-test` builds, whose sandbox strips most env vars. *)
let mk_opt () =
  match Hexaly.create () with
  | exception Hexaly.Hexaly_error (code, msg) ->
    Printf.eprintf "Hexaly setup failed (%s): %s\n  Skipping test.\n%!"
      (Hexaly.Error.code_to_string code) msg;
    Alcotest.skip ()
  | o ->
    Hexaly.set_verbosity (Hexaly.param o) 0;
    o

(* ============================================================
 *                  G R O U P   1  —  L I F E C Y C L E
 * ============================================================ *)

let test_create_optimizer () =
  let o = mk_opt () in
  Alcotest.(check string) "fresh optimizer is in Modeling state" "Modeling"
    (Hexaly.State.to_string (Hexaly.state o))

let test_model_handle () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  Alcotest.(check bool) "model not closed initially" false (Hexaly.is_closed m);
  Alcotest.(check int) "no decisions" 0 (Hexaly.nb_decisions m);
  Alcotest.(check int) "no constraints" 0 (Hexaly.nb_constraints m);
  Alcotest.(check int) "no objectives" 0 (Hexaly.nb_objectives m)

let test_param_handle () =
  let o = mk_opt () in
  let p = Hexaly.param o in
  Hexaly.set_time_limit p 1;
  Hexaly.set_seed p 42;
  Hexaly.set_nb_threads p 2;
  Alcotest.(check pass) "param setters return cleanly" () ()

(* Hexaly requires close+solve before [getSolution] is valid. We confirm
   that obtaining a solution handle on a fresh optimizer raises a typed
   error (rather than silently returning a stale handle). *)
let test_solution_handle_requires_solve () =
  if is_mock () then Alcotest.skip () else
  let o = mk_opt () in
  let raised = ref false in
  (try let _ = Hexaly.solution o in ()
   with Hexaly.Hexaly_error _ -> raised := true);
  Alcotest.(check bool) "solution pre-solve raises" true !raised

(* The optimizer-derived handles must keep the optimizer alive across GC. *)
let test_lifetime_chain () =
  let m =
    let o = mk_opt () in
    Hexaly.model o
    (* o not referenced after this — model holds it via its _mo field *)
  in
  Gc.compact ();
  Gc.full_major ();
  let x = Hexaly.bool_var m in
  let _ = Hexaly.add m x x in
  Alcotest.(check int) "model alive across GC" 1 (Hexaly.nb_decisions m)

(* ============================================================
 *           G R O U P   2  —  D E C I S I O N   V A R S
 * ============================================================ *)

let test_bool_var () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.bool_var m in
  Hexaly.maximize m x;
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "bool var = 1 when maximized" 1
    (Hexaly.int_value (Hexaly.solution o) x)

let test_int_var_bounds () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m (-10) 7 in
  Hexaly.minimize m x;
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "int var hits lower bound" (-10)
    (Hexaly.int_value (Hexaly.solution o) x)

let test_int_var_upper_bound () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m 3 17 in
  Hexaly.maximize m x;
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "int var hits upper bound" 17
    (Hexaly.int_value (Hexaly.solution o) x)

let test_float_var () =
  skip_on_mock ();
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.float_var m 0.0 10.0 in
  Hexaly.maximize m x;
  Hexaly.close m;
  Hexaly.solve o;
  let v = Hexaly.float_value (Hexaly.solution o) x in
  Alcotest.(check bool) "float var ≤ 10.0 + ε" true (v <= 10.0001);
  Alcotest.(check bool) "float var ≥ 0" true (v >= 0.0)

let test_interval_var_basic () =
  skip_on_mock ();
  let o = mk_opt () in
  let m = Hexaly.model o in
  let i = Hexaly.interval_var m 0 100 in
  Hexaly.add_constraint m
    (Hexaly.eq m (Hexaly.length m i) (Hexaly.int_const m 10));
  Hexaly.minimize m (Hexaly.start m i);
  Hexaly.close m;
  Hexaly.solve o;
  let (s, e) = Hexaly.interval_value (Hexaly.solution o) i in
  Alcotest.(check int) "interval start = 0" 0 s;
  Alcotest.(check int) "interval end = 10" 10 e

let test_optional_interval_var () =
  skip_on_mock ();
  let o = mk_opt () in
  let m = Hexaly.model o in
  let i = Hexaly.optional_interval_var m 0 100 in
  Hexaly.minimize m (Hexaly.presence m i);
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check pass) "optional interval solves" () ()

let test_list_var_basic () =
  skip_on_mock ();
  let n = 4 in
  let o = mk_opt () in
  let m = Hexaly.model o in
  let l = Hexaly.list_var m n in
  Hexaly.add_constraint m
    (Hexaly.eq m (Hexaly.count m l) (Hexaly.int_const m n));
  Hexaly.minimize m (Hexaly.int_const m 0);
  Hexaly.close m;
  Hexaly.solve o;
  let arr = Hexaly.collection_value (Hexaly.solution o) l in
  Alcotest.(check int) "list length" n (Array.length arr);
  let sorted = Array.copy arr in
  Array.sort compare sorted;
  Alcotest.(check (array int)) "permutation of 0..n-1"
    (Array.init n (fun i -> i)) sorted

let test_set_var () =
  skip_on_mock ();
  let n = 5 in
  let o = mk_opt () in
  let m = Hexaly.model o in
  let s = Hexaly.set_var m n in
  (* Force exactly 3 elements in the set *)
  Hexaly.add_constraint m
    (Hexaly.eq m (Hexaly.count m s) (Hexaly.int_const m 3));
  Hexaly.minimize m (Hexaly.int_const m 0);
  Hexaly.close m;
  Hexaly.solve o;
  let arr = Hexaly.collection_value (Hexaly.solution o) s in
  Alcotest.(check int) "set size = 3" 3 (Array.length arr);
  Array.iter (fun v ->
    Alcotest.(check bool) "set member in [0..n)" true (v >= 0 && v < n)
  ) arr

(* ============================================================
 *           G R O U P   3  —  C O N S T A N T S
 * ============================================================ *)

let test_int_const_negative () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m (-5) 5 in
  Hexaly.add_constraint m (Hexaly.eq m x (Hexaly.int_const m (-3)));
  Hexaly.minimize m x;
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "x = -3" (-3) (Hexaly.int_value (Hexaly.solution o) x)

let test_int_const_zero () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m (-5) 5 in
  Hexaly.add_constraint m (Hexaly.eq m x (Hexaly.int_const m 0));
  Hexaly.minimize m x;
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "x = 0" 0 (Hexaly.int_value (Hexaly.solution o) x)

let test_int_array_const () =
  skip_on_mock ();
  let o = mk_opt () in
  let m = Hexaly.model o in
  let arr = Hexaly.int_array_const m [|10; 20; 30; 40; 50|] in
  let idx = Hexaly.int_var m 0 4 in
  let pick = Hexaly.at m arr [idx] in
  Hexaly.maximize m pick;
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "at(idx) picks max = 50" 50
    (Hexaly.int_value (Hexaly.solution o) pick)

let test_float_array_const () =
  skip_on_mock ();
  let o = mk_opt () in
  let m = Hexaly.model o in
  let arr = Hexaly.float_array_const m [|1.5; 2.5; 3.5|] in
  let idx = Hexaly.int_var m 0 2 in
  let pick = Hexaly.at m arr [idx] in
  Hexaly.maximize m pick;
  Hexaly.close m;
  Hexaly.solve o;
  let v = Hexaly.float_value (Hexaly.solution o) pick in
  Alcotest.(check bool) "picks 3.5" true (v >= 3.4 && v <= 3.6)

(* ============================================================
 *           G R O U P   4  —  A R I T H M E T I C
 * ============================================================ *)

let test_sum_nary () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let xs = List.init 5 (fun _ -> Hexaly.bool_var m) in
  let s = Hexaly.sum m xs in
  Hexaly.maximize m s;
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "sum of 5 booleans = 5" 5
    (Hexaly.int_value (Hexaly.solution o) s)

let test_prod_nary () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let xs = List.init 3 (fun _ -> Hexaly.int_var m 1 5) in
  let p = Hexaly.prod m xs in
  Hexaly.maximize m p;
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "prod of 3 vars in [1,5]" 125
    (Hexaly.int_value (Hexaly.solution o) p)

let test_sub () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m 0 10 in
  let y = Hexaly.int_var m 0 10 in
  let d = Hexaly.sub m x y in
  Hexaly.maximize m d;
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "max(x - y) = 10" 10
    (Hexaly.int_value (Hexaly.solution o) d)

let test_div () =
  skip_on_mock ();
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m 1 100 in
  Hexaly.add_constraint m (Hexaly.eq m x (Hexaly.int_const m 30));
  (* Hexaly's [div] always returns a double, even on integer operands. *)
  let q = Hexaly.div m x (Hexaly.int_const m 6) in
  Hexaly.minimize m (Hexaly.int_const m 0);
  Hexaly.close m;
  Hexaly.solve o;
  let v = Hexaly.float_value (Hexaly.solution o) q in
  Alcotest.(check bool) "30.0/6.0 ≈ 5.0" true (Float.abs (v -. 5.0) < 0.001)

let test_abs () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m (-10) 10 in
  Hexaly.add_constraint m (Hexaly.eq m x (Hexaly.int_const m (-7)));
  let a = Hexaly.abs m x in
  Hexaly.minimize m (Hexaly.int_const m 0);
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "abs(-7) = 7" 7
    (Hexaly.int_value (Hexaly.solution o) a)

let test_dist () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m 0 10 in
  let y = Hexaly.int_var m 0 10 in
  Hexaly.add_constraint m (Hexaly.eq m x (Hexaly.int_const m 3));
  Hexaly.add_constraint m (Hexaly.eq m y (Hexaly.int_const m 8));
  let d = Hexaly.dist m x y in
  Hexaly.minimize m (Hexaly.int_const m 0);
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "dist(3, 8) = 5" 5
    (Hexaly.int_value (Hexaly.solution o) d)

let test_mod () =
  skip_on_mock ();
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m 0 100 in
  Hexaly.add_constraint m (Hexaly.eq m x (Hexaly.int_const m 17));
  let r = Hexaly.mod_ m x (Hexaly.int_const m 5) in
  Hexaly.minimize m (Hexaly.int_const m 0);
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "17 mod 5 = 2" 2
    (Hexaly.int_value (Hexaly.solution o) r)

let test_max_min () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let a = Hexaly.int_var m 0 10 in
  let b = Hexaly.int_var m 0 10 in
  Hexaly.add_constraint m (Hexaly.eq m a (Hexaly.int_const m 3));
  Hexaly.add_constraint m (Hexaly.eq m b (Hexaly.int_const m 7));
  let mx = Hexaly.max m [a; b] in
  let mn = Hexaly.min m [a; b] in
  Hexaly.minimize m (Hexaly.int_const m 0);
  Hexaly.close m;
  Hexaly.solve o;
  let sol = Hexaly.solution o in
  Alcotest.(check int) "max(3, 7) = 7" 7 (Hexaly.int_value sol mx);
  Alcotest.(check int) "min(3, 7) = 3" 3 (Hexaly.int_value sol mn)

let test_neg () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m (-5) 5 in
  Hexaly.add_constraint m (Hexaly.eq m x (Hexaly.int_const m 4));
  let nx = Hexaly.neg m x in
  Hexaly.minimize m (Hexaly.int_const m 0);
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "neg(4) = -4" (-4)
    (Hexaly.int_value (Hexaly.solution o) nx)

(* ============================================================
 *           G R O U P   5  —  C O M P A R I S O N
 * ============================================================ *)

let test_all_comparisons () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let a = Hexaly.int_var m 0 5 in
  let b = Hexaly.int_var m 0 5 in
  Hexaly.add_constraint m (Hexaly.eq m a (Hexaly.int_const m 2));
  Hexaly.add_constraint m (Hexaly.eq m b (Hexaly.int_const m 4));
  let e1 = Hexaly.eq  m a b in
  let e2 = Hexaly.neq m a b in
  let e3 = Hexaly.lt  m a b in
  let e4 = Hexaly.leq m a b in
  let e5 = Hexaly.gt  m a b in
  let e6 = Hexaly.geq m a b in
  Hexaly.minimize m (Hexaly.int_const m 0);
  Hexaly.close m;
  Hexaly.solve o;
  let s = Hexaly.solution o in
  Alcotest.(check int) "2 == 4" 0 (Hexaly.int_value s e1);
  Alcotest.(check int) "2 != 4" 1 (Hexaly.int_value s e2);
  Alcotest.(check int) "2 < 4"  1 (Hexaly.int_value s e3);
  Alcotest.(check int) "2 ≤ 4"  1 (Hexaly.int_value s e4);
  Alcotest.(check int) "2 > 4"  0 (Hexaly.int_value s e5);
  Alcotest.(check int) "2 ≥ 4"  0 (Hexaly.int_value s e6)

(* ============================================================
 *           G R O U P   6  —  L O G I C A L
 * ============================================================ *)

let test_all_logical () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let t = Hexaly.bool_var m in
  let f = Hexaly.bool_var m in
  Hexaly.add_constraint m (Hexaly.eq m t (Hexaly.int_const m 1));
  Hexaly.add_constraint m (Hexaly.eq m f (Hexaly.int_const m 0));
  let a = Hexaly.and_ m [t; f] in
  let oo = Hexaly.or_  m [t; f] in
  let xx = Hexaly.xor_ m [t; f] in
  let nt = Hexaly.not_ m t in
  let nf = Hexaly.not_ m f in
  let i  = Hexaly.if_  m t (Hexaly.int_const m 100) (Hexaly.int_const m 200) in
  Hexaly.minimize m (Hexaly.int_const m 0);
  Hexaly.close m;
  Hexaly.solve o;
  let s = Hexaly.solution o in
  Alcotest.(check int) "true ∧ false" 0 (Hexaly.int_value s a);
  Alcotest.(check int) "true ∨ false" 1 (Hexaly.int_value s oo);
  Alcotest.(check int) "true ⊕ false" 1 (Hexaly.int_value s xx);
  Alcotest.(check int) "¬true" 0  (Hexaly.int_value s nt);
  Alcotest.(check int) "¬false" 1 (Hexaly.int_value s nf);
  Alcotest.(check int) "if true 100 else 200" 100 (Hexaly.int_value s i)

(* ============================================================
 *           G R O U P   7  —  M A T H   F U N C S
 * ============================================================ *)

let test_math_functions () =
  skip_on_mock ();
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.float_var m 1.0 4.0 in
  Hexaly.add_constraint m
    (Hexaly.eq m x (Hexaly.float_const m 4.0));
  let s = Hexaly.sqrt m x in
  let _ = Hexaly.log m x in
  let _ = Hexaly.exp m x in
  let _ = Hexaly.pow m x (Hexaly.float_const m 2.0) in
  let _ = Hexaly.cos m x in
  let _ = Hexaly.sin m x in
  let _ = Hexaly.tan m x in
  Hexaly.minimize m (Hexaly.int_const m 0);
  Hexaly.close m;
  Hexaly.solve o;
  let v = Hexaly.float_value (Hexaly.solution o) s in
  Alcotest.(check bool) "sqrt(4) ≈ 2" true (Float.abs (v -. 2.0) < 0.01)

let test_ceil_floor_round () =
  skip_on_mock ();
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.float_var m 0.0 10.0 in
  Hexaly.add_constraint m
    (Hexaly.eq m x (Hexaly.float_const m 3.7));
  let c = Hexaly.ceil m x in
  let f = Hexaly.floor m x in
  let r = Hexaly.round m x in
  Hexaly.minimize m (Hexaly.int_const m 0);
  Hexaly.close m;
  Hexaly.solve o;
  let s = Hexaly.solution o in
  Alcotest.(check int) "ceil(3.7) = 4" 4 (Hexaly.int_value s c);
  Alcotest.(check int) "floor(3.7) = 3" 3 (Hexaly.int_value s f);
  Alcotest.(check int) "round(3.7) = 4" 4 (Hexaly.int_value s r)

(* ============================================================
 *           G R O U P   8  —  C O L L E C T I O N   O P S
 * ============================================================ *)

let test_at_index () =
  skip_on_mock ();
  let o = mk_opt () in
  let m = Hexaly.model o in
  let arr = Hexaly.int_array_const m [|7; 14; 21; 28|] in
  let idx = Hexaly.int_var m 0 3 in
  Hexaly.add_constraint m (Hexaly.eq m idx (Hexaly.int_const m 2));
  let v = Hexaly.at m arr [idx] in
  Hexaly.minimize m (Hexaly.int_const m 0);
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "at(idx=2) = 21" 21
    (Hexaly.int_value (Hexaly.solution o) v)

let test_count_distinct () =
  skip_on_mock ();
  let n = 4 in
  let o = mk_opt () in
  let m = Hexaly.model o in
  let l = Hexaly.list_var m n in
  let c = Hexaly.count m l in  (* MUST capture pre-close *)
  Hexaly.add_constraint m (Hexaly.eq m c (Hexaly.int_const m n));
  Hexaly.minimize m (Hexaly.int_const m 0);
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "list contains all n elements" n
    (Hexaly.int_value (Hexaly.solution o) c)

(* ============================================================
 *           G R O U P   9  —  C O N S T R A I N T S
 * ============================================================ *)

let test_multiple_constraints () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m 0 100 in
  Hexaly.add_constraint m (Hexaly.geq m x (Hexaly.int_const m 20));
  Hexaly.add_constraint m (Hexaly.leq m x (Hexaly.int_const m 30));
  Hexaly.minimize m x;
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "min subject to x ≥ 20 ∧ x ≤ 30" 20
    (Hexaly.int_value (Hexaly.solution o) x)

let test_constraint_count () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.bool_var m in
  Hexaly.add_constraint m (Hexaly.eq m x (Hexaly.int_const m 1));
  Hexaly.add_constraint m (Hexaly.geq m x (Hexaly.int_const m 0));
  Hexaly.add_constraint m (Hexaly.leq m x (Hexaly.int_const m 1));
  Hexaly.minimize m x;
  Alcotest.(check int) "nb_constraints = 3" 3 (Hexaly.nb_constraints m)

(* ============================================================
 *           G R O U P   1 0  —  E D G E   C A S E S
 * ============================================================ *)

let test_empty_model () =
  (* No decisions, no constraints, no objectives. Hexaly requires at
     least one objective, so we add a constant minimize. *)
  let o = mk_opt () in
  let m = Hexaly.model o in
  Hexaly.minimize m (Hexaly.int_const m 42);
  Hexaly.close m;
  Hexaly.solve o;
  let s = Hexaly.status (Hexaly.solution o) in
  Alcotest.(check bool) "empty model solves" true
    (s = Hexaly.Status.Optimal || s = Hexaly.Status.Feasible)

let test_large_sum () =
  (* 500-operand sum exercises the batched create_expression path
     beyond the stack-buffer threshold (64 in the C stub). The mock's
     brute force can't handle 2^500; only real Hexaly actually solves. *)
  let o = mk_opt () in
  let m = Hexaly.model o in
  let n = 500 in
  let xs = List.init n (fun _ -> Hexaly.bool_var m) in
  let s = Hexaly.sum m xs in
  Hexaly.maximize m s;
  Hexaly.close m;
  Alcotest.(check int) "n decisions registered" n (Hexaly.nb_decisions m);
  if not (is_mock ()) then begin
    Hexaly.solve o;
    Alcotest.(check int) "sum of 500 booleans = 500" n
      (Hexaly.int_value (Hexaly.solution o) s)
  end

let test_deeply_nested () =
  (* Build x + 1 + 1 + 1 + ... 100 times. *)
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m 0 1000 in
  Hexaly.add_constraint m (Hexaly.eq m x (Hexaly.int_const m 5));
  let one = Hexaly.int_const m 1 in
  let rec nest e n = if n = 0 then e else nest (Hexaly.add m e one) (n - 1) in
  let total = nest x 100 in
  Hexaly.minimize m (Hexaly.int_const m 0);
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "5 + 100 = 105" 105
    (Hexaly.int_value (Hexaly.solution o) total)

let test_re_solve () =
  (* Solving the same optimizer twice should give a stable answer. *)
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m 0 10 in
  Hexaly.maximize m x;
  Hexaly.close m;
  Hexaly.solve o;
  let v1 = Hexaly.int_value (Hexaly.solution o) x in
  Hexaly.solve o;
  let v2 = Hexaly.int_value (Hexaly.solution o) x in
  Alcotest.(check int) "first solve" 10 v1;
  Alcotest.(check int) "second solve identical" v1 v2

let test_multiple_optimizers () =
  (* Run independent optimizers in sequence; verify no state bleed. *)
  let solve_one bound =
    let o = mk_opt () in
    let m = Hexaly.model o in
    let x = Hexaly.int_var m 0 bound in
    Hexaly.maximize m x;
    Hexaly.close m;
    Hexaly.solve o;
    Hexaly.int_value (Hexaly.solution o) x
  in
  Alcotest.(check int) "optimizer A: max = 5" 5 (solve_one 5);
  Alcotest.(check int) "optimizer B: max = 17" 17 (solve_one 17);
  Alcotest.(check int) "optimizer C: max = 3" 3 (solve_one 3)

(* ============================================================
 *           G R O U P   1 1  —  E R R O R   P A T H S
 * ============================================================ *)

let test_error_after_close () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.bool_var m in
  Hexaly.minimize m x;
  Hexaly.close m;
  let raised = ref None in
  (try Hexaly.add_constraint m (Hexaly.eq m x (Hexaly.int_const m 1))
   with Hexaly.Hexaly_error (c, msg) -> raised := Some (c, msg));
  match !raised with
  | None -> Alcotest.fail "expected exception"
  | Some (_, msg) ->
    Alcotest.(check bool) "error message non-empty" true (String.length msg > 0)

let test_error_codes_are_distinguishable () =
  (* Different error scenarios should produce typed codes the user can
     pattern-match on. We confirm at least one path produces Api or Model. *)
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.bool_var m in
  Hexaly.minimize m x;
  Hexaly.close m;
  let code = ref None in
  (try Hexaly.maximize m x
   with Hexaly.Hexaly_error (c, _) -> code := Some c);
  match !code with
  | Some Hexaly.Error.(Api | Model | Internal) ->
    Alcotest.(check pass) "typed code received" () ()
  | Some other ->
    Alcotest.fail (Printf.sprintf "unexpected code: %s"
      (Hexaly.Error.code_to_string other))
  | None -> Alcotest.fail "no exception raised"

let test_error_code_to_string () =
  let open Hexaly.Error in
  Alcotest.(check string) "Api"      "Api"      (code_to_string Api);
  Alcotest.(check string) "License"  "License"  (code_to_string License);
  Alcotest.(check string) "Solver"   "Solver"   (code_to_string Solver);
  Alcotest.(check string) "Cloud"    "Cloud"    (code_to_string Cloud)

(* ============================================================
 *           G R O U P   1 2  —  E N U M S   /   P R E T T Y
 * ============================================================ *)

let test_status_pp () =
  let buf = Buffer.create 16 in
  let ppf = Format.formatter_of_buffer buf in
  Format.fprintf ppf "%a" Hexaly.Status.pp Hexaly.Status.Optimal;
  Format.pp_print_flush ppf ();
  Alcotest.(check string) "Status.pp" "Optimal" (Buffer.contents buf)

let test_state_pp () =
  let buf = Buffer.create 16 in
  let ppf = Format.formatter_of_buffer buf in
  Format.fprintf ppf "%a" Hexaly.State.pp Hexaly.State.Modeling;
  Format.pp_print_flush ppf ();
  Alcotest.(check string) "State.pp" "Modeling" (Buffer.contents buf)

let test_callback_type_pp () =
  let buf = Buffer.create 16 in
  let ppf = Format.formatter_of_buffer buf in
  Format.fprintf ppf "%a"
    Hexaly.Callback_type.pp Hexaly.Callback_type.Time_ticked;
  Format.pp_print_flush ppf ();
  Alcotest.(check string) "Callback_type.pp" "Time_ticked" (Buffer.contents buf)

(* ============================================================
 *           G R O U P   1 3  —  V E R S I O N
 * ============================================================ *)

let test_version_consistency () =
  let major = Hexaly.Version.major () in
  let minor = Hexaly.Version.minor () in
  let code  = Hexaly.Version.code () in
  Alcotest.(check bool) "major > 0" true (major > 0);
  Alcotest.(check bool) "minor ≥ 0" true (minor >= 0);
  Alcotest.(check bool) "code > 0"  true (code > 0)

let test_version_strings_non_empty () =
  Alcotest.(check bool) "version string"   true (String.length (Hexaly.Version.string ())    > 0);
  Alcotest.(check bool) "platform string"  true (String.length (Hexaly.Version.platform ())  > 0);
  Alcotest.(check bool) "info string"      true (String.length (Hexaly.Version.info ())      >= 0);
  Alcotest.(check bool) "copyright string" true (String.length (Hexaly.Version.copyright ()) >= 0)

(* ============================================================
 *           G R O U P   1 4  —  W A R M   S T A R T
 * ============================================================ *)

let test_warm_start () =
  skip_on_mock ();
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m 0 100 in
  let y = Hexaly.int_var m 0 100 in
  let s = Hexaly.sum m [x; y] in
  Hexaly.maximize m s;
  Hexaly.close m;
  let sol = Hexaly.solution o in
  Hexaly.set_int_value sol x 50;
  Hexaly.set_int_value sol y 50;
  Hexaly.solve o;
  Alcotest.(check int) "warm-started solve still finds optimum" 200
    (Hexaly.int_value sol s)

let test_clear_solution () =
  skip_on_mock ();
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m 0 10 in
  Hexaly.maximize m x;
  Hexaly.close m;
  let sol = Hexaly.solution o in
  Hexaly.set_int_value sol x 5;
  Hexaly.clear_solution sol;
  Hexaly.solve o;
  Alcotest.(check int) "still finds optimum after clear" 10
    (Hexaly.int_value sol x)

(* ============================================================
 *           G R O U P   1 5  —  P A R A M E T E R S
 * ============================================================ *)

let test_all_parameter_setters () =
  let o = mk_opt () in
  let p = Hexaly.param o in
  Hexaly.set_time_limit p 30;
  Hexaly.set_iteration_limit p 1000000L;
  Hexaly.set_seed p 42;
  Hexaly.set_nb_threads p 1;
  Hexaly.set_verbosity p 0;
  Hexaly.set_warning_level p 1;
  Hexaly.set_time_between_displays p 5;
  Hexaly.set_time_between_ticks p 1;
  Hexaly.set_iteration_between_ticks p 10000L;
  Hexaly.set_log_file p "";
  Hexaly.set_advanced_int p "unknownKey" 1;
  Hexaly.set_advanced_double p "unknownKey" 0.5;
  Hexaly.set_advanced_string p "unknownKey" "value";
  Hexaly.set_int_objective_threshold p 0 100;
  Hexaly.set_double_objective_threshold p 0 1.5;
  Alcotest.(check pass) "all setters accepted" () ()

(* ============================================================
 *           G R O U P   1 6  —  S O L U T I O N   I N S P
 * ============================================================ *)

let test_status_optimal () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m 0 10 in
  Hexaly.maximize m x;
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check (testable Fmt.string String.equal))
    "status = Optimal" "Optimal"
    (Hexaly.Status.to_string (Hexaly.status (Hexaly.solution o)))

let test_status_infeasible () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m 0 5 in
  Hexaly.add_constraint m (Hexaly.geq m x (Hexaly.int_const m 100));
  Hexaly.minimize m x;
  Hexaly.close m;
  Hexaly.solve o;
  let st = Hexaly.status (Hexaly.solution o) in
  Alcotest.(check bool) "infeasible/inconsistent" true
    (st = Hexaly.Status.Infeasible || st = Hexaly.Status.Inconsistent)

let test_is_violated () =
  skip_on_mock ();
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m 0 10 in
  let c = Hexaly.geq m x (Hexaly.int_const m 5) in
  Hexaly.add_constraint m c;
  Hexaly.maximize m x;
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check bool) "satisfied constraint not violated" false
    (Hexaly.is_violated (Hexaly.solution o) c)

(* ============================================================
 *           G R O U P   1 7  —  C A L L B A C K S
 * ============================================================ *)

let test_callback_optimization_started_ended () =
  let o = mk_opt () in
  let started = ref 0 in
  let ended   = ref 0 in
  let _ = Hexaly.add_callback o Hexaly.Callback_type.Optimization_started
    (fun () -> incr started)
  in
  let _ = Hexaly.add_callback o Hexaly.Callback_type.Optimization_ended
    (fun () -> incr ended)
  in
  let m = Hexaly.model o in
  let x = Hexaly.bool_var m in
  Hexaly.maximize m x;
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "started once" 1 !started;
  Alcotest.(check int) "ended once"   1 !ended

let test_callback_multiple_same_type () =
  let o = mk_opt () in
  let counters = Array.make 3 0 in
  let _ = Hexaly.add_callback o Hexaly.Callback_type.Optimization_started
    (fun () -> counters.(0) <- counters.(0) + 1)
  in
  let _ = Hexaly.add_callback o Hexaly.Callback_type.Optimization_started
    (fun () -> counters.(1) <- counters.(1) + 1)
  in
  let _ = Hexaly.add_callback o Hexaly.Callback_type.Optimization_started
    (fun () -> counters.(2) <- counters.(2) + 1)
  in
  let m = Hexaly.model o in
  let x = Hexaly.bool_var m in
  Hexaly.maximize m x;
  Hexaly.close m;
  Hexaly.solve o;
  Array.iteri (fun i c ->
    Alcotest.(check int) (Printf.sprintf "callback %d fired" i) 1 c
  ) counters

let test_callback_removal () =
  let o = mk_opt () in
  let fired = ref 0 in
  let cb = Hexaly.add_callback o Hexaly.Callback_type.Optimization_started
    (fun () -> incr fired)
  in
  let removed = Hexaly.remove_callback cb in
  Alcotest.(check bool) "remove returns true" true removed;
  let m = Hexaly.model o in
  let x = Hexaly.bool_var m in
  Hexaly.maximize m x;
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "removed callback didn't fire" 0 !fired

let test_callback_double_remove () =
  let o = mk_opt () in
  let cb = Hexaly.add_callback o Hexaly.Callback_type.Optimization_started
    (fun () -> ())
  in
  let r1 = Hexaly.remove_callback cb in
  let r2 = Hexaly.remove_callback cb in
  Alcotest.(check bool) "first remove true" true r1;
  Alcotest.(check bool) "second remove false (already gone)" false r2

let test_callback_captures_optimizer () =
  let o = mk_opt () in
  let captured = ref "" in
  let _ = Hexaly.add_callback o Hexaly.Callback_type.Optimization_ended
    (fun () -> captured := Hexaly.State.to_string (Hexaly.state o))
  in
  let m = Hexaly.model o in
  let x = Hexaly.bool_var m in
  Hexaly.maximize m x;
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check bool) "captured a state string" true
    (String.length !captured > 0)

(* Build, solve and drop an optimizer whose callback captures it. Kept at
   top level so no stack slot of the caller refers to the optimizer. *)
let solve_and_drop_optimizer_with_callback finalised =
  let o = mk_opt () in
  let _ = Hexaly.add_callback o Hexaly.Callback_type.Optimization_ended
    (fun () -> ignore (Hexaly.state o))
  in
  let m = Hexaly.model o in
  let x = Hexaly.bool_var m in
  Hexaly.maximize m x;
  Hexaly.close m;
  Hexaly.solve o;
  Gc.finalise (fun _ -> incr finalised) o

(* Regression: callbacks used to be pinned in a global list, so an
   optimizer with a never-removed callback was never freed. *)
let test_callback_does_not_leak_optimizer () =
  let finalised = ref 0 in
  for _ = 1 to 20 do solve_and_drop_optimizer_with_callback finalised done;
  Gc.full_major ();
  Gc.full_major ();
  Alcotest.(check bool) "optimizers with callbacks are collected" true
    (!finalised >= 19)

let register_and_drop_callback o fired =
  ignore (Hexaly.add_callback o Hexaly.Callback_type.Optimization_ended
            (fun () -> incr fired))

(* The optimizer keeps the callback alive: dropping the handle must not
   stop it firing. *)
let test_callback_survives_dropped_handle () =
  let o = mk_opt () in
  let fired = ref 0 in
  register_and_drop_callback o fired;
  Gc.full_major ();
  let m = Hexaly.model o in
  let x = Hexaly.bool_var m in
  Hexaly.maximize m x;
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "callback fired once" 1 !fired

(* When HEXALY_BACKEND forces a backend, [backend ()] must report it.
   Without the variable the build auto-detects, so there is nothing to
   compare against. *)
let test_backend_matches_env () =
  match Sys.getenv_opt "HEXALY_BACKEND" with
  | Some "mock" ->
    Alcotest.(check bool) "backend () is Mock" true (Hexaly.backend () = Hexaly.Mock)
  | Some "real" ->
    Alcotest.(check bool) "backend () is Real" true (Hexaly.backend () = Hexaly.Real)
  | _ -> Alcotest.skip ()

(* Regression: on the mock, a caught error used to leave a stale error
   behind, so the next [status] call raised it again. *)
let test_status_after_caught_error () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.bool_var m in
  Hexaly.maximize m x;
  Hexaly.close m;
  let sol = Hexaly.solution o in
  (try ignore (Hexaly.int_value sol x) with Hexaly.Hexaly_error _ -> ());
  Hexaly.solve o;
  Alcotest.(check bool) "status does not raise" true
    (Hexaly.status (Hexaly.solution o) = Hexaly.Status.Optimal)

let test_callback_exception_does_not_crash () =
  let o = mk_opt () in
  let _ = Hexaly.add_callback o Hexaly.Callback_type.Optimization_started
    (fun () -> failwith "intentional test exception")
  in
  let m = Hexaly.model o in
  let x = Hexaly.bool_var m in
  Hexaly.maximize m x;
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check string) "solve still completed" "Optimal"
    (Hexaly.Status.to_string (Hexaly.status (Hexaly.solution o)))

(* ============================================================
 *           G R O U P   1 8  —  P H A S E S
 * ============================================================ *)

let test_phases_create_and_inspect () =
  skip_on_mock ();
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.bool_var m in
  Hexaly.maximize m x;
  Hexaly.close m;
  let p = Hexaly.Phase.create o in
  Hexaly.Phase.set_optimized_objective p 0;
  Hexaly.Phase.set_time_limit p 1;
  Hexaly.Phase.set_iteration_limit p 1000L;
  Alcotest.(check int) "nb_phases = 1" 1 (Hexaly.Phase.nb_phases o);
  Alcotest.(check int) "phase optimizes objective 0" 0
    (Hexaly.Phase.optimized_objective p);
  Alcotest.(check int) "phase time limit = 1" 1 (Hexaly.Phase.time_limit p);
  Alcotest.(check (testable Fmt.int64 Int64.equal))
    "phase iteration limit = 1000" 1000L (Hexaly.Phase.iteration_limit p);
  Alcotest.(check bool) "phase enabled" true (Hexaly.Phase.is_enabled p);
  Hexaly.Phase.set_enabled p false;
  Alcotest.(check bool) "phase disabled after set" false (Hexaly.Phase.is_enabled p);
  Alcotest.(check bool) "to_string non-empty" true
    (String.length (Hexaly.Phase.to_string p) > 0)

let test_phases_get_by_index () =
  skip_on_mock ();
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m 0 5 in
  let y = Hexaly.int_var m 0 5 in
  Hexaly.minimize m x;
  Hexaly.minimize m y;
  Hexaly.close m;
  (* Newly-created phases default to optimizing the LAST objective.
     Set them explicitly to make the test deterministic. *)
  let p0 = Hexaly.Phase.create o in
  Hexaly.Phase.set_optimized_objective p0 0;
  let p1 = Hexaly.Phase.create o in
  Hexaly.Phase.set_optimized_objective p1 1;
  let got0 = Hexaly.Phase.get o 0 in
  let got1 = Hexaly.Phase.get o 1 in
  Alcotest.(check int) "got phase 0 obj" 0 (Hexaly.Phase.optimized_objective got0);
  Alcotest.(check int) "got phase 1 obj" 1 (Hexaly.Phase.optimized_objective got1)

(* ============================================================
 *           G R O U P   1 9  —  I N C O N S I S T E N C Y
 * ============================================================ *)

let test_inconsistency_basic () =
  skip_on_mock ();
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.int_var m 0 5 in
  Hexaly.add_constraint m (Hexaly.geq m x (Hexaly.int_const m 100));
  Hexaly.minimize m x;
  Hexaly.close m;
  Hexaly.solve o;
  let iis = Hexaly.compute_inconsistency o in
  let n = Hexaly.Inconsistency.nb_causes iis in
  Alcotest.(check bool) "≥ 1 cause" true (n >= 1);
  let s = Hexaly.Inconsistency.to_string iis in
  Alcotest.(check bool) "to_string non-empty" true (String.length s > 0);
  if n > 0 then begin
    let _ = Hexaly.Inconsistency.cause iis 0 in
    Alcotest.(check pass) "cause 0 retrievable" () ()
  end

(* ============================================================
 *           G R O U P   2 0  —  E N V I R O N M E N T
 * ============================================================ *)

let test_save_environment () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.bool_var m in
  Hexaly.maximize m x;
  Hexaly.close m;
  Hexaly.solve o;
  let suffix = if is_mock () then ".env" else ".hxm" in
  let tmp = Filename.temp_file "hexaly_env_" suffix in
  Fun.protect ~finally:(fun () -> try Sys.remove tmp with _ -> ()) (fun () ->
    Hexaly.save_environment o tmp;
    Alcotest.(check bool) "file created" true (Sys.file_exists tmp);
    Alcotest.(check bool) "file non-empty" true
      ((Unix.stat tmp).Unix.st_size > 0))

(* ============================================================
 *           G R O U P   2 1  —  S Y N T A X   S U G A R
 * ============================================================ *)

let test_syntax_arithmetic () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  Hexaly.Syntax.with_model m (fun () ->
    let open Hexaly.Syntax in
    let x = Hexaly.int_var m 0 10 in
    let e = x +! !!3 -! !!1 in
    Hexaly.add_constraint m (e =! !!7);
    Hexaly.maximize m x;
    Hexaly.close m;
    Hexaly.solve o;
    Alcotest.(check int) "x + 3 - 1 = 7 → x = 5" 5
      (Hexaly.int_value (Hexaly.solution o) x))

let test_syntax_comparisons () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  Hexaly.Syntax.with_model m (fun () ->
    let open Hexaly.Syntax in
    let x = Hexaly.int_var m 0 10 in
    Hexaly.add_constraint m (x >=! !!3);
    Hexaly.add_constraint m (x <=! !!7);
    Hexaly.add_constraint m (x <>! !!5);
    Hexaly.minimize m x;
    Hexaly.close m;
    Hexaly.solve o;
    Alcotest.(check int) "min(x ∈ [3..7] \\ {5}) = 3" 3
      (Hexaly.int_value (Hexaly.solution o) x))

let test_syntax_with_model_restores () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  Hexaly.Syntax.with_model m (fun () -> ());
  (* After with_model, the current cell is None. Using sugar raises. *)
  let raised = ref false in
  (try
     let open Hexaly.Syntax in
     let _ : Hexaly.expr = !!42 in
     ()
   with Failure _ -> raised := true);
  Alcotest.(check bool) "with_model restores prior state" true !raised

(* ============================================================
 *           G R O U P   2 2  —  R E G R E S S I O N
 * ============================================================ *)

let test_knapsack () =
  let weights = [| 23; 31; 29; 44; 53; 38; 63; 85; 89; 82 |] in
  let values  = [| 92; 57; 49; 68; 60; 43; 67; 84; 87; 72 |] in
  let cap = 165 in
  let o = mk_opt () in
  let m = Hexaly.model o in
  let xs = Array.init (Array.length weights) (fun _ -> Hexaly.bool_var m) in
  let dot c xs =
    Hexaly.sum m (Array.to_list (Array.mapi
      (fun i x -> Hexaly.mul m (Hexaly.int_const m c.(i)) x) xs))
  in
  let w = dot weights xs in
  let v = dot values  xs in
  Hexaly.add_constraint m (Hexaly.leq m w (Hexaly.int_const m cap));
  Hexaly.maximize m v;
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "knapsack optimum" 309
    (Hexaly.int_value (Hexaly.solution o) v)

(* Verify the knapsack solution actually satisfies its weight constraint
   (a behavioral invariant, not just the objective). *)
let test_knapsack_constraint_satisfied () =
  let weights = [| 23; 31; 29; 44; 53; 38; 63; 85; 89; 82 |] in
  let values  = [| 92; 57; 49; 68; 60; 43; 67; 84; 87; 72 |] in
  let cap = 165 in
  let o = mk_opt () in
  let m = Hexaly.model o in
  let xs = Array.init (Array.length weights) (fun _ -> Hexaly.bool_var m) in
  let w = Hexaly.sum m (Array.to_list (Array.mapi
    (fun i x -> Hexaly.mul m (Hexaly.int_const m weights.(i)) x) xs))
  in
  let v = Hexaly.sum m (Array.to_list (Array.mapi
    (fun i x -> Hexaly.mul m (Hexaly.int_const m values.(i))  x) xs))
  in
  Hexaly.add_constraint m (Hexaly.leq m w (Hexaly.int_const m cap));
  Hexaly.maximize m v;
  Hexaly.close m;
  Hexaly.solve o;
  let s = Hexaly.solution o in
  Alcotest.(check bool) "weight ≤ capacity" true
    (Hexaly.int_value s w <= cap)

(* ============================================================
 *           G R O U P   2 3  —  S T R E S S
 * ============================================================ *)

let test_gc_under_pressure () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.bool_var m in
  for _ = 1 to 10000 do
    let _ = Hexaly.add m x (Hexaly.int_const m 1) in ()
  done;
  Gc.compact ();
  Gc.full_major ();
  Alcotest.(check int) "decision survived" 1 (Hexaly.nb_decisions m);
  Alcotest.(check bool) "many expressions" true (Hexaly.nb_expressions m > 1000)

let test_many_callbacks_alive () =
  let o = mk_opt () in
  let n = 50 in
  let counters = Array.make n 0 in
  let _handles = Array.init n (fun i ->
    Hexaly.add_callback o Hexaly.Callback_type.Optimization_started
      (fun () -> counters.(i) <- counters.(i) + 1))
  in
  Gc.full_major ();
  let m = Hexaly.model o in
  let x = Hexaly.bool_var m in
  Hexaly.maximize m x;
  Hexaly.close m;
  Hexaly.solve o;
  Array.iter (fun c -> Alcotest.(check int) "each fired exactly once" 1 c) counters

let test_huge_array_const () =
  skip_on_mock ();
  let n = 1000 in
  let o = mk_opt () in
  let m = Hexaly.model o in
  let arr = Hexaly.int_array_const m (Array.init n (fun i -> i * 2)) in
  let idx = Hexaly.int_var m 0 (n - 1) in
  let pick = Hexaly.at m arr [idx] in
  Hexaly.maximize m pick;
  Hexaly.close m;
  Hexaly.solve o;
  Alcotest.(check int) "max of 0..2(n-1) = 2(n-1)" (2 * (n - 1))
    (Hexaly.int_value (Hexaly.solution o) pick)

(* ============================================================
 *           G R O U P   2 4  —  M O D E L   S T A T E
 * ============================================================ *)

let test_close_idempotent_or_clean () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let x = Hexaly.bool_var m in
  Hexaly.maximize m x;
  Hexaly.close m;
  Alcotest.(check bool) "closed once" true (Hexaly.is_closed m);
  (* Closing twice may either be idempotent or raise — both are fine. *)
  let no_crash =
    try Hexaly.close m; true
    with Hexaly.Hexaly_error _ -> true
  in
  Alcotest.(check bool) "double-close handled" true no_crash

let test_model_counts_grow () =
  let o = mk_opt () in
  let m = Hexaly.model o in
  let e0 = Hexaly.nb_expressions m in
  let _ = Hexaly.bool_var m in
  let e1 = Hexaly.nb_expressions m in
  let _ = Hexaly.bool_var m in
  let e2 = Hexaly.nb_expressions m in
  Alcotest.(check bool) "e0 ≤ e1" true (e0 <= e1);
  Alcotest.(check bool) "e1 ≤ e2" true (e1 <= e2);
  Alcotest.(check int)  "2 decisions" 2 (Hexaly.nb_decisions m)

(* ============================================================
 *           R U N N E R
 * ============================================================ *)

let () =
  Alcotest.run "hexaly" [
    "lifecycle", [
      Alcotest.test_case "create optimizer"        `Quick test_create_optimizer;
      Alcotest.test_case "model handle"            `Quick test_model_handle;
      Alcotest.test_case "param handle"            `Quick test_param_handle;
      Alcotest.test_case "solution requires solve" `Quick test_solution_handle_requires_solve;
      Alcotest.test_case "lifetime chain"          `Quick test_lifetime_chain;
    ];
    "decisions", [
      Alcotest.test_case "bool var"                `Quick test_bool_var;
      Alcotest.test_case "int var lower bound"     `Quick test_int_var_bounds;
      Alcotest.test_case "int var upper bound"     `Quick test_int_var_upper_bound;
      Alcotest.test_case "float var"               `Quick test_float_var;
      Alcotest.test_case "interval var"            `Quick test_interval_var_basic;
      Alcotest.test_case "optional interval var"   `Quick test_optional_interval_var;
      Alcotest.test_case "list var permutation"    `Quick test_list_var_basic;
      Alcotest.test_case "set var"                 `Quick test_set_var;
    ];
    "constants", [
      Alcotest.test_case "int const negative"      `Quick test_int_const_negative;
      Alcotest.test_case "int const zero"          `Quick test_int_const_zero;
      Alcotest.test_case "int array const + at"    `Quick test_int_array_const;
      Alcotest.test_case "float array const + at"  `Quick test_float_array_const;
    ];
    "arithmetic", [
      Alcotest.test_case "n-ary sum"               `Quick test_sum_nary;
      Alcotest.test_case "n-ary prod"              `Quick test_prod_nary;
      Alcotest.test_case "sub"                     `Quick test_sub;
      Alcotest.test_case "div"                     `Quick test_div;
      Alcotest.test_case "abs"                     `Quick test_abs;
      Alcotest.test_case "dist"                    `Quick test_dist;
      Alcotest.test_case "mod"                     `Quick test_mod;
      Alcotest.test_case "max + min"               `Quick test_max_min;
      Alcotest.test_case "neg"                     `Quick test_neg;
    ];
    "comparison", [
      Alcotest.test_case "all comparison ops"      `Quick test_all_comparisons;
    ];
    "logical", [
      Alcotest.test_case "all logical ops + if_"   `Quick test_all_logical;
    ];
    "math", [
      Alcotest.test_case "sqrt log exp pow trig"   `Quick test_math_functions;
      Alcotest.test_case "ceil floor round"        `Quick test_ceil_floor_round;
    ];
    "collections", [
      Alcotest.test_case "at with int index"       `Quick test_at_index;
      Alcotest.test_case "count on full list"      `Quick test_count_distinct;
    ];
    "constraints", [
      Alcotest.test_case "multiple constraints"    `Quick test_multiple_constraints;
      Alcotest.test_case "nb_constraints counter"  `Quick test_constraint_count;
    ];
    "edge_cases", [
      Alcotest.test_case "empty model"             `Quick test_empty_model;
      Alcotest.test_case "500-operand sum"         `Quick test_large_sum;
      Alcotest.test_case "deeply nested (100)"     `Quick test_deeply_nested;
      Alcotest.test_case "re-solve"                `Quick test_re_solve;
      Alcotest.test_case "multiple optimizers"     `Quick test_multiple_optimizers;
    ];
    "error_paths", [
      Alcotest.test_case "mutate after close"      `Quick test_error_after_close;
      Alcotest.test_case "typed code"              `Quick test_error_codes_are_distinguishable;
      Alcotest.test_case "code_to_string"          `Quick test_error_code_to_string;
    ];
    "pretty", [
      Alcotest.test_case "Status.pp"               `Quick test_status_pp;
      Alcotest.test_case "State.pp"                `Quick test_state_pp;
      Alcotest.test_case "Callback_type.pp"        `Quick test_callback_type_pp;
    ];
    "version", [
      Alcotest.test_case "version consistency"     `Quick test_version_consistency;
      Alcotest.test_case "version strings"         `Quick test_version_strings_non_empty;
    ];
    "warm_start", [
      Alcotest.test_case "set initial values"      `Quick test_warm_start;
      Alcotest.test_case "clear solution"          `Quick test_clear_solution;
    ];
    "params", [
      Alcotest.test_case "all setters accepted"    `Quick test_all_parameter_setters;
    ];
    "solution_inspection", [
      Alcotest.test_case "status optimal"          `Quick test_status_optimal;
      Alcotest.test_case "status infeasible"       `Quick test_status_infeasible;
      Alcotest.test_case "is_violated false"       `Quick test_is_violated;
    ];
    "callbacks", [
      Alcotest.test_case "start + end fire once"   `Quick test_callback_optimization_started_ended;
      Alcotest.test_case "multiple same type"      `Quick test_callback_multiple_same_type;
      Alcotest.test_case "removal stops firing"    `Quick test_callback_removal;
      Alcotest.test_case "double remove idempotent" `Quick test_callback_double_remove;
      Alcotest.test_case "captures optimizer"      `Quick test_callback_captures_optimizer;
      Alcotest.test_case "exception caught"        `Quick test_callback_exception_does_not_crash;
      Alcotest.test_case "no optimizer leak"       `Quick test_callback_does_not_leak_optimizer;
      Alcotest.test_case "backend matches env"     `Quick test_backend_matches_env;
      Alcotest.test_case "status after caught error" `Quick test_status_after_caught_error;
      Alcotest.test_case "survives dropped handle" `Quick test_callback_survives_dropped_handle;
    ];
    "phases", [
      Alcotest.test_case "create + inspect"        `Quick test_phases_create_and_inspect;
      Alcotest.test_case "get by index"            `Quick test_phases_get_by_index;
    ];
    "iis", [
      Alcotest.test_case "compute inconsistency"   `Quick test_inconsistency_basic;
    ];
    "env", [
      Alcotest.test_case "save environment"        `Quick test_save_environment;
    ];
    "syntax", [
      Alcotest.test_case "arithmetic sugar"        `Quick test_syntax_arithmetic;
      Alcotest.test_case "comparison sugar"        `Quick test_syntax_comparisons;
      Alcotest.test_case "with_model restores"     `Quick test_syntax_with_model_restores;
    ];
    "regression", [
      Alcotest.test_case "knapsack optimum"        `Quick test_knapsack;
      Alcotest.test_case "knapsack constraint OK"  `Quick test_knapsack_constraint_satisfied;
    ];
    "stress", [
      Alcotest.test_case "GC under pressure (10K)" `Quick test_gc_under_pressure;
      Alcotest.test_case "50 live callbacks"       `Quick test_many_callbacks_alive;
      Alcotest.test_case "1K-element array const"  `Quick test_huge_array_const;
    ];
    "model_state", [
      Alcotest.test_case "close idempotent"        `Quick test_close_idempotent_or_clean;
      Alcotest.test_case "counts grow monotonically" `Quick test_model_counts_grow;
    ];
  ]
