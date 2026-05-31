(* Multi-objective assignment example using HxPhase.
 *
 * Assign N=6 tasks to M=2 workers. Each (worker, task) pair has a cost.
 * Two objectives:
 *   1. Primary:   minimize total cost.
 *   2. Secondary: balance the load — minimize the maximum number of tasks
 *      assigned to any single worker.
 *
 * Hexaly's lexicographic phases run them in order: first find the
 * minimum-cost solution; then, *holding cost at its minimum*, balance the
 * load. This is the standard "lex-min" multi-objective semantics.
 *
 * Run: dune exec examples/multi_objective.exe *)

let n = 6   (* tasks *)
let m = 2   (* workers *)
let cost = [|
  (* worker 0 *) [| 4; 9; 2; 7; 1; 5 |];
  (* worker 1 *) [| 6; 3; 8; 4; 5; 2 |];
|]

let () =
  let opt = Hexaly.create () in
  Hexaly.set_verbosity (Hexaly.param opt) 0;
  let mdl = Hexaly.model opt in

  (* Decision: x.(i).(j) = 1 iff worker i handles task j *)
  let x = Array.init m (fun _ ->
            Array.init n (fun _ -> Hexaly.bool_var mdl))
  in

  (* Each task assigned to exactly one worker *)
  for j = 0 to n - 1 do
    let col = List.init m (fun i -> x.(i).(j)) in
    Hexaly.add_constraint mdl
      (Hexaly.eq mdl (Hexaly.sum mdl col) (Hexaly.int_const mdl 1))
  done;

  (* Objective 1: total cost *)
  let total_cost =
    Hexaly.sum mdl
      (List.concat_map (fun i ->
         List.init n (fun j ->
           Hexaly.mul mdl (Hexaly.int_const mdl cost.(i).(j)) x.(i).(j)))
        (List.init m Fun.id))
  in
  Hexaly.minimize mdl total_cost;

  (* Objective 2: max load across workers. Build the per-worker load
     expressions BEFORE closing the model — they're needed both for the
     objective and for solution readout afterwards. *)
  let loads = Array.init m (fun i -> Hexaly.sum mdl (Array.to_list x.(i))) in
  let max_load = Hexaly.max mdl (Array.to_list loads) in
  Hexaly.minimize mdl max_load;

  Hexaly.close mdl;

  (* Set up two phases: phase 0 minimizes objective 0 (cost), phase 1
     minimizes objective 1 (max_load) subject to objective 0's optimum. *)
  let p0 = Hexaly.Phase.create opt in
  Hexaly.Phase.set_optimized_objective p0 0;
  Hexaly.Phase.set_time_limit p0 5;

  let p1 = Hexaly.Phase.create opt in
  Hexaly.Phase.set_optimized_objective p1 1;
  Hexaly.Phase.set_time_limit p1 5;

  Printf.printf "phases declared: %d\n" (Hexaly.Phase.nb_phases opt);

  Hexaly.solve opt;

  let sol = Hexaly.solution opt in
  Printf.printf "\nstatus      : %s\n" (Hexaly.Status.to_string (Hexaly.status sol));
  Printf.printf "total cost  : %d\n" (Hexaly.int_value sol total_cost);
  Printf.printf "max load    : %d\n" (Hexaly.int_value sol max_load);
  Printf.printf "\nassignment:\n";
  for j = 0 to n - 1 do
    let assigned =
      let rec find i =
        if i = m then -1
        else if Hexaly.int_value sol x.(i).(j) = 1 then i
        else find (i + 1)
      in find 0
    in
    Printf.printf "  task %d -> worker %d (cost %d)\n"
      j assigned cost.(assigned).(j)
  done;
  Printf.printf "\nloads:\n";
  for i = 0 to m - 1 do
    Printf.printf "  worker %d : %d tasks\n" i (Hexaly.int_value sol loads.(i))
  done
