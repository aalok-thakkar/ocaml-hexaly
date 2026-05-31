(* 0/1 knapsack: pick a subset of items to maximize value subject to a weight cap.
 *
 * Exercises every layer of the binding:
 *   - decision-variable creation (bool_var)
 *   - batched sum over many operands (the scalar product)
 *   - a single constraint, a single maximize objective
 *   - solve + solution extraction
 *
 * Run after building:  dune exec examples/knapsack.exe *)

let weights = [| 23; 31; 29; 44; 53; 38; 63; 85; 89; 82 |]
let values  = [| 92; 57; 49; 68; 60; 43; 67; 84; 87; 72 |]
let capacity = 165
(* Reference optimal value for this instance: 309 (items 1,2,3,4,6 in 1-indexed). *)

let scalar_product m coeffs xs =
  (* sum_i (coeff_i * x_i) via one create_expression per term + one Sum. *)
  let terms =
    Array.to_list (Array.mapi (fun i x ->
      Hexaly.mul m (Hexaly.int_const m coeffs.(i)) x
    ) xs)
  in
  Hexaly.sum m terms

let () =
  let opt = Hexaly.create () in
  let m   = Hexaly.model opt in
  let n   = Array.length weights in

  let xs = Array.init n (fun _ -> Hexaly.bool_var m) in

  let total_weight = scalar_product m weights xs in
  let total_value  = scalar_product m values  xs in

  Hexaly.add_constraint m (Hexaly.leq m total_weight (Hexaly.int_const m capacity));
  Hexaly.maximize m total_value;
  Hexaly.close m;

  Hexaly.set_time_limit (Hexaly.param opt) 10;
  Hexaly.solve opt;

  let sol = Hexaly.solution opt in
  Printf.printf "status   : %s\n" (Hexaly.Status.to_string (Hexaly.status sol));
  Printf.printf "value    : %d\n" (Hexaly.int_value sol total_value);
  Printf.printf "weight   : %d / %d\n" (Hexaly.int_value sol total_weight) capacity;
  Printf.printf "picked   :";
  Array.iteri (fun i x ->
    if Hexaly.int_value sol x = 1 then Printf.printf " %d" i
  ) xs;
  print_newline ()
