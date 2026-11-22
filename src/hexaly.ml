(* Public OCaml interface — see hexaly.mli for docs.
 *
 * Lifetime invariant: every derived handle is wrapped in a record carrying
 * its parent. The OCaml reachability analysis enforces the lifetime chain. *)

(* Raw FFI handle types, never exposed to the user. *)
type _opt_h
type _model_h
type _param_h
type _solution_h
type _expr_h
type _iis_h
type _cb_h
type _phs_h

(* The optimizer owns its callbacks. The cycle optimizer -> callback ->
   optimizer is ordinary OCaml data, so the GC can collect both once the
   user drops them. C holds a callback's closure as a GC root only while
   [solve] runs. *)
type optimizer = {
  _oh : _opt_h;
  mutable _cbs : callback list;
  mutable _solving : bool;
}
and callback = { _ch : _cb_h; _co : optimizer; _closure : unit -> unit }

type model    = { _mh : _model_h;    _mo : optimizer }
type param    = { _ph : _param_h;    _po : optimizer }
type solution = { _sh : _solution_h; _so : optimizer }
type expr     = { _eh : _expr_h;     _em : model }

(* ---------- Errors ---------- *)
module Error = struct
  type code =
    | Api | File | Model | Callback | License | Solver | Internal | Modeler | Cloud

  (* Suppress unused-value warning by exporting _of_int as part of the
     conversion table the C stubs implicitly rely on (via integer match). *)
  let _of_int = function
    | 0 -> Api | 1 -> File | 2 -> Model | 3 -> Callback | 4 -> License
    | 5 -> Solver | 6 -> Internal | 7 -> Modeler | 8 -> Cloud
    | n -> failwith (Printf.sprintf "Hexaly.Error: unknown code %d" n)

  let code_to_string = function
    | Api -> "Api"          | File -> "File"     | Model -> "Model"
    | Callback -> "Callback" | License -> "License" | Solver -> "Solver"
    | Internal -> "Internal" | Modeler -> "Modeler" | Cloud -> "Cloud"

  let pp ppf c = Format.pp_print_string ppf (code_to_string c)
  let pp_code = pp
end

exception Hexaly_error of Error.code * string

let () =
  (* Register the constructor so C stubs can raise it via
     caml_raise_with_args. The argument is a dummy — the C side
     constructs fresh argument values for each raise. *)
  Callback.register_exception "Hexaly.Hexaly_error"
    (Hexaly_error (Error.Internal, ""))

(* ---------- State / Status / Callback type ---------- *)
module State = struct
  type t = Modeling | Running | Paused | Stopped
  let of_int = function
    | 0 -> Modeling | 1 -> Running | 2 -> Paused | 3 -> Stopped
    | n -> failwith (Printf.sprintf "Hexaly.State: unknown tag %d" n)
  let to_string = function
    | Modeling -> "Modeling" | Running -> "Running"
    | Paused -> "Paused"     | Stopped -> "Stopped"
  let pp ppf s = Format.pp_print_string ppf (to_string s)
end

module Status = struct
  type t = Inconsistent | Infeasible | Feasible | Optimal
  let of_int = function
    | 0 -> Inconsistent | 1 -> Infeasible | 2 -> Feasible | 3 -> Optimal
    | n -> failwith (Printf.sprintf "Hexaly.Status: unknown tag %d" n)
  let to_string = function
    | Inconsistent -> "Inconsistent" | Infeasible -> "Infeasible"
    | Feasible -> "Feasible"          | Optimal -> "Optimal"
  let pp ppf s = Format.pp_print_string ppf (to_string s)
end

module Callback_type = struct
  type t =
    | Phase_started | Phase_ended | Display
    | Time_ticked | Iteration_ticked
    | Optimization_started | Optimization_ended

  let to_int = function
    | Phase_started -> 0 | Phase_ended -> 1 | Display -> 2
    | Time_ticked -> 3 | Iteration_ticked -> 4
    | Optimization_started -> 5 | Optimization_ended -> 6

  let to_string = function
    | Phase_started -> "Phase_started" | Phase_ended -> "Phase_ended"
    | Display -> "Display"
    | Time_ticked -> "Time_ticked" | Iteration_ticked -> "Iteration_ticked"
    | Optimization_started -> "Optimization_started"
    | Optimization_ended -> "Optimization_ended"

  let pp ppf c = Format.pp_print_string ppf (to_string c)
end

(* ---------- Op ----------
 * Tag integers match HxOperator declaration order. Verified at compile
 * time by static_asserts in hexaly_shim_real.cpp. *)
module Op = struct
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

  let to_int = function
    | Sum -> 3  | Sub -> 4  | Prod -> 5 | Max -> 6 | Min -> 7
    | Eq -> 8   | Neq -> 9  | Geq -> 10 | Leq -> 11 | Gt -> 12 | Lt -> 13
    | If -> 14  | Not -> 15 | And -> 16 | Or -> 17 | Xor -> 18
    | Abs -> 19 | Dist -> 20 | Div -> 21 | Mod -> 22
    | Array -> 23 | At -> 24 | Scalar -> 25
    | Ceil -> 26 | Floor -> 27 | Round -> 28 | Sqrt -> 29 | Log -> 30
    | Exp -> 31  | Pow -> 32  | Cos -> 33   | Sin -> 34   | Tan -> 35
    | Count -> 39 | IndexOf -> 40 | Partition -> 41 | Disjoint -> 42
    | Contains -> 48
    | Find -> 52 | Sort -> 53
    | Distinct -> 58
    | Intersection -> 59 | Hull -> 60 | Union -> 63
    | Start -> 55 | End_ -> 56 | Length -> 57 | Presence -> 65
end

(* ---------- Version ---------- *)
module Version = struct
  external major          : unit -> int    = "caml_hxs_version_major"
  external minor          : unit -> int    = "caml_hxs_version_minor"
  external code           : unit -> int    = "caml_hxs_version_code"
  external build_date     : unit -> int    = "caml_hxs_version_build_date"
  external string         : unit -> string = "caml_hxs_version_string"
  external platform       : unit -> string = "caml_hxs_version_platform"
  external info           : unit -> string = "caml_hxs_version_info"
  external copyright      : unit -> string = "caml_hxs_version_copyright"
  external license_path   : unit -> string = "caml_hxs_version_license_path"
  external set_license_path    : string -> unit = "caml_hxs_version_set_license_path"
  external set_license_content : string -> unit = "caml_hxs_version_set_license_content"
end

(* ---------- External primitives ---------- *)
external optimizer_new          : unit -> _opt_h        = "caml_hxs_optimizer_new"
external optimizer_get_model    : _opt_h -> _model_h    = "caml_hxs_optimizer_get_model"
external optimizer_get_param    : _opt_h -> _param_h    = "caml_hxs_optimizer_get_param"
external optimizer_get_sol      : _opt_h -> _solution_h = "caml_hxs_optimizer_get_solution"
external optimizer_solve_       : _opt_h -> unit        = "caml_hxs_optimizer_solve"
external optimizer_stop_        : _opt_h -> unit        = "caml_hxs_optimizer_stop"
external optimizer_state_       : _opt_h -> int         = "caml_hxs_optimizer_state"
external optimizer_running_time_: _opt_h -> int         = "caml_hxs_optimizer_running_time"
external optimizer_nb_iters_    : _opt_h -> int64       = "caml_hxs_optimizer_nb_iterations"

external optimizer_save_env_ : _opt_h -> string -> unit = "caml_hxs_optimizer_save_environment"
external optimizer_load_env_ : _opt_h -> string -> unit = "caml_hxs_optimizer_load_environment"

external optimizer_create_phase_ : _opt_h -> _phs_h     = "caml_hxs_optimizer_create_phase"
external optimizer_get_phase_    : _opt_h -> int -> _phs_h = "caml_hxs_optimizer_get_phase"
external optimizer_nb_phases_    : _opt_h -> int        = "caml_hxs_optimizer_nb_phases"
external phs_set_time_limit_     : _phs_h -> int   -> unit = "caml_hxs_phase_set_time_limit"
external phs_get_time_limit_     : _phs_h -> int          = "caml_hxs_phase_get_time_limit"
external phs_set_iter_limit_     : _phs_h -> int64 -> unit = "caml_hxs_phase_set_iteration_limit"
external phs_get_iter_limit_     : _phs_h -> int64        = "caml_hxs_phase_get_iteration_limit"
external phs_set_opt_obj_        : _phs_h -> int   -> unit = "caml_hxs_phase_set_optimized_objective"
external phs_get_opt_obj_        : _phs_h -> int          = "caml_hxs_phase_get_optimized_objective"
external phs_set_enabled_        : _phs_h -> bool  -> unit = "caml_hxs_phase_set_enabled"
external phs_is_enabled_         : _phs_h -> bool         = "caml_hxs_phase_is_enabled"
external phs_to_string_          : _phs_h -> string       = "caml_hxs_phase_to_string"

external optimizer_compute_iis_ : _opt_h -> _iis_h     = "caml_hxs_optimizer_compute_inconsistency"
external iis_nb_causes_         : _iis_h -> int           = "caml_hxs_inconsistency_nb_causes"
external iis_cause_             : _iis_h -> int -> _expr_h = "caml_hxs_inconsistency_cause"
external iis_to_string_         : _iis_h -> string        = "caml_hxs_inconsistency_to_string"

external optimizer_add_callback_    : _opt_h -> int -> _cb_h = "caml_hxs_optimizer_add_callback"
external optimizer_remove_callback_ : _opt_h -> _cb_h -> bool = "caml_hxs_optimizer_remove_callback"
external callback_pin_   : _cb_h -> (unit -> unit) -> unit = "caml_hxs_callback_pin"
external callback_unpin_ : _cb_h -> unit = "caml_hxs_callback_unpin"

external m_bool_var          : _model_h -> _expr_h               = "caml_hxs_model_bool_var"
external m_int_var           : _model_h -> int -> int -> _expr_h = "caml_hxs_model_int_var"
external m_float_var         : _model_h -> float -> float -> _expr_h = "caml_hxs_model_float_var"
external m_interval_var      : _model_h -> int -> int -> _expr_h = "caml_hxs_model_interval_var"
external m_opt_interval_var  : _model_h -> int -> int -> _expr_h = "caml_hxs_model_optional_interval_var"
external m_list_var          : _model_h -> int -> _expr_h        = "caml_hxs_model_list_var"
external m_set_var           : _model_h -> int -> _expr_h        = "caml_hxs_model_set_var"

external m_const_int         : _model_h -> int -> _expr_h        = "caml_hxs_model_const_int"
external m_const_float       : _model_h -> float -> _expr_h      = "caml_hxs_model_const_float"
external m_const_int_array   : _model_h -> int array -> _expr_h  = "caml_hxs_model_const_int_array"
external m_const_float_array : _model_h -> float array -> _expr_h = "caml_hxs_model_const_float_array"

external m_create_expression :
  _model_h -> int -> _expr_h array -> int array -> float array -> _expr_h
  = "caml_hxs_model_create_expression"

external m_add_constraint : _model_h -> _expr_h -> unit = "caml_hxs_model_add_constraint"
external m_minimize       : _model_h -> _expr_h -> unit = "caml_hxs_model_minimize"
external m_maximize       : _model_h -> _expr_h -> unit = "caml_hxs_model_maximize"
external m_close          : _model_h -> unit            = "caml_hxs_model_close"
external m_is_closed      : _model_h -> bool            = "caml_hxs_model_is_closed"

external m_nb_expressions : _model_h -> int = "caml_hxs_model_nb_expressions"
external m_nb_constraints : _model_h -> int = "caml_hxs_model_nb_constraints"
external m_nb_objectives  : _model_h -> int = "caml_hxs_model_nb_objectives"
external m_nb_decisions   : _model_h -> int = "caml_hxs_model_nb_decisions"

external s_int_value       : _solution_h -> _expr_h -> int       = "caml_hxs_solution_int_value"
external s_float_value     : _solution_h -> _expr_h -> float     = "caml_hxs_solution_float_value"
external s_interval_value  : _solution_h -> _expr_h -> int * int = "caml_hxs_solution_interval_value"
external s_collection_value: _solution_h -> _expr_h -> int array = "caml_hxs_solution_collection_value"
external s_status          : _solution_h -> int                  = "caml_hxs_solution_status"
external s_is_violated     : _solution_h -> _expr_h -> bool      = "caml_hxs_solution_is_violated"
external s_is_undefined    : _solution_h -> _expr_h -> bool      = "caml_hxs_solution_is_undefined"
external s_set_int         : _solution_h -> _expr_h -> int -> unit = "caml_hxs_solution_set_int_value"
external s_set_float       : _solution_h -> _expr_h -> float -> unit = "caml_hxs_solution_set_float_value"
external s_set_interval    : _solution_h -> _expr_h -> int -> int -> unit = "caml_hxs_solution_set_interval_value"
external s_clear           : _solution_h -> unit                 = "caml_hxs_solution_clear"

external p_set_time_limit      : _param_h -> int   -> unit = "caml_hxs_param_set_time_limit"
external p_set_iteration_limit : _param_h -> int64 -> unit = "caml_hxs_param_set_iteration_limit"
external p_set_seed            : _param_h -> int   -> unit = "caml_hxs_param_set_seed"
external p_set_nb_threads      : _param_h -> int   -> unit = "caml_hxs_param_set_nb_threads"
external p_set_verbosity       : _param_h -> int   -> unit = "caml_hxs_param_set_verbosity"
external p_set_warning_level   : _param_h -> int   -> unit = "caml_hxs_param_set_warning_level"
external p_set_tbd             : _param_h -> int   -> unit = "caml_hxs_param_set_time_between_displays"
external p_set_tbt             : _param_h -> int   -> unit = "caml_hxs_param_set_time_between_ticks"
external p_set_ibt             : _param_h -> int64 -> unit = "caml_hxs_param_set_iteration_between_ticks"
external p_set_log_file        : _param_h -> string -> unit = "caml_hxs_param_set_log_file"
external p_set_adv_int         : _param_h -> string -> int   -> unit = "caml_hxs_param_set_advanced_int"
external p_set_adv_dbl         : _param_h -> string -> float -> unit = "caml_hxs_param_set_advanced_double"
external p_set_adv_str         : _param_h -> string -> string -> unit = "caml_hxs_param_set_advanced_string"
external p_set_iot             : _param_h -> int -> int   -> unit = "caml_hxs_param_set_int_objective_threshold"
external p_set_dot             : _param_h -> int -> float -> unit = "caml_hxs_param_set_double_objective_threshold"

(* ---------- Public API ---------- *)

type backend = Real | Mock

external backend_is_mock_ : unit -> bool = "caml_hxs_backend_is_mock"

let backend () = if backend_is_mock_ () then Mock else Real

let mock_warned = ref false

let warn_if_unexpected_mock () =
  if backend () = Mock && not !mock_warned
     && Sys.getenv_opt "HEXALY_BACKEND" <> Some "mock" then begin
    mock_warned := true;
    prerr_endline
      "hexaly: warning: built against the bundled mock backend, not the \
       Hexaly solver. Results are from a brute-force test double. Install \
       Hexaly and reinstall this package (see README), or set \
       HEXALY_BACKEND=mock to silence this warning."
  end

let create () =
  warn_if_unexpected_mock ();
  { _oh = optimizer_new (); _cbs = []; _solving = false }
let model    o = { _mh = optimizer_get_model o._oh; _mo = o }
let param    o = { _ph = optimizer_get_param o._oh; _po = o }
let solution o = { _sh = optimizer_get_sol   o._oh; _so = o }

let pin_callback   cb = callback_pin_ cb._ch cb._closure
let unpin_callback cb = callback_unpin_ cb._ch

let unpin_all o =
  List.iter unpin_callback o._cbs;
  o._solving <- false

let solve o =
  o._solving <- true;
  List.iter pin_callback o._cbs;
  Fun.protect ~finally:(fun () -> unpin_all o)
    (fun () -> optimizer_solve_ o._oh)

let stop o = optimizer_stop_ o._oh

let state         o = State.of_int (optimizer_state_ o._oh)
let running_time  o = optimizer_running_time_ o._oh
let nb_iterations o = optimizer_nb_iters_ o._oh

let save_environment o path = optimizer_save_env_ o._oh path
let load_environment o path = optimizer_load_env_ o._oh path

let wrap m h = { _eh = h; _em = m }

let bool_var               m       = wrap m (m_bool_var         m._mh)
let int_var                m lo hi = wrap m (m_int_var          m._mh lo hi)
let float_var              m lo hi = wrap m (m_float_var        m._mh lo hi)
let interval_var           m a b   = wrap m (m_interval_var     m._mh a b)
let optional_interval_var  m a b   = wrap m (m_opt_interval_var m._mh a b)
let list_var               m n     = wrap m (m_list_var         m._mh n)
let set_var                m n     = wrap m (m_set_var          m._mh n)

let int_const   m n   = wrap m (m_const_int   m._mh n)
let float_const m f   = wrap m (m_const_float m._mh f)
let int_array_const   m a = wrap m (m_const_int_array   m._mh a)
let float_array_const m a = wrap m (m_const_float_array m._mh a)

let empty_ints   : int array   = [||]
let empty_floats : float array = [||]

let create_expression m op ?(operands=[||]) ?(ints=empty_ints) ?(floats=empty_floats) () =
  let raws = Array.map (fun e -> e._eh) operands in
  wrap m (m_create_expression m._mh (Op.to_int op) raws ints floats)

let mk1 m op a       = wrap m (m_create_expression m._mh (Op.to_int op) [|a._eh|] empty_ints empty_floats)
let mk2 m op a b     = wrap m (m_create_expression m._mh (Op.to_int op) [|a._eh; b._eh|] empty_ints empty_floats)
let mk3 m op a b c   = wrap m (m_create_expression m._mh (Op.to_int op) [|a._eh; b._eh; c._eh|] empty_ints empty_floats)
let mkn m op xs =
  let arr = Array.of_list (List.map (fun e -> e._eh) xs) in
  wrap m (m_create_expression m._mh (Op.to_int op) arr empty_ints empty_floats)

let sum   m xs    = mkn m Op.Sum  xs
let prod  m xs    = mkn m Op.Prod xs
let add   m a b   = mk2 m Op.Sum  a b
let sub   m a b   = mk2 m Op.Sub  a b
let mul   m a b   = mk2 m Op.Prod a b
let div   m a b   = mk2 m Op.Div  a b
let neg   m a     = mk2 m Op.Sub  (int_const m 0) a
let abs   m a     = mk1 m Op.Abs  a
let dist  m a b   = mk2 m Op.Dist a b
let mod_  m a b   = mk2 m Op.Mod  a b
let max   m xs    = mkn m Op.Max  xs
let min   m xs    = mkn m Op.Min  xs

let sqrt  m a     = mk1 m Op.Sqrt  a
let log   m a     = mk1 m Op.Log   a
let exp   m a     = mk1 m Op.Exp   a
let pow   m a b   = mk2 m Op.Pow   a b
let cos   m a     = mk1 m Op.Cos   a
let sin   m a     = mk1 m Op.Sin   a
let tan   m a     = mk1 m Op.Tan   a
let ceil  m a     = mk1 m Op.Ceil  a
let floor m a     = mk1 m Op.Floor a
let round m a     = mk1 m Op.Round a

let eq    m a b   = mk2 m Op.Eq  a b
let neq   m a b   = mk2 m Op.Neq a b
let lt    m a b   = mk2 m Op.Lt  a b
let leq   m a b   = mk2 m Op.Leq a b
let gt    m a b   = mk2 m Op.Gt  a b
let geq   m a b   = mk2 m Op.Geq a b

let and_  m xs    = mkn m Op.And xs
let or_   m xs    = mkn m Op.Or  xs
let xor_  m xs    = mkn m Op.Xor xs
let not_  m a     = mk1 m Op.Not a
let if_   m c a b = mk3 m Op.If  c a b

let array       m xs   = mkn m Op.Array xs
let at          m a is = mkn m Op.At (a :: is)
let scalar      m a b  = mk2 m Op.Scalar a b
let count       m a    = mk1 m Op.Count a
let index_of    m a b  = mk2 m Op.IndexOf a b
let contains    m a b  = mk2 m Op.Contains a b
let partition   m xs   = mkn m Op.Partition xs
let disjoint    m xs   = mkn m Op.Disjoint xs
let distinct    m a    = mk1 m Op.Distinct a
let find        m a b  = mk2 m Op.Find a b
let sort        m a    = mk1 m Op.Sort a
let intersection m xs  = mkn m Op.Intersection xs
let union_       m xs  = mkn m Op.Union xs
let hull         m xs  = mkn m Op.Hull xs

let start    m a = mk1 m Op.Start    a
let end_     m a = mk1 m Op.End_     a
let length   m a = mk1 m Op.Length   a
let presence m a = mk1 m Op.Presence a

let add_constraint m e = m_add_constraint m._mh e._eh
let minimize       m e = m_minimize       m._mh e._eh
let maximize       m e = m_maximize       m._mh e._eh
let close          m   = m_close          m._mh
let is_closed      m   = m_is_closed      m._mh

let nb_expressions m = m_nb_expressions m._mh
let nb_constraints m = m_nb_constraints m._mh
let nb_objectives  m = m_nb_objectives  m._mh
let nb_decisions   m = m_nb_decisions   m._mh

let int_value         s e = s_int_value        s._sh e._eh
let float_value       s e = s_float_value      s._sh e._eh
let interval_value    s e = s_interval_value   s._sh e._eh
let collection_value  s e = s_collection_value s._sh e._eh
let status            s   = Status.of_int (s_status s._sh)
let is_violated       s e = s_is_violated  s._sh e._eh
let is_undefined      s e = s_is_undefined s._sh e._eh

let set_int_value      s e v = s_set_int      s._sh e._eh v
let set_float_value    s e v = s_set_float    s._sh e._eh v
let set_interval_value s e ~start ~end_ = s_set_interval s._sh e._eh start end_
let clear_solution     s     = s_clear        s._sh

let set_time_limit              p v = p_set_time_limit      p._ph v
let set_iteration_limit         p v = p_set_iteration_limit p._ph v
let set_seed                    p v = p_set_seed            p._ph v
let set_nb_threads              p v = p_set_nb_threads      p._ph v
let set_verbosity               p v = p_set_verbosity       p._ph v
let set_warning_level           p v = p_set_warning_level   p._ph v
let set_time_between_displays   p v = p_set_tbd             p._ph v
let set_time_between_ticks      p v = p_set_tbt             p._ph v
let set_iteration_between_ticks p v = p_set_ibt             p._ph v
let set_log_file                p s = p_set_log_file        p._ph s
let set_int_objective_threshold    p i t = p_set_iot p._ph i t
let set_double_objective_threshold p i t = p_set_dot p._ph i t
let set_advanced_int    p k v = p_set_adv_int p._ph k v
let set_advanced_double p k v = p_set_adv_dbl p._ph k v
let set_advanced_string p k v = p_set_adv_str p._ph k v

(* ---------- Phase ---------- *)
module Phase = struct
  type t = { _ph : _phs_h; _po : optimizer }

  let create o = { _ph = optimizer_create_phase_ o._oh; _po = o }
  let get o i  = { _ph = optimizer_get_phase_ o._oh i; _po = o }
  let nb_phases o = optimizer_nb_phases_ o._oh

  let set_time_limit p v          = phs_set_time_limit_ p._ph v
  let time_limit p                = phs_get_time_limit_ p._ph
  let set_iteration_limit p v     = phs_set_iter_limit_ p._ph v
  let iteration_limit p           = phs_get_iter_limit_ p._ph
  let set_optimized_objective p v = phs_set_opt_obj_   p._ph v
  let optimized_objective p       = phs_get_opt_obj_   p._ph
  let set_enabled p v             = phs_set_enabled_   p._ph v
  let is_enabled p                = phs_is_enabled_    p._ph
  let to_string p                 = phs_to_string_     p._ph
  let pp ppf p = Format.pp_print_string ppf (to_string p)
end

(* ---------- Inconsistency ---------- *)
module Inconsistency = struct
  type t = { _ih : _iis_h; _io : optimizer }

  let nb_causes i = iis_nb_causes_ i._ih
  let cause i idx = { _eh = iis_cause_ i._ih idx; _em = model i._io }
  let to_string i = iis_to_string_ i._ih
  let pp ppf i = Format.pp_print_string ppf (to_string i)
end

let compute_inconsistency o =
  { Inconsistency._ih = optimizer_compute_iis_ o._oh; _io = o }

(* ---------- Callbacks ----------
   Lifetime: a registered callback fires until [remove_callback] is called
   or its optimizer is collected. The optimizer's [_cbs] list keeps the
   callback record reachable, so users need not retain the returned
   handle. *)
let add_callback opt cb_type closure =
  let h = optimizer_add_callback_ opt._oh (Callback_type.to_int cb_type) in
  let cb = { _ch = h; _co = opt; _closure = closure } in
  opt._cbs <- cb :: opt._cbs;
  if opt._solving then pin_callback cb;
  cb

let remove_callback cb =
  let o = cb._co in
  let removed = optimizer_remove_callback_ o._oh cb._ch in
  o._cbs <- List.filter (fun c -> not (c == cb)) o._cbs;
  removed

(* ---------- Syntax ---------- *)
module Syntax = struct
  let current : model option ref = ref None
  let with_model m f =
    let prev = !current in
    current := Some m;
    Fun.protect ~finally:(fun () -> current := prev) f
  let m () = match !current with
    | Some m -> m
    | None -> failwith "Hexaly.Syntax: no current model"
  let ( +! )  a b = add (m ()) a b
  let ( -! )  a b = sub (m ()) a b
  let ( *! )  a b = mul (m ()) a b
  let ( /! )  a b = div (m ()) a b
  let ( =! )  a b = eq  (m ()) a b
  let ( <>! ) a b = neq (m ()) a b
  let ( <! )  a b = lt  (m ()) a b
  let ( <=! ) a b = leq (m ()) a b
  let ( >! )  a b = gt  (m ()) a b
  let ( >=! ) a b = geq (m ()) a b
  let ( !! ) n = int_const (m ()) n
end
