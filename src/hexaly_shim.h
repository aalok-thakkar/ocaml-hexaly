/* hexaly_shim.h - extern "C" surface over the Hexaly C++ API.
 *
 * Design:
 *   - Handles (HxsOptimizer, HxsModel, HxsExpression, HxsSolution, HxsParam,
 *     HxsInconsistency, HxsCallback) are opaque pointers. The optimizer
 *     owns everything else; freeing it invalidates derived handles.
 *     OCaml enforces this by holding the parent in each derived wrapper
 *     record (see hexaly.ml).
 *   - Errors are reported by returning NULL or a sentinel return, plus a
 *     thread-local (code, string) pair accessible via hxs_last_error*().
 *     The real-backend shim catches HxException and extracts the errorCode;
 *     other C++ exceptions are tagged HXS_EC_INTERNAL.
 *   - createExpression is batched: one FFI call takes an array of operand
 *     handles + int/float-const arrays, so building a sum of N variables
 *     crosses FFI once, not N+1 times.
 *   - Callbacks: the user supplies a C function pointer + opaque userdata.
 *     The shim wraps these in a C++ HxCallback subclass; on each event the
 *     subclass invokes the function pointer. The OCaml C stubs use this to
 *     dispatch to OCaml closures (see hexaly_stubs.c).
 */
#ifndef HEXALY_SHIM_H
#define HEXALY_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int64_t hxs_int;
typedef double  hxs_float;

typedef struct hxs_optimizer     hxs_optimizer;
typedef struct hxs_model         hxs_model;
typedef struct hxs_expression    hxs_expression;
typedef struct hxs_solution      hxs_solution;
typedef struct hxs_param         hxs_param;
typedef struct hxs_inconsistency hxs_inconsistency;
typedef struct hxs_callback      hxs_callback;
typedef struct hxs_phase         hxs_phase;

/* Mirror of hexaly::HxOperator from include/optimizer/hxoperator.h.
 * MUST match HxOperator's declaration order exactly. Verified at compile
 * time by static_asserts in hexaly_shim_real.cpp. */
typedef enum {
    HXS_O_BOOL = 0,
    HXS_O_FLOAT, HXS_O_CONST, HXS_O_SUM, HXS_O_SUB, HXS_O_PROD, HXS_O_MAX,
    HXS_O_MIN, HXS_O_EQ, HXS_O_NEQ, HXS_O_GEQ, HXS_O_LEQ, HXS_O_GT, HXS_O_LT,
    HXS_O_IF, HXS_O_NOT, HXS_O_AND, HXS_O_OR, HXS_O_XOR, HXS_O_ABS, HXS_O_DIST,
    HXS_O_DIV, HXS_O_MOD, HXS_O_ARRAY, HXS_O_AT, HXS_O_SCALAR, HXS_O_CEIL,
    HXS_O_FLOOR, HXS_O_ROUND, HXS_O_SQRT, HXS_O_LOG, HXS_O_EXP, HXS_O_POW,
    HXS_O_COS, HXS_O_SIN, HXS_O_TAN, HXS_O_INT, HXS_O_PIECEWISE, HXS_O_LIST,
    HXS_O_COUNT, HXS_O_INDEX_OF, HXS_O_PARTITION, HXS_O_DISJOINT,
    HXS_O_EXTERNAL_FUNCTION, HXS_O_CALL, HXS_O_LAMBDA_FUNCTION, HXS_O_ARGUMENT,
    HXS_O_RANGE, HXS_O_CONTAINS, HXS_O_SET, HXS_O_DEPRECATED, HXS_O_COVER,
    HXS_O_FIND, HXS_O_SORT, HXS_O_INTERVAL, HXS_O_START, HXS_O_END,
    HXS_O_LENGTH, HXS_O_DISTINCT, HXS_O_INTERSECTION, HXS_O_HULL,
    HXS_O_STEP_ARRAY, HXS_O_CONST_ARRAY, HXS_O_UNION, HXS_O_OPTIONAL_INTERVAL,
    HXS_O_PRESENCE
} hxs_operator;

/* Mirror of hexaly::HxErrorCode. */
typedef enum {
    HXS_EC_API = 0, HXS_EC_FILE, HXS_EC_MODEL, HXS_EC_CALLBACK,
    HXS_EC_LICENSE, HXS_EC_SOLVER, HXS_EC_INTERNAL, HXS_EC_MODELER, HXS_EC_CLOUD
} hxs_error_code;

typedef enum { HXS_MINIMIZE = 0, HXS_MAXIMIZE = 1 } hxs_objective_direction;
typedef enum {
    HXS_STATUS_INCONSISTENT = 0, HXS_STATUS_INFEASIBLE = 1,
    HXS_STATUS_FEASIBLE = 2,     HXS_STATUS_OPTIMAL = 3
} hxs_solution_status;

/* Mirror of hexaly::HxState. */
typedef enum {
    HXS_STATE_MODELING = 0, HXS_STATE_RUNNING, HXS_STATE_PAUSED, HXS_STATE_STOPPED
} hxs_state;

/* Mirror of hexaly::HxCallbackType. */
typedef enum {
    HXS_CT_PHASE_STARTED = 0,
    HXS_CT_PHASE_ENDED,
    HXS_CT_DISPLAY,
    HXS_CT_TIME_TICKED,
    HXS_CT_ITERATION_TICKED,
    HXS_CT_OPTIMIZATION_STARTED,
    HXS_CT_OPTIMIZATION_ENDED
} hxs_callback_type;

/* ---------- Error handling (thread-local) ---------- */
const char*    hxs_last_error(void);
hxs_error_code hxs_last_error_code(void);
void           hxs_clear_error(void);

/* ---------- Version / globals (static accessors on HxVersion) ---------- */
/* 1 if this build links the bundled mock instead of libhexaly, else 0. */
int  hxs_backend_is_mock(void);

int  hxs_version_major(void);
int  hxs_version_minor(void);
int  hxs_version_code(void);
int  hxs_version_build_date(void);
/* Each string getter writes up to max_out bytes into buf (null-terminated if
 * room) and returns the required size including terminator. Pass buf=NULL,
 * max_out=0 to query size. */
int  hxs_version_string  (char* buf, int max_out);
int  hxs_version_platform(char* buf, int max_out);
int  hxs_version_info    (char* buf, int max_out);
int  hxs_version_copyright(char* buf, int max_out);
int  hxs_version_license_path(char* buf, int max_out);
void hxs_version_set_license_path(const char* path);
void hxs_version_set_license_content(const char* content);

/* ---------- Optimizer ---------- */
hxs_optimizer* hxs_optimizer_new(void);
void           hxs_optimizer_free(hxs_optimizer* opt);
hxs_model*     hxs_optimizer_get_model(hxs_optimizer* opt);
hxs_param*     hxs_optimizer_get_param(hxs_optimizer* opt);
hxs_solution*  hxs_optimizer_get_solution(hxs_optimizer* opt);
int            hxs_optimizer_solve(hxs_optimizer* opt);
void           hxs_optimizer_stop(hxs_optimizer* opt);
hxs_state      hxs_optimizer_get_state(hxs_optimizer* opt);
int            hxs_optimizer_running_time(hxs_optimizer* opt);
long long      hxs_optimizer_nb_iterations(hxs_optimizer* opt);

/* Save/load Hexaly environment (.hxe). Returns 0 on success, -1 on error. */
int hxs_optimizer_save_environment(hxs_optimizer* opt, const char* path);
int hxs_optimizer_load_environment(hxs_optimizer* opt, const char* path);

/* ---------- Multi-objective phases ---------- */
/* Hexaly supports lexicographic multi-objective optimization. Declare
 * multiple objectives via minimize/maximize, then create one Phase per
 * objective. Each Phase has its own time/iteration limit and selects
 * which objective is active in that phase. */
hxs_phase* hxs_optimizer_create_phase(hxs_optimizer* opt);
hxs_phase* hxs_optimizer_get_phase   (hxs_optimizer* opt, int idx);
int        hxs_optimizer_nb_phases   (hxs_optimizer* opt);

void      hxs_phase_set_time_limit          (hxs_phase* p, int seconds);
int       hxs_phase_get_time_limit          (hxs_phase* p);
void      hxs_phase_set_iteration_limit     (hxs_phase* p, long long iters);
long long hxs_phase_get_iteration_limit     (hxs_phase* p);
void      hxs_phase_set_optimized_objective (hxs_phase* p, int idx);
int       hxs_phase_get_optimized_objective (hxs_phase* p);
void      hxs_phase_set_enabled             (hxs_phase* p, int enabled);
int       hxs_phase_is_enabled              (hxs_phase* p);
int       hxs_phase_to_string               (hxs_phase* p, char* buf, int max_out);
void      hxs_phase_free                    (hxs_phase* p);

/* ---------- Inconsistency analysis (IIS) ---------- */
/* computeInconsistency returns an inconsistency handle if available.
 * Callers must free with hxs_inconsistency_free. */
hxs_inconsistency* hxs_optimizer_compute_inconsistency(hxs_optimizer* opt);
int                hxs_inconsistency_nb_causes        (hxs_inconsistency* i);
hxs_expression*    hxs_inconsistency_cause            (hxs_inconsistency* i, int idx);
int                hxs_inconsistency_to_string        (hxs_inconsistency* i, char* buf, int max_out);
void               hxs_inconsistency_free             (hxs_inconsistency* i);

/* ---------- Callbacks ---------- */
/* The user supplies a C function pointer + opaque userdata. On each event of
 * the registered type, the shim invokes (*fn)(opt, type, userdata). The shim
 * retains the wrapper until the optimizer is freed or remove_callback is
 * called. */
typedef void (*hxs_callback_fn)(hxs_optimizer* opt, hxs_callback_type type, void* userdata);

hxs_callback* hxs_optimizer_add_callback(
    hxs_optimizer* opt, hxs_callback_type type,
    hxs_callback_fn fn, void* userdata);

/* Removes a previously registered callback. Returns 1 if removed, 0 if not
 * found. Does NOT free the userdata — callers do that. */
int hxs_optimizer_remove_callback(hxs_optimizer* opt, hxs_callback* cb);

/* ---------- Model: decisions ---------- */
hxs_expression* hxs_model_bool_var          (hxs_model* m);
hxs_expression* hxs_model_int_var           (hxs_model* m, hxs_int lo, hxs_int hi);
hxs_expression* hxs_model_float_var         (hxs_model* m, hxs_float lo, hxs_float hi);
hxs_expression* hxs_model_interval_var      (hxs_model* m, hxs_int min_start, hxs_int max_end);
hxs_expression* hxs_model_optional_interval_var(hxs_model* m, hxs_int min_start, hxs_int max_end);
hxs_expression* hxs_model_list_var          (hxs_model* m, hxs_int n);
hxs_expression* hxs_model_set_var           (hxs_model* m, hxs_int n);

/* ---------- Model: constants & arrays ---------- */
hxs_expression* hxs_model_const_int     (hxs_model* m, hxs_int v);
hxs_expression* hxs_model_const_float   (hxs_model* m, hxs_float v);
hxs_expression* hxs_model_const_int_array  (hxs_model* m, const hxs_int* vals,  int n);
hxs_expression* hxs_model_const_float_array(hxs_model* m, const hxs_float* vals, int n);

/* Batched create_expression. */
hxs_expression* hxs_model_create_expression(
    hxs_model* m,
    hxs_operator op,
    hxs_expression** operands, int nb_operands,
    const hxs_int* int_consts, int nb_int_consts,
    const hxs_float* float_consts, int nb_float_consts);

/* ---------- Model: constraints, objectives, state ---------- */
void hxs_model_add_constraint(hxs_model* m, hxs_expression* e);
void hxs_model_minimize      (hxs_model* m, hxs_expression* e);
void hxs_model_maximize      (hxs_model* m, hxs_expression* e);
void hxs_model_close         (hxs_model* m);
int  hxs_model_is_closed     (hxs_model* m);

int  hxs_model_nb_expressions(hxs_model* m);
int  hxs_model_nb_constraints(hxs_model* m);
int  hxs_model_nb_objectives (hxs_model* m);
int  hxs_model_nb_decisions  (hxs_model* m);

/* ---------- Solution ---------- */
hxs_int             hxs_solution_int_value   (hxs_solution* s, hxs_expression* e);
hxs_float           hxs_solution_float_value (hxs_solution* s, hxs_expression* e);
hxs_solution_status hxs_solution_get_status  (hxs_solution* s);
int                 hxs_solution_is_violated (hxs_solution* s, hxs_expression* e);
int                 hxs_solution_is_undefined(hxs_solution* s, hxs_expression* e);

/* Interval / collection readback. */
int hxs_solution_interval_value(hxs_solution* s, hxs_expression* e,
                                hxs_int* out_start, hxs_int* out_end);
int hxs_solution_collection_size(hxs_solution* s, hxs_expression* e);
int hxs_solution_collection_dump(hxs_solution* s, hxs_expression* e,
                                 hxs_int* out_buf, int max_out);

/* Warm start: set values BEFORE solve to provide a hint. */
int hxs_solution_set_int_value     (hxs_solution* s, hxs_expression* e, hxs_int v);
int hxs_solution_set_float_value   (hxs_solution* s, hxs_expression* e, hxs_float v);
int hxs_solution_set_interval_value(hxs_solution* s, hxs_expression* e, hxs_int st, hxs_int ed);
void hxs_solution_clear            (hxs_solution* s);

/* ---------- Param ---------- */
void hxs_param_set_time_limit     (hxs_param* p, int seconds);
void hxs_param_set_iteration_limit(hxs_param* p, long long iters);
void hxs_param_set_seed           (hxs_param* p, int seed);
void hxs_param_set_nb_threads     (hxs_param* p, int n);
void hxs_param_set_verbosity      (hxs_param* p, int level);
void hxs_param_set_warning_level  (hxs_param* p, int level);
void hxs_param_set_time_between_displays(hxs_param* p, int seconds);
void hxs_param_set_time_between_ticks   (hxs_param* p, int seconds);
void hxs_param_set_iteration_between_ticks(hxs_param* p, long long iters);
void hxs_param_set_log_file       (hxs_param* p, const char* path);
/* Advanced parameters by name (Hexaly exposes many tuning knobs via attrs).
 * For unknown keys these are no-ops (Hexaly silently ignores). */
void hxs_param_set_advanced_int   (hxs_param* p, const char* key, int v);
void hxs_param_set_advanced_double(hxs_param* p, const char* key, double v);
void hxs_param_set_advanced_string(hxs_param* p, const char* key, const char* v);
/* Objective thresholds (stop when one objective reaches threshold). */
void hxs_param_set_int_objective_threshold   (hxs_param* p, int obj_index, hxs_int threshold);
void hxs_param_set_double_objective_threshold(hxs_param* p, int obj_index, hxs_float threshold);

/* ---------- Wrapper-struct destructors ---------- */
void hxs_model_free     (hxs_model* m);
void hxs_expression_free(hxs_expression* e);
void hxs_solution_free  (hxs_solution* s);
void hxs_param_free     (hxs_param* p);

#ifdef __cplusplus
}
#endif

#endif /* HEXALY_SHIM_H */
