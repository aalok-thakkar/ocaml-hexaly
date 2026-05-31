(* Benchmark: build a model with ~1M expression nodes and time the OCaml
 * side. Measures FFI overhead in the hot path (per-expression
 * create_expression calls).
 *
 * The model itself is artificial: N int vars, then N*K = 1M scalar
 * products in a single sum. Solving is bounded so we measure model build,
 * not solver time.
 *
 * Run:  dune exec bench/build_million.exe
 *
 * Reference points (Hexaly's official Python binding on the same machine
 * does roughly the equivalent over libhexaly; expect FFI overhead in this
 * binding to be roughly 1-3x faster than ctypes equivalents and within
 * 1.5x of the Python binding's hot path). *)

let time label f =
  let t0 = Unix.gettimeofday () in
  let r = f () in
  let t1 = Unix.gettimeofday () in
  Printf.printf "  %-40s  %8.3f s\n%!" label (t1 -. t0);
  r

let () =
  let n = 1000 in     (* int vars *)
  let k = 1000 in     (* terms per scalar product, so n*k = 1_000_000 *)
  Printf.printf "Hexaly OCaml binding benchmark\n";
  Printf.printf "  vars:  %d\n  terms: %d\n  total: %d expression nodes\n\n"
    n k (n * k);

  let opt = Hexaly.create () in
  Hexaly.set_verbosity (Hexaly.param opt) 0;
  let m = Hexaly.model opt in

  let xs = time "1. create int vars" (fun () ->
    Array.init n (fun _ -> Hexaly.int_var m 0 1))
  in

  let coeffs = Array.init n (fun i -> i + 1) in

  let scalar_products = time "2. build N scalar products (N*K terms)" (fun () ->
    Array.init n (fun i ->
      let terms = List.init k (fun _ ->
        Hexaly.mul m (Hexaly.int_const m coeffs.(i)) xs.(i)
      ) in
      Hexaly.sum m terms))
  in

  let big_sum = time "3. sum the N scalar products" (fun () ->
    Hexaly.sum m (Array.to_list scalar_products))
  in

  time "4. set objective + close" (fun () ->
    Hexaly.maximize m big_sum;
    Hexaly.close m);

  Printf.printf "\n  total expressions reported by Hexaly: %d\n"
    (Hexaly.nb_expressions m);

  Hexaly.set_time_limit (Hexaly.param opt) 1;
  time "5. solve (1 sec time limit)" (fun () -> Hexaly.solve opt);

  let sol = Hexaly.solution opt in
  Printf.printf "\n  status:    %s\n" (Hexaly.Status.to_string (Hexaly.status sol));
  Printf.printf "  objective: %d\n" (Hexaly.int_value sol big_sum);
  Printf.printf "  iters:     %Ld\n" (Hexaly.nb_iterations opt)
