(* Single-machine scheduling: N jobs with fixed durations share one machine,
 * no overlap, minimize makespan (latest completion time).
 *
 * Model: one interval variable per job + a [disjoint] constraint forbidding
 * overlap + [length] constraints pinning the durations + objective
 * minimize max(end(i) for i in jobs).
 *
 * For durations [3; 5; 2; 4; 1], total = 15, so optimal makespan = 15. *)

let durations = [| 3; 5; 2; 4; 1 |]

let () =
  let n = Array.length durations in
  let horizon = Array.fold_left (+) 0 durations in

  let opt = Hexaly.create () in
  Hexaly.set_verbosity (Hexaly.param opt) 0;
  let m = Hexaly.model opt in

  let jobs = Array.init n (fun _ -> Hexaly.interval_var m 0 horizon) in

  (* Each job's length is fixed. *)
  Array.iteri (fun i ji ->
    Hexaly.add_constraint m
      (Hexaly.eq m (Hexaly.length m ji) (Hexaly.int_const m durations.(i)))
  ) jobs;

  (* Single-machine: no two jobs overlap. Hexaly's [disjoint] applies to
     collections (lists/sets), not intervals — we use pairwise constraints
     end(i) <= start(j) OR end(j) <= start(i) for every i < j. *)
  for i = 0 to n - 2 do
    for j = i + 1 to n - 1 do
      let ei = Hexaly.end_ m jobs.(i) in
      let sj = Hexaly.start m jobs.(j) in
      let ej = Hexaly.end_ m jobs.(j) in
      let si = Hexaly.start m jobs.(i) in
      Hexaly.add_constraint m
        (Hexaly.or_ m [Hexaly.leq m ei sj; Hexaly.leq m ej si])
    done
  done;

  (* Makespan = max end time. *)
  let makespan = Hexaly.max m (Array.to_list
    (Array.map (Hexaly.end_ m) jobs)) in
  Hexaly.minimize m makespan;

  Hexaly.close m;
  Hexaly.set_time_limit (Hexaly.param opt) 5;
  Hexaly.solve opt;

  let sol = Hexaly.solution opt in
  Printf.printf "status   : %s\n" (Hexaly.Status.to_string (Hexaly.status sol));
  Printf.printf "makespan : %d (lower bound = %d)\n"
    (Hexaly.int_value sol makespan) horizon;
  Printf.printf "schedule (sorted by start):\n";
  let intervals = Array.mapi (fun i j ->
    let (s, e) = Hexaly.interval_value sol j in
    (i, s, e)
  ) jobs in
  Array.sort (fun (_, s1, _) (_, s2, _) -> compare s1 s2) intervals;
  Array.iter (fun (i, s, e) ->
    Printf.printf "  job %d  [%2d, %2d)  duration %d\n"
      i s e durations.(i)
  ) intervals;
  Printf.printf "iters    : %Ld\n" (Hexaly.nb_iterations opt)
