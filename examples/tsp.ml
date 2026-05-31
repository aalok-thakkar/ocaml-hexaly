(* Symmetric TSP with N=5 cities, solved via Hexaly's list variable.
 *
 * The list variable [p] is a permutation of {0..n-1}. We build a 2D array
 * of distances [d_arr] and express the tour cost as
 *     sum_k  d[ p[k], p[(k+1) mod n] ]
 * unrolled over k. Hexaly's native TSP idiom uses a lambda over a range;
 * we don't bind lambdas yet, so we unroll. For larger n use the real
 * Hexaly Python/C++ TSP idiom or wait for lambda support.
 *
 * Run: dune exec examples/tsp.exe *)

let n = 5
let distances = [|
  [| 0;  8;  4;  9;  3 |];
  [| 8;  0;  6;  7;  5 |];
  [| 4;  6;  0;  5;  2 |];
  [| 9;  7;  5;  0;  6 |];
  [| 3;  5;  2;  6;  0 |];
|]
(* For this instance, optimal tour visits in order 0-4-2-1-3-0 with
   cost 3 + 2 + 6 + 7 + 9 = 27. *)

let () =
  let opt = Hexaly.create () in
  Hexaly.set_verbosity (Hexaly.param opt) 0;
  let m = Hexaly.model opt in

  (* Permutation variable: p is a list of length n covering {0..n-1}. *)
  let p = Hexaly.list_var m n in

  (* Constraint: p must contain all n elements. *)
  Hexaly.add_constraint m
    (Hexaly.eq m (Hexaly.count m p) (Hexaly.int_const m n));

  (* Build the 2D distance matrix as an array of rows. *)
  let rows = Array.map (Hexaly.int_array_const m) distances in
  let d2 = Hexaly.array m (Array.to_list rows) in

  (* Tour cost: sum over k of d[p[k], p[(k+1) mod n]]. *)
  let leg k =
    let pk  = Hexaly.at m p [Hexaly.int_const m k] in
    let pk1 = Hexaly.at m p [Hexaly.int_const m ((k + 1) mod n)] in
    Hexaly.at m d2 [pk; pk1]
  in
  let cost = Hexaly.sum m (List.init n leg) in

  Hexaly.minimize m cost;
  Hexaly.close m;
  Hexaly.set_time_limit (Hexaly.param opt) 5;
  Hexaly.solve opt;

  let sol = Hexaly.solution opt in
  let perm = Hexaly.collection_value sol p in
  Printf.printf "status : %s\n" (Hexaly.Status.to_string (Hexaly.status sol));
  Printf.printf "cost   : %d\n" (Hexaly.int_value sol cost);
  Printf.printf "route  :";
  Array.iter (fun c -> Printf.printf " %d" c) perm;
  Printf.printf " -> %d\n" perm.(0);
  Printf.printf "iters  : %Ld\n" (Hexaly.nb_iterations opt)
