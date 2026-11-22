/* hexaly_stubs.c - OCaml C stubs over hexaly_shim.h.
 *
 * Each Hexaly handle becomes an OCaml custom block carrying a pointer + a
 * finalizer that calls the matching hxs_*_free. Errors from the shim are
 * raised as the typed exception (Hexaly_error of code * string), looked up
 * via caml_named_value("Hexaly.Hexaly_error") which hexaly.ml registers at
 * module init time.
 *
 * Callbacks:
 *   - The user supplies an OCaml closure (unit -> unit).
 *   - We wrap it in a CallbackBox holding a generational global root + the
 *     shim's hxs_callback*.
 *   - The custom block's finalizer calls hxs_optimizer_remove_callback,
 *     unregisters the root, and frees the box.
 *   - The OCaml-side record holding the callback handle ALSO holds the
 *     optimizer, so the optimizer can't be GC'd before its callbacks.
 *   - The trampoline runs on whatever thread Hexaly invokes it from. It
 *     registers the thread (defensive — idempotent), acquires the runtime
 *     lock (since solve() released it), calls the closure, releases the
 *     lock, and returns. OCaml exceptions in the user callback are caught
 *     and printed to stderr — they don't escape into Hexaly's C++ code,
 *     which would be undefined behavior.
 *
 * Threading note: solve() releases the OCaml runtime lock for its duration
 * so other OCaml threads (if any) can run and so callbacks from Hexaly
 * worker threads can safely call back into OCaml.
 */
#define CAML_NAME_SPACE
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <caml/callback.h>
#include <caml/threads.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hexaly_shim.h"

/* ---------- typed error raising ---------- */
static const value* hexaly_error_exn = NULL;

static void init_hexaly_error_exn(void) {
    if (hexaly_error_exn == NULL) {
        hexaly_error_exn = caml_named_value("Hexaly.Hexaly_error");
    }
}

static void raise_hexaly_error(const char* fallback) {
    init_hexaly_error_exn();
    const char* msg = hxs_last_error();
    if (!msg) msg = fallback ? fallback : "Hexaly: unknown error";
    if (hexaly_error_exn == NULL) {
        caml_failwith(msg);
    }
    int code = (int)hxs_last_error_code();
    value args[2];
    args[0] = Val_int(code);
    args[1] = caml_copy_string(msg);
    caml_raise_with_args(*hexaly_error_exn, 2, args);
}

#define CHECK_HANDLE(p, what) do { if ((p) == NULL) raise_hexaly_error(what); } while (0)

/* ---------- custom-block boilerplate ---------- */
#define DEFINE_HANDLE(Name, C_t, FreeFn)                                 \
    static void Name##_finalize(value v) {                               \
        C_t* p = *((C_t**)Data_custom_val(v));                           \
        if (p) FreeFn(p);                                                \
    }                                                                    \
    static struct custom_operations Name##_ops = {                       \
        "hexaly." #Name,                                                 \
        Name##_finalize,                                                 \
        custom_compare_default,                                          \
        custom_hash_default,                                              \
        custom_serialize_default,                                        \
        custom_deserialize_default,                                       \
        custom_compare_ext_default,                                       \
        custom_fixed_length_default                                      \
    };                                                                    \
    static value Name##_alloc(C_t* p) {                                   \
        value v = caml_alloc_custom(&Name##_ops, sizeof(C_t*), 0, 1);     \
        *((C_t**)Data_custom_val(v)) = p;                                 \
        return v;                                                         \
    }                                                                     \
    static inline C_t* Name##_get(value v) {                              \
        return *((C_t**)Data_custom_val(v));                              \
    }

DEFINE_HANDLE(opt,  hxs_optimizer,     hxs_optimizer_free)
DEFINE_HANDLE(mdl,  hxs_model,         hxs_model_free)
DEFINE_HANDLE(expr, hxs_expression,    hxs_expression_free)
DEFINE_HANDLE(sol,  hxs_solution,      hxs_solution_free)
DEFINE_HANDLE(prm,  hxs_param,         hxs_param_free)
DEFINE_HANDLE(iis,  hxs_inconsistency, hxs_inconsistency_free)
DEFINE_HANDLE(phs,  hxs_phase,         hxs_phase_free)

/* ---------- Callback box + finalizer ----------
 * The closure is registered as a GC root only while [solve] runs (see
 * [Hexaly.solve], which pins and unpins). Outside [solve] nothing on the C
 * side references the closure, so a closure that captures its optimizer
 * does not keep that optimizer alive. */
typedef struct {
    value          closure;   /* 0 when unpinned; else a generational root */
    hxs_callback*  shim;      /* Hexaly's callback handle; NULL once removed */
    hxs_optimizer* owner;
} CallbackBox;

static void cb_trampoline(hxs_optimizer* opt, hxs_callback_type type, void* userdata) {
    (void)opt; (void)type;
    CallbackBox* box = (CallbackBox*)userdata;
    if (!box) return;
    /* Register defensively; idempotent on already-registered threads. */
    caml_c_thread_register();
    caml_acquire_runtime_system();
    /* Read the root only while holding the runtime lock: the GC may move it. */
    if (box->closure) {
        value result = caml_callback_exn(box->closure, Val_unit);
        if (Is_exception_result(result)) {
            fprintf(stderr, "Hexaly: user callback raised an exception (suppressed)\n");
        }
    }
    caml_release_runtime_system();
}

static void callback_unpin(CallbackBox* box) {
    if (box->closure) {
        caml_remove_generational_global_root(&box->closure);
        box->closure = 0;
    }
}

/* Must not call into the owner: when the optimizer and its callbacks become
 * unreachable together, finalizers run in no particular order and the owner
 * may already be freed. hxs_optimizer_free drops the shim-side callbacks. */
static void callback_box_finalize(CallbackBox* box) {
    if (!box) return;
    callback_unpin(box);
    free(box);
}
DEFINE_HANDLE(cb, CallbackBox, callback_box_finalize)

/* ---------- Version ---------- */
CAMLprim value caml_hxs_backend_is_mock(value unit) { (void)unit; return Val_bool(hxs_backend_is_mock()); }
CAMLprim value caml_hxs_version_major(value unit) { (void)unit; return Val_int(hxs_version_major()); }
CAMLprim value caml_hxs_version_minor(value unit) { (void)unit; return Val_int(hxs_version_minor()); }
CAMLprim value caml_hxs_version_code (value unit) { (void)unit; return Val_int(hxs_version_code()); }
CAMLprim value caml_hxs_version_build_date(value unit) { (void)unit; return Val_int(hxs_version_build_date()); }

static value copy_str_via_getter(int (*getter)(char*, int)) {
    int need = getter(NULL, 0);
    if (need < 0) raise_hexaly_error("Hexaly.Version (getter)");
    /* need includes NUL terminator. */
    char* buf = caml_stat_alloc((size_t)need);
    getter(buf, need);
    value v = caml_copy_string(buf);
    caml_stat_free(buf);
    return v;
}

CAMLprim value caml_hxs_version_string  (value u) { (void)u; return copy_str_via_getter(hxs_version_string); }
CAMLprim value caml_hxs_version_platform(value u) { (void)u; return copy_str_via_getter(hxs_version_platform); }
CAMLprim value caml_hxs_version_info    (value u) { (void)u; return copy_str_via_getter(hxs_version_info); }
CAMLprim value caml_hxs_version_copyright(value u) { (void)u; return copy_str_via_getter(hxs_version_copyright); }
CAMLprim value caml_hxs_version_license_path(value u) { (void)u; return copy_str_via_getter(hxs_version_license_path); }

CAMLprim value caml_hxs_version_set_license_path(value v) {
    CAMLparam1(v);
    hxs_version_set_license_path(String_val(v));
    CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_version_set_license_content(value v) {
    CAMLparam1(v);
    hxs_version_set_license_content(String_val(v));
    CAMLreturn(Val_unit);
}

/* ---------- Optimizer ---------- */
CAMLprim value caml_hxs_optimizer_new(value unit) {
    CAMLparam1(unit);
    hxs_optimizer* p = hxs_optimizer_new();
    CHECK_HANDLE(p, "Hexaly.create");
    CAMLreturn(opt_alloc(p));
}
CAMLprim value caml_hxs_optimizer_get_model(value v) {
    CAMLparam1(v);
    hxs_model* p = hxs_optimizer_get_model(opt_get(v));
    CHECK_HANDLE(p, "Hexaly.model");
    CAMLreturn(mdl_alloc(p));
}
CAMLprim value caml_hxs_optimizer_get_param(value v) {
    CAMLparam1(v);
    hxs_param* p = hxs_optimizer_get_param(opt_get(v));
    CHECK_HANDLE(p, "Hexaly.param");
    CAMLreturn(prm_alloc(p));
}
CAMLprim value caml_hxs_optimizer_get_solution(value v) {
    CAMLparam1(v);
    hxs_solution* p = hxs_optimizer_get_solution(opt_get(v));
    CHECK_HANDLE(p, "Hexaly.solution");
    CAMLreturn(sol_alloc(p));
}

CAMLprim value caml_hxs_optimizer_solve(value v) {
    CAMLparam1(v);
    hxs_optimizer* o = opt_get(v);
    /* Release the runtime lock for the duration of solve() so callbacks from
     * Hexaly worker threads can call back into OCaml safely, and so other
     * OCaml threads can run. */
    caml_release_runtime_system();
    int rc = hxs_optimizer_solve(o);
    caml_acquire_runtime_system();
    if (rc != 0) raise_hexaly_error("Hexaly.solve");
    CAMLreturn(Val_unit);
}

CAMLprim value caml_hxs_optimizer_stop(value v) {
    CAMLparam1(v); hxs_optimizer_stop(opt_get(v)); CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_optimizer_state(value v) {
    CAMLparam1(v);
    CAMLreturn(Val_int((int)hxs_optimizer_get_state(opt_get(v))));
}
CAMLprim value caml_hxs_optimizer_running_time(value v) {
    CAMLparam1(v);
    int t = hxs_optimizer_running_time(opt_get(v));
    if (t < 0) raise_hexaly_error("Hexaly.running_time");
    CAMLreturn(Val_int(t));
}
CAMLprim value caml_hxs_optimizer_nb_iterations(value v) {
    CAMLparam1(v);
    long long n = hxs_optimizer_nb_iterations(opt_get(v));
    if (n < 0) raise_hexaly_error("Hexaly.nb_iterations");
    CAMLreturn(caml_copy_int64((int64_t)n));
}

CAMLprim value caml_hxs_optimizer_save_environment(value v_opt, value v_path) {
    CAMLparam2(v_opt, v_path);
    int rc = hxs_optimizer_save_environment(opt_get(v_opt), String_val(v_path));
    if (rc != 0) raise_hexaly_error("Hexaly.save_environment");
    CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_optimizer_load_environment(value v_opt, value v_path) {
    CAMLparam2(v_opt, v_path);
    int rc = hxs_optimizer_load_environment(opt_get(v_opt), String_val(v_path));
    if (rc != 0) raise_hexaly_error("Hexaly.load_environment");
    CAMLreturn(Val_unit);
}

/* ---------- Phases ---------- */
CAMLprim value caml_hxs_optimizer_create_phase(value v_opt) {
    CAMLparam1(v_opt);
    hxs_phase* p = hxs_optimizer_create_phase(opt_get(v_opt));
    CHECK_HANDLE(p, "Hexaly.Phase.create");
    CAMLreturn(phs_alloc(p));
}
CAMLprim value caml_hxs_optimizer_get_phase(value v_opt, value v_idx) {
    CAMLparam2(v_opt, v_idx);
    hxs_phase* p = hxs_optimizer_get_phase(opt_get(v_opt), Int_val(v_idx));
    CHECK_HANDLE(p, "Hexaly.Phase.get");
    CAMLreturn(phs_alloc(p));
}
CAMLprim value caml_hxs_optimizer_nb_phases(value v_opt) {
    CAMLparam1(v_opt);
    int n = hxs_optimizer_nb_phases(opt_get(v_opt));
    if (n < 0) raise_hexaly_error("Hexaly.Phase.nb_phases");
    CAMLreturn(Val_int(n));
}
CAMLprim value caml_hxs_phase_set_time_limit(value v_p, value v_n) {
    CAMLparam2(v_p, v_n); hxs_phase_set_time_limit(phs_get(v_p), Int_val(v_n)); CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_phase_get_time_limit(value v_p) {
    CAMLparam1(v_p);
    int r = hxs_phase_get_time_limit(phs_get(v_p));
    if (r < 0) raise_hexaly_error("Hexaly.Phase.time_limit");
    CAMLreturn(Val_int(r));
}
CAMLprim value caml_hxs_phase_set_iteration_limit(value v_p, value v_n) {
    CAMLparam2(v_p, v_n);
    hxs_phase_set_iteration_limit(phs_get(v_p), (long long)Int64_val(v_n));
    CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_phase_get_iteration_limit(value v_p) {
    CAMLparam1(v_p);
    long long n = hxs_phase_get_iteration_limit(phs_get(v_p));
    if (n < 0) raise_hexaly_error("Hexaly.Phase.iteration_limit");
    CAMLreturn(caml_copy_int64((int64_t)n));
}
CAMLprim value caml_hxs_phase_set_optimized_objective(value v_p, value v_n) {
    CAMLparam2(v_p, v_n); hxs_phase_set_optimized_objective(phs_get(v_p), Int_val(v_n)); CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_phase_get_optimized_objective(value v_p) {
    CAMLparam1(v_p);
    int r = hxs_phase_get_optimized_objective(phs_get(v_p));
    if (r < 0) raise_hexaly_error("Hexaly.Phase.optimized_objective");
    CAMLreturn(Val_int(r));
}
CAMLprim value caml_hxs_phase_set_enabled(value v_p, value v_b) {
    CAMLparam2(v_p, v_b); hxs_phase_set_enabled(phs_get(v_p), Bool_val(v_b)); CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_phase_is_enabled(value v_p) {
    CAMLparam1(v_p);
    int r = hxs_phase_is_enabled(phs_get(v_p));
    if (r < 0) raise_hexaly_error("Hexaly.Phase.is_enabled");
    CAMLreturn(Val_bool(r));
}
CAMLprim value caml_hxs_phase_to_string(value v_p) {
    CAMLparam1(v_p);
    int need = hxs_phase_to_string(phs_get(v_p), NULL, 0);
    if (need < 0) raise_hexaly_error("Hexaly.Phase.to_string");
    char* buf = caml_stat_alloc((size_t)need);
    hxs_phase_to_string(phs_get(v_p), buf, need);
    value r = caml_copy_string(buf);
    caml_stat_free(buf);
    CAMLreturn(r);
}

/* ---------- Inconsistency ---------- */
CAMLprim value caml_hxs_optimizer_compute_inconsistency(value v) {
    CAMLparam1(v);
    hxs_inconsistency* p = hxs_optimizer_compute_inconsistency(opt_get(v));
    CHECK_HANDLE(p, "Hexaly.compute_inconsistency");
    CAMLreturn(iis_alloc(p));
}
CAMLprim value caml_hxs_inconsistency_nb_causes(value v) {
    CAMLparam1(v);
    int n = hxs_inconsistency_nb_causes(iis_get(v));
    if (n < 0) raise_hexaly_error("Hexaly.Inconsistency.nb_causes");
    CAMLreturn(Val_int(n));
}
CAMLprim value caml_hxs_inconsistency_cause(value v_iis, value v_idx) {
    CAMLparam2(v_iis, v_idx);
    hxs_expression* p = hxs_inconsistency_cause(iis_get(v_iis), Int_val(v_idx));
    CHECK_HANDLE(p, "Hexaly.Inconsistency.cause");
    CAMLreturn(expr_alloc(p));
}
CAMLprim value caml_hxs_inconsistency_to_string(value v) {
    CAMLparam1(v);
    int need = hxs_inconsistency_to_string(iis_get(v), NULL, 0);
    if (need < 0) raise_hexaly_error("Hexaly.Inconsistency.to_string");
    char* buf = caml_stat_alloc((size_t)need);
    hxs_inconsistency_to_string(iis_get(v), buf, need);
    value r = caml_copy_string(buf);
    caml_stat_free(buf);
    CAMLreturn(r);
}

/* ---------- Callbacks ---------- */
CAMLprim value caml_hxs_optimizer_add_callback(value v_opt, value v_type)
{
    CAMLparam2(v_opt, v_type);
    CallbackBox* box = (CallbackBox*)calloc(1, sizeof(CallbackBox));
    if (!box) caml_failwith("Hexaly.add_callback: out of memory");
    box->owner = opt_get(v_opt);
    hxs_callback* shim = hxs_optimizer_add_callback(
        box->owner, (hxs_callback_type)Int_val(v_type),
        cb_trampoline, box);
    if (!shim) {
        free(box);
        raise_hexaly_error("Hexaly.add_callback");
    }
    box->shim = shim;
    CAMLreturn(cb_alloc(box));
}

CAMLprim value caml_hxs_callback_pin(value v_cb, value v_closure) {
    CAMLparam2(v_cb, v_closure);
    CallbackBox* box = cb_get(v_cb);
    if (box && box->shim && !box->closure) {
        box->closure = v_closure;
        caml_register_generational_global_root(&box->closure);
    }
    CAMLreturn(Val_unit);
}

CAMLprim value caml_hxs_callback_unpin(value v_cb) {
    CAMLparam1(v_cb);
    CallbackBox* box = cb_get(v_cb);
    if (box) callback_unpin(box);
    CAMLreturn(Val_unit);
}

CAMLprim value caml_hxs_optimizer_remove_callback(value v_opt, value v_cb) {
    CAMLparam2(v_opt, v_cb);
    (void)v_opt; /* the box already holds the owner */
    CallbackBox* box = cb_get(v_cb);
    if (!box) CAMLreturn(Val_bool(0));
    int removed = 0;
    if (box->shim && box->owner) {
        removed = hxs_optimizer_remove_callback(box->owner, box->shim);
        box->shim = NULL;
    }
    callback_unpin(box);
    CAMLreturn(Val_bool(removed));
}

/* ---------- Model: decisions ---------- */
#define DECISION_VAR_NO_ARGS(camlname, shimname, errstr)        \
    CAMLprim value camlname(value v_m) {                        \
        CAMLparam1(v_m);                                        \
        hxs_expression* p = shimname(mdl_get(v_m));             \
        CHECK_HANDLE(p, errstr);                                \
        CAMLreturn(expr_alloc(p));                              \
    }
#define DECISION_VAR_2INT(camlname, shimname, errstr)           \
    CAMLprim value camlname(value v_m, value v_a, value v_b) {  \
        CAMLparam3(v_m, v_a, v_b);                              \
        hxs_expression* p = shimname(mdl_get(v_m),              \
            (hxs_int)Long_val(v_a), (hxs_int)Long_val(v_b));    \
        CHECK_HANDLE(p, errstr);                                \
        CAMLreturn(expr_alloc(p));                              \
    }

DECISION_VAR_NO_ARGS(caml_hxs_model_bool_var, hxs_model_bool_var, "Hexaly.bool_var")
DECISION_VAR_2INT   (caml_hxs_model_int_var,  hxs_model_int_var,  "Hexaly.int_var")

CAMLprim value caml_hxs_model_float_var(value v_m, value v_lo, value v_hi) {
    CAMLparam3(v_m, v_lo, v_hi);
    hxs_expression* p = hxs_model_float_var(mdl_get(v_m), Double_val(v_lo), Double_val(v_hi));
    CHECK_HANDLE(p, "Hexaly.float_var");
    CAMLreturn(expr_alloc(p));
}
DECISION_VAR_2INT(caml_hxs_model_interval_var,          hxs_model_interval_var,          "Hexaly.interval_var")
DECISION_VAR_2INT(caml_hxs_model_optional_interval_var, hxs_model_optional_interval_var, "Hexaly.optional_interval_var")

CAMLprim value caml_hxs_model_list_var(value v_m, value v_n) {
    CAMLparam2(v_m, v_n);
    hxs_expression* p = hxs_model_list_var(mdl_get(v_m), (hxs_int)Long_val(v_n));
    CHECK_HANDLE(p, "Hexaly.list_var");
    CAMLreturn(expr_alloc(p));
}
CAMLprim value caml_hxs_model_set_var(value v_m, value v_n) {
    CAMLparam2(v_m, v_n);
    hxs_expression* p = hxs_model_set_var(mdl_get(v_m), (hxs_int)Long_val(v_n));
    CHECK_HANDLE(p, "Hexaly.set_var");
    CAMLreturn(expr_alloc(p));
}

/* ---------- Model: constants ---------- */
CAMLprim value caml_hxs_model_const_int(value v_m, value v_n) {
    CAMLparam2(v_m, v_n);
    hxs_expression* p = hxs_model_const_int(mdl_get(v_m), (hxs_int)Long_val(v_n));
    CHECK_HANDLE(p, "Hexaly.int_const");
    CAMLreturn(expr_alloc(p));
}
CAMLprim value caml_hxs_model_const_float(value v_m, value v_f) {
    CAMLparam2(v_m, v_f);
    hxs_expression* p = hxs_model_const_float(mdl_get(v_m), Double_val(v_f));
    CHECK_HANDLE(p, "Hexaly.float_const");
    CAMLreturn(expr_alloc(p));
}
CAMLprim value caml_hxs_model_const_int_array(value v_m, value v_arr) {
    CAMLparam2(v_m, v_arr);
    mlsize_t n = Wosize_val(v_arr);
    hxs_int* buf = (n == 0) ? NULL : caml_stat_alloc(n * sizeof(hxs_int));
    for (mlsize_t i = 0; i < n; ++i) buf[i] = (hxs_int)Long_val(Field(v_arr, i));
    hxs_expression* p = hxs_model_const_int_array(mdl_get(v_m), buf, (int)n);
    if (buf) caml_stat_free(buf);
    CHECK_HANDLE(p, "Hexaly.int_array_const");
    CAMLreturn(expr_alloc(p));
}
CAMLprim value caml_hxs_model_const_float_array(value v_m, value v_arr) {
    CAMLparam2(v_m, v_arr);
    mlsize_t n = (Tag_val(v_arr) == Double_array_tag)
               ? Wosize_val(v_arr) / Double_wosize : 0;
    const hxs_float* buf = (n == 0) ? NULL : (const hxs_float*)v_arr;
    hxs_expression* p = hxs_model_const_float_array(mdl_get(v_m), buf, (int)n);
    CHECK_HANDLE(p, "Hexaly.float_array_const");
    CAMLreturn(expr_alloc(p));
}

#define STACK_THRESHOLD 64

CAMLprim value caml_hxs_model_create_expression(
    value v_m, value v_op, value v_ops, value v_ints, value v_floats)
{
    CAMLparam5(v_m, v_op, v_ops, v_ints, v_floats);

    mlsize_t nb_ops    = Wosize_val(v_ops);
    mlsize_t nb_ints   = Wosize_val(v_ints);
    mlsize_t nb_floats = (Tag_val(v_floats) == Double_array_tag)
                       ? Wosize_val(v_floats) / Double_wosize : 0;

    hxs_expression* stack_ops[STACK_THRESHOLD];
    hxs_expression** ops_buf = (nb_ops <= STACK_THRESHOLD) ? stack_ops
        : (hxs_expression**)caml_stat_alloc(nb_ops * sizeof(hxs_expression*));
    for (mlsize_t i = 0; i < nb_ops; ++i) ops_buf[i] = expr_get(Field(v_ops, i));

    hxs_int stack_ints[STACK_THRESHOLD];
    hxs_int* ints_buf = (nb_ints <= STACK_THRESHOLD) ? stack_ints
        : (hxs_int*)caml_stat_alloc(nb_ints * sizeof(hxs_int));
    for (mlsize_t i = 0; i < nb_ints; ++i) ints_buf[i] = (hxs_int)Long_val(Field(v_ints, i));

    const hxs_float* floats_buf = (nb_floats == 0) ? NULL : (const hxs_float*)v_floats;

    hxs_expression* p = hxs_model_create_expression(
        mdl_get(v_m), (hxs_operator)Int_val(v_op),
        ops_buf, (int)nb_ops,
        ints_buf, (int)nb_ints,
        floats_buf, (int)nb_floats);

    if (ops_buf  != stack_ops)  caml_stat_free(ops_buf);
    if (ints_buf != stack_ints) caml_stat_free(ints_buf);

    CHECK_HANDLE(p, "Hexaly.create_expression");
    CAMLreturn(expr_alloc(p));
}

/* ---------- Model: constraints/objectives/state ---------- */
#define MODEL_OP_E(camlname, shimname, errstr)             \
    CAMLprim value camlname(value v_m, value v_e) {        \
        CAMLparam2(v_m, v_e);                              \
        hxs_clear_error();                                 \
        shimname(mdl_get(v_m), expr_get(v_e));             \
        if (hxs_last_error()) raise_hexaly_error(errstr);  \
        CAMLreturn(Val_unit);                              \
    }
MODEL_OP_E(caml_hxs_model_add_constraint, hxs_model_add_constraint, "Hexaly.add_constraint")
MODEL_OP_E(caml_hxs_model_minimize,       hxs_model_minimize,       "Hexaly.minimize")
MODEL_OP_E(caml_hxs_model_maximize,       hxs_model_maximize,       "Hexaly.maximize")

CAMLprim value caml_hxs_model_close(value v_m) {
    CAMLparam1(v_m);
    hxs_clear_error();
    hxs_model_close(mdl_get(v_m));
    if (hxs_last_error()) raise_hexaly_error("Hexaly.close");
    CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_model_is_closed(value v_m) {
    CAMLparam1(v_m);
    int r = hxs_model_is_closed(mdl_get(v_m));
    if (r < 0) raise_hexaly_error("Hexaly.is_closed");
    CAMLreturn(Val_bool(r));
}

#define MODEL_NB(camlname, shimname, errstr)               \
    CAMLprim value camlname(value v_m) {                   \
        CAMLparam1(v_m);                                   \
        int r = shimname(mdl_get(v_m));                    \
        if (r < 0) raise_hexaly_error(errstr);             \
        CAMLreturn(Val_int(r));                            \
    }
MODEL_NB(caml_hxs_model_nb_expressions, hxs_model_nb_expressions, "Hexaly.nb_expressions")
MODEL_NB(caml_hxs_model_nb_constraints, hxs_model_nb_constraints, "Hexaly.nb_constraints")
MODEL_NB(caml_hxs_model_nb_objectives,  hxs_model_nb_objectives,  "Hexaly.nb_objectives")
MODEL_NB(caml_hxs_model_nb_decisions,   hxs_model_nb_decisions,   "Hexaly.nb_decisions")

/* ---------- Solution ---------- */
CAMLprim value caml_hxs_solution_int_value(value v_s, value v_e) {
    CAMLparam2(v_s, v_e);
    hxs_clear_error();
    hxs_int r = hxs_solution_int_value(sol_get(v_s), expr_get(v_e));
    if (hxs_last_error()) raise_hexaly_error("Hexaly.int_value");
    CAMLreturn(Val_long((intnat)r));
}
CAMLprim value caml_hxs_solution_float_value(value v_s, value v_e) {
    CAMLparam2(v_s, v_e);
    hxs_clear_error();
    hxs_float r = hxs_solution_float_value(sol_get(v_s), expr_get(v_e));
    if (hxs_last_error()) raise_hexaly_error("Hexaly.float_value");
    CAMLreturn(caml_copy_double(r));
}
CAMLprim value caml_hxs_solution_status(value v_s) {
    CAMLparam1(v_s);
    hxs_clear_error();
    hxs_solution_status r = hxs_solution_get_status(sol_get(v_s));
    if (hxs_last_error()) raise_hexaly_error("Hexaly.status");
    CAMLreturn(Val_int((int)r));
}
CAMLprim value caml_hxs_solution_is_violated(value v_s, value v_e) {
    CAMLparam2(v_s, v_e);
    int r = hxs_solution_is_violated(sol_get(v_s), expr_get(v_e));
    if (r < 0) raise_hexaly_error("Hexaly.is_violated");
    CAMLreturn(Val_bool(r));
}
CAMLprim value caml_hxs_solution_is_undefined(value v_s, value v_e) {
    CAMLparam2(v_s, v_e);
    int r = hxs_solution_is_undefined(sol_get(v_s), expr_get(v_e));
    if (r < 0) raise_hexaly_error("Hexaly.is_undefined");
    CAMLreturn(Val_bool(r));
}
CAMLprim value caml_hxs_solution_interval_value(value v_s, value v_e) {
    CAMLparam2(v_s, v_e);
    CAMLlocal1(tuple);
    hxs_int st = 0, ed = 0;
    int rc = hxs_solution_interval_value(sol_get(v_s), expr_get(v_e), &st, &ed);
    if (rc != 0) raise_hexaly_error("Hexaly.interval_value");
    tuple = caml_alloc(2, 0);
    Store_field(tuple, 0, Val_long((intnat)st));
    Store_field(tuple, 1, Val_long((intnat)ed));
    CAMLreturn(tuple);
}
CAMLprim value caml_hxs_solution_collection_value(value v_s, value v_e) {
    CAMLparam2(v_s, v_e);
    CAMLlocal1(arr);
    int n = hxs_solution_collection_size(sol_get(v_s), expr_get(v_e));
    if (n < 0) raise_hexaly_error("Hexaly.collection_value (size)");
    if (n == 0) { CAMLreturn(Atom(0)); }
    hxs_int* buf = caml_stat_alloc((size_t)n * sizeof(hxs_int));
    int written = hxs_solution_collection_dump(sol_get(v_s), expr_get(v_e), buf, n);
    if (written < 0) { caml_stat_free(buf); raise_hexaly_error("Hexaly.collection_value (dump)"); }
    arr = caml_alloc(n, 0);
    for (int i = 0; i < n; ++i) Store_field(arr, i, Val_long((intnat)buf[i]));
    caml_stat_free(buf);
    CAMLreturn(arr);
}

CAMLprim value caml_hxs_solution_set_int_value(value v_s, value v_e, value v_n) {
    CAMLparam3(v_s, v_e, v_n);
    int rc = hxs_solution_set_int_value(sol_get(v_s), expr_get(v_e), (hxs_int)Long_val(v_n));
    if (rc != 0) raise_hexaly_error("Hexaly.set_int_value");
    CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_solution_set_float_value(value v_s, value v_e, value v_f) {
    CAMLparam3(v_s, v_e, v_f);
    int rc = hxs_solution_set_float_value(sol_get(v_s), expr_get(v_e), Double_val(v_f));
    if (rc != 0) raise_hexaly_error("Hexaly.set_float_value");
    CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_solution_set_interval_value(value v_s, value v_e, value v_st, value v_ed) {
    CAMLparam4(v_s, v_e, v_st, v_ed);
    int rc = hxs_solution_set_interval_value(sol_get(v_s), expr_get(v_e),
                                              (hxs_int)Long_val(v_st), (hxs_int)Long_val(v_ed));
    if (rc != 0) raise_hexaly_error("Hexaly.set_interval_value");
    CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_solution_clear(value v_s) {
    CAMLparam1(v_s); hxs_solution_clear(sol_get(v_s)); CAMLreturn(Val_unit);
}

/* ---------- Param ---------- */
CAMLprim value caml_hxs_param_set_time_limit(value v_p, value v_s) {
    CAMLparam2(v_p, v_s); hxs_param_set_time_limit(prm_get(v_p), Int_val(v_s)); CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_param_set_iteration_limit(value v_p, value v_n) {
    CAMLparam2(v_p, v_n); hxs_param_set_iteration_limit(prm_get(v_p), (long long)Int64_val(v_n)); CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_param_set_seed(value v_p, value v_s) {
    CAMLparam2(v_p, v_s); hxs_param_set_seed(prm_get(v_p), Int_val(v_s)); CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_param_set_nb_threads(value v_p, value v_n) {
    CAMLparam2(v_p, v_n); hxs_param_set_nb_threads(prm_get(v_p), Int_val(v_n)); CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_param_set_verbosity(value v_p, value v_l) {
    CAMLparam2(v_p, v_l); hxs_param_set_verbosity(prm_get(v_p), Int_val(v_l)); CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_param_set_warning_level(value v_p, value v_l) {
    CAMLparam2(v_p, v_l); hxs_param_set_warning_level(prm_get(v_p), Int_val(v_l)); CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_param_set_time_between_displays(value v_p, value v_s) {
    CAMLparam2(v_p, v_s); hxs_param_set_time_between_displays(prm_get(v_p), Int_val(v_s)); CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_param_set_time_between_ticks(value v_p, value v_s) {
    CAMLparam2(v_p, v_s); hxs_param_set_time_between_ticks(prm_get(v_p), Int_val(v_s)); CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_param_set_iteration_between_ticks(value v_p, value v_n) {
    CAMLparam2(v_p, v_n); hxs_param_set_iteration_between_ticks(prm_get(v_p), (long long)Int64_val(v_n)); CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_param_set_log_file(value v_p, value v_path) {
    CAMLparam2(v_p, v_path); hxs_param_set_log_file(prm_get(v_p), String_val(v_path)); CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_param_set_advanced_int(value v_p, value v_k, value v_n) {
    CAMLparam3(v_p, v_k, v_n);
    hxs_param_set_advanced_int(prm_get(v_p), String_val(v_k), Int_val(v_n));
    CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_param_set_advanced_double(value v_p, value v_k, value v_f) {
    CAMLparam3(v_p, v_k, v_f);
    hxs_param_set_advanced_double(prm_get(v_p), String_val(v_k), Double_val(v_f));
    CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_param_set_advanced_string(value v_p, value v_k, value v_s) {
    CAMLparam3(v_p, v_k, v_s);
    hxs_param_set_advanced_string(prm_get(v_p), String_val(v_k), String_val(v_s));
    CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_param_set_int_objective_threshold(value v_p, value v_i, value v_t) {
    CAMLparam3(v_p, v_i, v_t);
    hxs_param_set_int_objective_threshold(prm_get(v_p), Int_val(v_i), (hxs_int)Long_val(v_t));
    CAMLreturn(Val_unit);
}
CAMLprim value caml_hxs_param_set_double_objective_threshold(value v_p, value v_i, value v_t) {
    CAMLparam3(v_p, v_i, v_t);
    hxs_param_set_double_objective_threshold(prm_get(v_p), Int_val(v_i), Double_val(v_t));
    CAMLreturn(Val_unit);
}
