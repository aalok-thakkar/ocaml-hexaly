(** OCaml bindings for the Hexaly Optimizer (formerly LocalSolver).

    Hexaly is a commercial mathematical optimization solver supporting
    mixed-integer programming, constraint programming, and the specialized
    decision variables (interval, list, set) that distinguish it from
    classical MIP solvers.

    {1 Quick start}

    {[
      let opt = Hexaly.create () in
      Hexaly.set_verbosity (Hexaly.param opt) 0;
      let m   = Hexaly.model opt in
      let xs  = Array.init n (fun _ -> Hexaly.bool_var m) in
      let value = Hexaly.sum m (Array.to_list (Array.mapi
        (fun i x -> Hexaly.mul m (Hexaly.int_const m values.(i)) x) xs))
      in
      Hexaly.maximize m value;
      Hexaly.close m;
      Hexaly.solve opt;
      assert (Hexaly.status (Hexaly.solution opt) = Hexaly.Status.Optimal)
    ]}

    {1 Lifetimes and the GC}

    The user-facing types ([model], [param], [solution], [expr],
    [Inconsistency.t], [callback]) are records that hold their parent so
    OCaml's reachability analysis enforces the lifetime chain — drop the
    optimizer and every descendant is invalidated; hold any descendant and
    the optimizer survives. This costs one extra word per handle and
    eliminates the most common use-after-free in C bindings.

    {1 Threading}

    [solve] releases the OCaml runtime lock for its duration, so other OCaml
    threads can run and so callbacks invoked from Hexaly worker threads can
    safely re-enter OCaml. Every other Hexaly call is short and holds the
    lock. *)

(** {1 Types} *)

type optimizer
type model
type expr
type solution
type param

(** {1 Errors} *)

module Error : sig
  (** Mirror of Hexaly's [HxErrorCode]. *)
  type code =
    | Api       (** Programmer error against the API contract. *)
    | File      (** File I/O failure. *)
    | Model     (** Modeling error (invalid expression structure, post-close mutation, ...). *)
    | Callback  (** Failure inside a registered callback. *)
    | License   (** License missing, expired, or invalid. *)
    | Solver    (** Solver runtime failure. *)
    | Internal  (** Internal Hexaly assertion or unexpected exception. *)
    | Modeler   (** Hexaly Modeler (HXM) error. *)
    | Cloud     (** Hexaly Cloud connectivity. *)

  val code_to_string : code -> string

  val pp_code : Format.formatter -> code -> unit
end

(** Every Hexaly call site can raise [Hexaly_error (code, msg)]. *)
exception Hexaly_error of Error.code * string

(** {1 Solver state, solution status, callback types} *)

module State : sig
  type t = Modeling | Running | Paused | Stopped
  val to_string : t -> string
  val pp : Format.formatter -> t -> unit
end

module Status : sig
  type t = Inconsistent | Infeasible | Feasible | Optimal
  val to_string : t -> string
  val pp : Format.formatter -> t -> unit
end

module Callback_type : sig
  (** Mirror of Hexaly's [HxCallbackType]. Use these as the event filter
      for {!add_callback}. *)
  type t =
    | Phase_started
    | Phase_ended
    | Display
    | Time_ticked
    | Iteration_ticked
    | Optimization_started
    | Optimization_ended

  val to_string : t -> string
  val pp : Format.formatter -> t -> unit
end

(** Operator tags mirroring [HxOperator]. Used by {!create_expression} for
    operators without a named helper. *)
module Op : sig
  type t =
    | Sum | Sub | Prod | Max | Min
    | Abs | Dist | Div | Mod
    | Eq  | Neq  | Geq  | Leq | Gt | Lt
    | If  | Not  | And  | Or  | Xor
    | Ceil | Floor | Round | Sqrt | Log | Exp | Pow | Cos | Sin | Tan
    | Array | At | Scalar
    | Count | IndexOf | Contains | Partition | Disjoint | Distinct
    | Find | Sort | Intersection | Union | Hull
    | Start | End_ | Length | Presence
end

(** {1 Hexaly version and license configuration} *)

module Version : sig
  val major : unit -> int
  val minor : unit -> int
  val code  : unit -> int
  val build_date : unit -> int

  val string    : unit -> string
  val platform  : unit -> string
  val info      : unit -> string
  val copyright : unit -> string

  (** Current license path. Empty string if not set. *)
  val license_path : unit -> string

  (** Override the license file path (an alternative to setting [HX_LICENSE_PATH]). *)
  val set_license_path : string -> unit

  (** Set the license content directly (bypasses the file lookup). *)
  val set_license_content : string -> unit
end

(** {1 Lifecycle} *)

(** Acquire a license token and create a fresh optimizer.
    @raise Hexaly_error if no license is available. *)
val create : unit -> optimizer

val model    : optimizer -> model
val param    : optimizer -> param
val solution : optimizer -> solution

(** Run the solver. Blocks the calling OCaml thread; releases the runtime
    lock so other OCaml threads can run.
    @raise Hexaly_error on solver failure. *)
val solve : optimizer -> unit

val stop  : optimizer -> unit

(** {2 Introspection} *)

val state         : optimizer -> State.t
val running_time  : optimizer -> int
val nb_iterations : optimizer -> int64

(** {2 Environment save/load} *)

(** Save the model as a Hexaly Modeler script. The destination file's
    suffix selects the format: [.hxm] (Hexaly Modeler, recommended) or
    [.lsp] (legacy LocalSolver script). The result is loadable by the
    [hexaly] CLI and HexalyModeler.

    Note: as of Hexaly 14.5, the saved file is NOT a complete environment
    snapshot — solver state and best solution are not round-tripped
    through {!load_environment}. For sharing/debugging models, this is the
    canonical export path.

    @raise Hexaly_error if the file cannot be written or the suffix is
    unrecognized. *)
val save_environment : optimizer -> string -> unit

(** Load a Hexaly snapshot file produced by Hexaly Studio or a future
    version of {!save_environment}. As of Hexaly 14.5 the formats
    accepted here are NOT the same as those produced by
    {!save_environment}; do not assume round-trip.
    @raise Hexaly_error if the file format is not recognized. *)
val load_environment : optimizer -> string -> unit

(** {1 Multi-objective phases}

    Hexaly supports lexicographic multi-objective optimization. The pattern:

    {[
      Hexaly.minimize m cost;        (* objective 0 *)
      Hexaly.minimize m makespan;    (* objective 1 *)
      Hexaly.close m;
      let p0 = Hexaly.Phase.create opt in
      Hexaly.Phase.set_optimized_objective p0 0;
      Hexaly.Phase.set_time_limit p0 30;
      let p1 = Hexaly.Phase.create opt in
      Hexaly.Phase.set_optimized_objective p1 1;
      Hexaly.Phase.set_time_limit p1 30;
      Hexaly.solve opt
    ]}

    Hexaly runs the phases in order: it optimizes objective 0 to convergence
    (or its time/iteration limit), then optimizes objective 1 while
    constraining objective 0 to its best value. *)

module Phase : sig
  type t

  (** Create and append a new phase to the optimizer. The phase's index in
      declaration order matters for execution sequence. *)
  val create : optimizer -> t

  (** Retrieve an existing phase by its 0-based index. *)
  val get : optimizer -> int -> t

  val nb_phases : optimizer -> int

  val set_time_limit          : t -> int   -> unit
  val time_limit              : t -> int
  val set_iteration_limit     : t -> int64 -> unit
  val iteration_limit         : t -> int64

  (** Which objective (0-based index in declaration order) this phase
      optimizes. *)
  val set_optimized_objective : t -> int   -> unit
  val optimized_objective     : t -> int

  val set_enabled : t -> bool -> unit
  val is_enabled  : t -> bool

  val to_string : t -> string
  val pp : Format.formatter -> t -> unit
end

(** {1 Inconsistency analysis (IIS)} *)

module Inconsistency : sig
  type t

  (** Number of constraints (or objective bounds) in the inconsistency set. *)
  val nb_causes : t -> int

  (** The [i]-th cause as an [expr]. *)
  val cause : t -> int -> expr

  val to_string : t -> string

  val pp : Format.formatter -> t -> unit
end

(** Run Hexaly's inconsistency analysis to identify a minimal set of
    constraints whose conflict makes the model infeasible. Only meaningful
    after a solve that reported [Infeasible] or [Inconsistent]. *)
val compute_inconsistency : optimizer -> Inconsistency.t

(** {1 Callbacks} *)

(** Opaque handle to a registered callback. The registration persists
    for the lifetime of the program (or until {!remove_callback} is
    called) regardless of whether the user retains this handle —
    dropping the handle does NOT silently stop the callback firing. *)
type callback

(** Register an OCaml closure to be invoked on every event of the given type
    during {!solve}. The closure receives [unit]; capture the [optimizer]
    in its closure if you need to inspect state.

    Exceptions raised by the closure are caught and printed to [stderr] —
    they cannot propagate into Hexaly's C++ without corrupting state.

    Example: print progress every 5 seconds during a long solve.
    {[
      let last = ref 0.0 in
      let _cb = Hexaly.add_callback opt Hexaly.Callback_type.Time_ticked
        (fun () ->
          let now = Unix.gettimeofday () in
          if now -. !last >= 5.0 then begin
            Printf.printf "[%.0fs] iter=%Ld\n%!"
              (now -. start) (Hexaly.nb_iterations opt);
            last := now
          end)
      in
      Hexaly.solve opt
    ]} *)
val add_callback : optimizer -> Callback_type.t -> (unit -> unit) -> callback

(** Remove a previously registered callback. Returns [true] if it was found
    and removed. Safe to call multiple times. *)
val remove_callback : callback -> bool

(** {1 Decision variables} *)

val bool_var               : model -> expr
val int_var                : model -> int -> int -> expr
val float_var              : model -> float -> float -> expr

(** [interval_var m min_start max_end] creates a half-open interval
    decision: start ≥ min_start, end ≤ max_end. Read via
    {!interval_value}. *)
val interval_var           : model -> int -> int -> expr

(** Like {!interval_var} but the interval can be absent (length 0). *)
val optional_interval_var  : model -> int -> int -> expr

(** [list_var m n] creates a permutation decision over [\{0, ..., n-1\}].
    Read via {!collection_value}. *)
val list_var : model -> int -> expr

(** [set_var m n] creates a subset decision over [\{0, ..., n-1\}].
    Read via {!collection_value}. *)
val set_var  : model -> int -> expr

(** {1 Constants} *)

val int_const         : model -> int -> expr
val float_const       : model -> float -> expr
val int_array_const   : model -> int array   -> expr
val float_array_const : model -> float array -> expr

(** {1 Generic expression builder} *)

val create_expression :
  model -> Op.t ->
  ?operands:expr array ->
  ?ints:int array ->
  ?floats:float array ->
  unit -> expr

(** {1 Arithmetic} *)
val sum  : model -> expr list -> expr
val prod : model -> expr list -> expr
val add  : model -> expr -> expr -> expr
val sub  : model -> expr -> expr -> expr
val mul  : model -> expr -> expr -> expr
val div  : model -> expr -> expr -> expr
val neg  : model -> expr -> expr
val abs  : model -> expr -> expr
val dist : model -> expr -> expr -> expr
val mod_ : model -> expr -> expr -> expr
val max  : model -> expr list -> expr
val min  : model -> expr list -> expr

(** {2 Math functions} *)
val sqrt  : model -> expr -> expr
val log   : model -> expr -> expr
val exp   : model -> expr -> expr
val pow   : model -> expr -> expr -> expr
val cos   : model -> expr -> expr
val sin   : model -> expr -> expr
val tan   : model -> expr -> expr
val ceil  : model -> expr -> expr
val floor : model -> expr -> expr
val round : model -> expr -> expr

(** {1 Comparison (returns boolean expression)} *)
val eq  : model -> expr -> expr -> expr
val neq : model -> expr -> expr -> expr
val lt  : model -> expr -> expr -> expr
val leq : model -> expr -> expr -> expr
val gt  : model -> expr -> expr -> expr
val geq : model -> expr -> expr -> expr

(** {1 Logical} *)
val and_ : model -> expr list -> expr
val or_  : model -> expr list -> expr
val xor_ : model -> expr list -> expr
val not_ : model -> expr -> expr
val if_  : model -> expr -> expr -> expr -> expr

(** {1 Array / collection operators} *)
val array    : model -> expr list -> expr
val at       : model -> expr -> expr list -> expr
val scalar   : model -> expr -> expr -> expr
val count    : model -> expr -> expr
val index_of : model -> expr -> expr -> expr
val contains : model -> expr -> expr -> expr
val partition : model -> expr list -> expr
val disjoint  : model -> expr list -> expr
val distinct  : model -> expr -> expr
val find      : model -> expr -> expr -> expr
val sort      : model -> expr -> expr
val intersection : model -> expr list -> expr
val union_       : model -> expr list -> expr
val hull         : model -> expr list -> expr

(** {1 Interval operators} *)
val start     : model -> expr -> expr
val end_      : model -> expr -> expr
val length    : model -> expr -> expr
val presence  : model -> expr -> expr

(** {1 Constraints, objectives, model state} *)
val add_constraint : model -> expr -> unit
val minimize       : model -> expr -> unit
val maximize       : model -> expr -> unit
val close          : model -> unit
val is_closed      : model -> bool

(** {1 Inspection} *)
val nb_expressions : model -> int
val nb_constraints : model -> int
val nb_objectives  : model -> int
val nb_decisions   : model -> int

(** {1 Solution access} *)

val int_value      : solution -> expr -> int
val float_value    : solution -> expr -> float

(** Read an interval decision as [(start, end)]. End is exclusive
    (count = end - start). *)
val interval_value : solution -> expr -> int * int

(** Read a list-var or set-var as an array of element indices in [0..n-1]. *)
val collection_value : solution -> expr -> int array

(** [is_violated sol expr] returns [true] if [expr] is a violated
    constraint in this solution. *)
val is_violated  : solution -> expr -> bool

(** [is_undefined sol expr] returns [true] if [expr] has no defined value
    in this solution (e.g. an optional interval that was absent). *)
val is_undefined : solution -> expr -> bool

val status : solution -> Status.t

(** {2 Warm start (initial solution)} *)

(** Set an initial value for a decision before [solve]. Hexaly will use it
    as a starting point. *)
val set_int_value      : solution -> expr -> int -> unit
val set_float_value    : solution -> expr -> float -> unit

(** [set_interval_value sol expr ~start ~end_] hints an interval's
    [(start, end)] for the next solve. *)
val set_interval_value : solution -> expr -> start:int -> end_:int -> unit

(** Discard all warm-start hints. *)
val clear_solution     : solution -> unit

(** {1 Solver parameters} *)

val set_time_limit              : param -> int   -> unit
val set_iteration_limit         : param -> int64 -> unit
val set_seed                    : param -> int   -> unit
val set_nb_threads              : param -> int   -> unit
val set_verbosity               : param -> int   -> unit

(** Hexaly warning level (0..3). Higher = more output. *)
val set_warning_level           : param -> int   -> unit

(** Seconds between progress-line displays in the console log. *)
val set_time_between_displays   : param -> int   -> unit

(** Seconds between [Time_ticked] callback firings. *)
val set_time_between_ticks      : param -> int   -> unit

(** Iterations between [Iteration_ticked] callback firings. *)
val set_iteration_between_ticks : param -> int64 -> unit

(** Mirror Hexaly's solver log to a file. Empty string disables. *)
val set_log_file                : param -> string -> unit

(** Set an objective-specific integer threshold: solver stops when this
    objective reaches the threshold. Index is the objective's position in
    declaration order. *)
val set_int_objective_threshold    : param -> int -> int   -> unit
val set_double_objective_threshold : param -> int -> float -> unit

(** {2 Advanced parameters}

    Hexaly exposes many tuning knobs by attribute name (see the Hexaly
    documentation for the catalog). Unknown keys are silently ignored. *)
val set_advanced_int    : param -> string -> int    -> unit
val set_advanced_double : param -> string -> float  -> unit
val set_advanced_string : param -> string -> string -> unit

(** {1 Operator syntax sugar} *)

module Syntax : sig
  (** [with_model m f] sets [m] as the implicit model for the operators
      below for the duration of [f]. Save the result of [f] (probably
      a value or a side-effect) — do not let expressions escape outside
      [with_model] without binding them first. *)
  val with_model : model -> (unit -> 'a) -> 'a

  val ( +! )  : expr -> expr -> expr
  val ( -! )  : expr -> expr -> expr
  val ( *! )  : expr -> expr -> expr
  val ( /! )  : expr -> expr -> expr
  val ( =! )  : expr -> expr -> expr
  val ( <>! ) : expr -> expr -> expr
  val ( <! )  : expr -> expr -> expr
  val ( <=! ) : expr -> expr -> expr
  val ( >! )  : expr -> expr -> expr
  val ( >=! ) : expr -> expr -> expr

  (** Lift an OCaml int to a constant expression in the implicit model. *)
  val ( !! ) : int -> expr
end
