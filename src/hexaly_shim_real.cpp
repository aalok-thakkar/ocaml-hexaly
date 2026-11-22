/* hexaly_shim_real.cpp - extern "C" implementation over the Hexaly C++ API.
 *
 * All C++ exceptions are caught at the ABI boundary and converted into a
 * thread-local (error_code, message) pair plus a sentinel return value.
 * Letting a C++ exception escape into OCaml's runtime would corrupt the
 * stack — that's the one invariant this file must never violate.
 *
 * Callbacks: Hexaly invokes the registered HxCallback subclass on each event;
 * we forward to a user-supplied C function pointer + opaque userdata.
 * Lifetime: we OWN the HxCallback subclass instances (Hexaly stores raw
 * pointers); the optimizer wrapper tracks them in a vector and deletes them
 * in its destructor.
 */
#include "hexaly_shim.h"

#include "optimizer/hexalyoptimizer.h"

#include <cstring>
#include <fstream>
#include <memory>
#include <new>
#include <string>
#include <vector>

using namespace hexaly;

/* ---------- HxOperator / Error / State / Callback type sanity ---------- */
static_assert((int)HXS_O_BOOL     == (int)O_Bool,     "HxOperator drift: Bool");
static_assert((int)HXS_O_FLOAT    == (int)O_Float,    "HxOperator drift: Float");
static_assert((int)HXS_O_SUM      == (int)O_Sum,      "HxOperator drift: Sum");
static_assert((int)HXS_O_PROD     == (int)O_Prod,     "HxOperator drift: Prod");
static_assert((int)HXS_O_EQ       == (int)O_Eq,       "HxOperator drift: Eq");
static_assert((int)HXS_O_LT       == (int)O_Lt,       "HxOperator drift: Lt");
static_assert((int)HXS_O_IF       == (int)O_If,       "HxOperator drift: If");
static_assert((int)HXS_O_AND      == (int)O_And,      "HxOperator drift: And");
static_assert((int)HXS_O_ABS      == (int)O_Abs,      "HxOperator drift: Abs");
static_assert((int)HXS_O_MOD      == (int)O_Mod,      "HxOperator drift: Mod");
static_assert((int)HXS_O_TAN      == (int)O_Tan,      "HxOperator drift: Tan");
static_assert((int)HXS_O_INT      == (int)O_Int,      "HxOperator drift: Int (out-of-order)");
static_assert((int)HXS_O_LIST     == (int)O_List,     "HxOperator drift: List");
static_assert((int)HXS_O_INTERVAL == (int)O_Interval, "HxOperator drift: Interval");
static_assert((int)HXS_O_PRESENCE == (int)O_Presence, "HxOperator drift: Presence (tail)");

static_assert((int)HXS_EC_API      == (int)EC_Api,      "HxErrorCode drift: Api");
static_assert((int)HXS_EC_LICENSE  == (int)EC_License,  "HxErrorCode drift: License");
static_assert((int)HXS_EC_CLOUD    == (int)EC_Cloud,    "HxErrorCode drift: Cloud (tail)");

static_assert((int)HXS_STATE_MODELING == (int)S_Modeling, "HxState drift: Modeling");
static_assert((int)HXS_STATE_STOPPED  == (int)S_Stopped,  "HxState drift: Stopped");

static_assert((int)HXS_CT_PHASE_STARTED        == (int)CT_PhaseStarted,        "HxCallbackType drift: PhaseStarted");
static_assert((int)HXS_CT_TIME_TICKED          == (int)CT_TimeTicked,          "HxCallbackType drift: TimeTicked");
static_assert((int)HXS_CT_OPTIMIZATION_ENDED   == (int)CT_OptimizationEnded,   "HxCallbackType drift: OptimizationEnded (tail)");

/* ---------- Thread-local error slot ---------- */
namespace {
thread_local std::string    g_last_error;
thread_local hxs_error_code g_last_error_code = HXS_EC_INTERNAL;

void set_error(hxs_error_code code, const char* what) {
    g_last_error_code = code;
    g_last_error.assign(what ? what : "unknown error");
}
void clear_error() { g_last_error.clear(); }
} // namespace

extern "C" const char* hxs_last_error(void) {
    return g_last_error.empty() ? nullptr : g_last_error.c_str();
}
extern "C" hxs_error_code hxs_last_error_code(void) { return g_last_error_code; }
extern "C" void           hxs_clear_error(void)     { clear_error(); }

/* ---------- Forward decls ---------- */
struct hxs_callback;

/* ---------- Wrapper structs ---------- */
struct hxs_optimizer  {
    HexalyOptimizer impl;
    /* OWNED HxCallback subclasses we registered. Freed on optimizer destruction. */
    std::vector<std::unique_ptr<hxs_callback>> callbacks;
};
struct hxs_model      { HxModel       impl; explicit hxs_model(HxModel m) : impl(m) {} };
struct hxs_expression { HxExpression  impl; explicit hxs_expression(HxExpression e) : impl(e) {} };
struct hxs_solution   { HxSolution    impl; explicit hxs_solution(HxSolution s) : impl(s) {} };
struct hxs_param      { HxParam       impl; explicit hxs_param(HxParam p) : impl(p) {} };
struct hxs_inconsistency {
    HxInconsistency impl;
    explicit hxs_inconsistency(HxInconsistency i) : impl(i) {}
};
struct hxs_phase {
    HxPhase impl;
    explicit hxs_phase(HxPhase p) : impl(p) {}
};

/* HxCallback subclass that forwards to a user C function pointer.
 * Lifetime owned by hxs_optimizer::callbacks. Hexaly stores a raw pointer
 * to this object but does NOT free it. */
struct hxs_callback : public HxCallback {
    hxs_optimizer*    owner;
    hxs_callback_type type;
    hxs_callback_fn   fn;
    void*             userdata;

    hxs_callback(hxs_optimizer* o, hxs_callback_type t, hxs_callback_fn f, void* ud)
        : owner(o), type(t), fn(f), userdata(ud) {}

    void callback(HexalyOptimizer&, HxCallbackType t) override {
        /* If the user's fn throws, the dispatcher above us in Hexaly will
         * call hx_interrupt — but exception types must not cross C ABI, so
         * fn itself must NOT throw. Pure C contract. */
        if (fn) fn(owner, (hxs_callback_type)(int)t, userdata);
    }
};

/* Exception → thread-local conversion macros. */
#define HXS_TRY        try { clear_error();
#define HXS_CATCH_RET(retval)                                                \
    } catch (const HxException& ex) {                                        \
        set_error((hxs_error_code)(int)ex.getErrorCode(), ex.getExplanation().c_str()); \
        return retval;                                                       \
    } catch (const std::exception& ex) {                                     \
        set_error(HXS_EC_INTERNAL, ex.what()); return retval;                \
    } catch (...) {                                                          \
        set_error(HXS_EC_INTERNAL, "unknown C++ exception"); return retval;  \
    }
#define HXS_CATCH_VOID                                                       \
    } catch (const HxException& ex) {                                        \
        set_error((hxs_error_code)(int)ex.getErrorCode(), ex.getExplanation().c_str()); \
    } catch (const std::exception& ex) {                                     \
        set_error(HXS_EC_INTERNAL, ex.what());                               \
    } catch (...) {                                                          \
        set_error(HXS_EC_INTERNAL, "unknown C++ exception");                 \
    }

/* String-getter helper: copies a std::string into a user buffer with size
 * semantics matching every Hexaly-style toString. */
static int copy_string_out(const std::string& s, char* buf, int max_out) {
    int need = (int)s.size() + 1; /* include NUL */
    if (buf == nullptr || max_out <= 0) return need;
    int to_copy = (max_out - 1 < (int)s.size()) ? max_out - 1 : (int)s.size();
    std::memcpy(buf, s.data(), to_copy);
    buf[to_copy] = '\0';
    return need;
}

/* ---------- Version ---------- */
extern "C" int  hxs_backend_is_mock(void)    { return 0; }
extern "C" int  hxs_version_major(void)      { HXS_TRY return HxVersion::getMajorVersionNumber(); HXS_CATCH_RET(-1) }
extern "C" int  hxs_version_minor(void)      { HXS_TRY return HxVersion::getMinorVersionNumber(); HXS_CATCH_RET(-1) }
extern "C" int  hxs_version_code(void)       { HXS_TRY return HxVersion::getVersionCode();        HXS_CATCH_RET(-1) }
extern "C" int  hxs_version_build_date(void) { HXS_TRY return HxVersion::getBuildDate();          HXS_CATCH_RET(-1) }
extern "C" int  hxs_version_string  (char* buf, int max_out) { HXS_TRY return copy_string_out(HxVersion::getVersion(),     buf, max_out); HXS_CATCH_RET(-1) }
extern "C" int  hxs_version_platform(char* buf, int max_out) { HXS_TRY return copy_string_out(HxVersion::getPlatform(),    buf, max_out); HXS_CATCH_RET(-1) }
extern "C" int  hxs_version_info    (char* buf, int max_out) { HXS_TRY return copy_string_out(HxVersion::getInfo(),        buf, max_out); HXS_CATCH_RET(-1) }
extern "C" int  hxs_version_copyright(char* buf, int max_out){ HXS_TRY return copy_string_out(HxVersion::getCopyright(),   buf, max_out); HXS_CATCH_RET(-1) }
extern "C" int  hxs_version_license_path(char* buf, int max_out){ HXS_TRY return copy_string_out(HxVersion::getLicensePath(), buf, max_out); HXS_CATCH_RET(-1) }
extern "C" void hxs_version_set_license_path   (const char* p) { HXS_TRY HxVersion::setLicensePath   (p ? p : ""); HXS_CATCH_VOID }
extern "C" void hxs_version_set_license_content(const char* c) { HXS_TRY HxVersion::setLicenseContent(c ? c : ""); HXS_CATCH_VOID }

/* ---------- Optimizer ---------- */
extern "C" hxs_optimizer* hxs_optimizer_new(void) {
    HXS_TRY return new hxs_optimizer(); HXS_CATCH_RET(nullptr)
}
extern "C" void hxs_optimizer_free(hxs_optimizer* opt) {
    /* Hexaly destructor will be called before our vector clears. The order
     * matters: Hexaly may invoke a callback during shutdown? Unlikely, but
     * to be safe we drop the callbacks BEFORE Hexaly's HexalyOptimizer dtor
     * fires by explicitly clearing. Then delete the wrapper (which fires
     * the impl dtor). */
    if (opt) {
        opt->callbacks.clear();
        delete opt;
    }
}

extern "C" hxs_model* hxs_optimizer_get_model(hxs_optimizer* opt) {
    HXS_TRY return new hxs_model(opt->impl.getModel()); HXS_CATCH_RET(nullptr)
}
extern "C" hxs_param* hxs_optimizer_get_param(hxs_optimizer* opt) {
    HXS_TRY return new hxs_param(opt->impl.getParam()); HXS_CATCH_RET(nullptr)
}
extern "C" hxs_solution* hxs_optimizer_get_solution(hxs_optimizer* opt) {
    HXS_TRY return new hxs_solution(opt->impl.getSolution()); HXS_CATCH_RET(nullptr)
}
extern "C" int hxs_optimizer_solve(hxs_optimizer* opt) {
    HXS_TRY opt->impl.solve(); return 0; HXS_CATCH_RET(-1)
}
extern "C" void hxs_optimizer_stop(hxs_optimizer* opt) {
    HXS_TRY opt->impl.stop(); HXS_CATCH_VOID
}
extern "C" hxs_state hxs_optimizer_get_state(hxs_optimizer* opt) {
    HXS_TRY return (hxs_state)(int)opt->impl.getState(); HXS_CATCH_RET(HXS_STATE_STOPPED)
}
extern "C" int hxs_optimizer_running_time(hxs_optimizer* opt) {
    HXS_TRY return opt->impl.getStatistics().getRunningTime(); HXS_CATCH_RET(-1)
}
extern "C" long long hxs_optimizer_nb_iterations(hxs_optimizer* opt) {
    HXS_TRY return opt->impl.getStatistics().getNbIterations(); HXS_CATCH_RET(-1)
}
extern "C" int hxs_optimizer_save_environment(hxs_optimizer* opt, const char* path) {
    HXS_TRY opt->impl.saveEnvironment(path ? path : ""); return 0; HXS_CATCH_RET(-1)
}
extern "C" int hxs_optimizer_load_environment(hxs_optimizer* opt, const char* path) {
    HXS_TRY opt->impl.loadEnvironment(path ? path : ""); return 0; HXS_CATCH_RET(-1)
}

/* ---------- Phases ---------- */
extern "C" hxs_phase* hxs_optimizer_create_phase(hxs_optimizer* opt) {
    HXS_TRY return new hxs_phase(opt->impl.createPhase()); HXS_CATCH_RET(nullptr)
}
extern "C" hxs_phase* hxs_optimizer_get_phase(hxs_optimizer* opt, int idx) {
    HXS_TRY return new hxs_phase(opt->impl.getPhase(idx)); HXS_CATCH_RET(nullptr)
}
extern "C" int hxs_optimizer_nb_phases(hxs_optimizer* opt) {
    HXS_TRY return opt->impl.getNbPhases(); HXS_CATCH_RET(-1)
}
extern "C" void hxs_phase_set_time_limit(hxs_phase* p, int s)              { HXS_TRY p->impl.setTimeLimit(s); HXS_CATCH_VOID }
extern "C" int  hxs_phase_get_time_limit(hxs_phase* p)                     { HXS_TRY return p->impl.getTimeLimit(); HXS_CATCH_RET(-1) }
extern "C" void hxs_phase_set_iteration_limit(hxs_phase* p, long long n)   { HXS_TRY p->impl.setIterationLimit(n); HXS_CATCH_VOID }
extern "C" long long hxs_phase_get_iteration_limit(hxs_phase* p)           { HXS_TRY return p->impl.getIterationLimit(); HXS_CATCH_RET(-1) }
extern "C" void hxs_phase_set_optimized_objective(hxs_phase* p, int idx)   { HXS_TRY p->impl.setOptimizedObjective(idx); HXS_CATCH_VOID }
extern "C" int  hxs_phase_get_optimized_objective(hxs_phase* p)            { HXS_TRY return p->impl.getOptimizedObjective(); HXS_CATCH_RET(-1) }
extern "C" void hxs_phase_set_enabled(hxs_phase* p, int e)                 { HXS_TRY p->impl.setEnabled(e != 0); HXS_CATCH_VOID }
extern "C" int  hxs_phase_is_enabled(hxs_phase* p)                         { HXS_TRY return p->impl.isEnabled() ? 1 : 0; HXS_CATCH_RET(-1) }
extern "C" int  hxs_phase_to_string(hxs_phase* p, char* buf, int max_out)  { HXS_TRY return copy_string_out(p->impl.toString(), buf, max_out); HXS_CATCH_RET(-1) }
extern "C" void hxs_phase_free(hxs_phase* p) { delete p; }

/* ---------- Inconsistency ---------- */
extern "C" hxs_inconsistency* hxs_optimizer_compute_inconsistency(hxs_optimizer* opt) {
    HXS_TRY return new hxs_inconsistency(opt->impl.computeInconsistency()); HXS_CATCH_RET(nullptr)
}
extern "C" int hxs_inconsistency_nb_causes(hxs_inconsistency* i) {
    HXS_TRY return i->impl.getNbCauses(); HXS_CATCH_RET(-1)
}
extern "C" hxs_expression* hxs_inconsistency_cause(hxs_inconsistency* i, int idx) {
    HXS_TRY return new hxs_expression(i->impl.getCause(idx)); HXS_CATCH_RET(nullptr)
}
extern "C" int hxs_inconsistency_to_string(hxs_inconsistency* i, char* buf, int max_out) {
    HXS_TRY return copy_string_out(i->impl.toString(), buf, max_out); HXS_CATCH_RET(-1)
}
extern "C" void hxs_inconsistency_free(hxs_inconsistency* i) { delete i; }

/* ---------- Callbacks ---------- */
extern "C" hxs_callback* hxs_optimizer_add_callback(
    hxs_optimizer* opt, hxs_callback_type type,
    hxs_callback_fn fn, void* userdata)
{
    HXS_TRY
        auto cb = std::unique_ptr<hxs_callback>(new hxs_callback(opt, type, fn, userdata));
        hxs_callback* raw = cb.get();
        opt->impl.addCallback((HxCallbackType)(int)type, raw);
        opt->callbacks.push_back(std::move(cb));
        return raw;
    HXS_CATCH_RET(nullptr)
}

extern "C" int hxs_optimizer_remove_callback(hxs_optimizer* opt, hxs_callback* cb) {
    HXS_TRY
        bool removed = opt->impl.removeCallback((HxCallbackType)(int)cb->type, cb);
        if (!removed) return 0;
        for (auto it = opt->callbacks.begin(); it != opt->callbacks.end(); ++it) {
            if (it->get() == cb) { opt->callbacks.erase(it); break; }
        }
        return 1;
    HXS_CATCH_RET(0)
}

/* ---------- Model: decisions ---------- */
extern "C" hxs_expression* hxs_model_bool_var(hxs_model* m) {
    HXS_TRY return new hxs_expression(m->impl.boolVar()); HXS_CATCH_RET(nullptr)
}
extern "C" hxs_expression* hxs_model_int_var(hxs_model* m, hxs_int lo, hxs_int hi) {
    HXS_TRY return new hxs_expression(m->impl.intVar(lo, hi)); HXS_CATCH_RET(nullptr)
}
extern "C" hxs_expression* hxs_model_float_var(hxs_model* m, hxs_float lo, hxs_float hi) {
    HXS_TRY return new hxs_expression(m->impl.floatVar(lo, hi)); HXS_CATCH_RET(nullptr)
}
extern "C" hxs_expression* hxs_model_interval_var(hxs_model* m, hxs_int min_start, hxs_int max_end) {
    HXS_TRY return new hxs_expression(m->impl.intervalVar(min_start, max_end)); HXS_CATCH_RET(nullptr)
}
extern "C" hxs_expression* hxs_model_optional_interval_var(hxs_model* m, hxs_int min_start, hxs_int max_end) {
    HXS_TRY return new hxs_expression(m->impl.optionalIntervalVar(min_start, max_end)); HXS_CATCH_RET(nullptr)
}
extern "C" hxs_expression* hxs_model_list_var(hxs_model* m, hxs_int n) {
    HXS_TRY return new hxs_expression(m->impl.listVar(n)); HXS_CATCH_RET(nullptr)
}
extern "C" hxs_expression* hxs_model_set_var(hxs_model* m, hxs_int n) {
    HXS_TRY return new hxs_expression(m->impl.setVar(n)); HXS_CATCH_RET(nullptr)
}

/* ---------- Model: constants & arrays ---------- */
extern "C" hxs_expression* hxs_model_const_int(hxs_model* m, hxs_int v) {
    HXS_TRY return new hxs_expression(m->impl.createConstant((hxint)v)); HXS_CATCH_RET(nullptr)
}
extern "C" hxs_expression* hxs_model_const_float(hxs_model* m, hxs_float v) {
    HXS_TRY return new hxs_expression(m->impl.createConstant((hxdouble)v)); HXS_CATCH_RET(nullptr)
}
extern "C" hxs_expression* hxs_model_const_int_array(hxs_model* m, const hxs_int* vals, int n) {
    HXS_TRY
        std::vector<hxint> tmp(vals, vals + n);
        return new hxs_expression(m->impl.createConstArray(tmp.data(), n));
    HXS_CATCH_RET(nullptr)
}
extern "C" hxs_expression* hxs_model_const_float_array(hxs_model* m, const hxs_float* vals, int n) {
    HXS_TRY
        std::vector<hxdouble> tmp(vals, vals + n);
        return new hxs_expression(m->impl.createConstArray(tmp.data(), n));
    HXS_CATCH_RET(nullptr)
}

extern "C" hxs_expression* hxs_model_create_expression(
    hxs_model* m, hxs_operator op,
    hxs_expression** operands, int nb_operands,
    const hxs_int* int_consts, int nb_int_consts,
    const hxs_float* float_consts, int nb_float_consts)
{
    HXS_TRY
        HxExpression e = m->impl.createExpression((HxOperator)op);
        for (int i = 0; i < nb_operands; ++i)   e.addOperand(operands[i]->impl);
        for (int i = 0; i < nb_int_consts; ++i) e.addOperand((hxint)int_consts[i]);
        for (int i = 0; i < nb_float_consts; ++i) e.addOperand((hxdouble)float_consts[i]);
        return new hxs_expression(e);
    HXS_CATCH_RET(nullptr)
}

/* ---------- Model: constraints/objectives/state ---------- */
extern "C" void hxs_model_add_constraint(hxs_model* m, hxs_expression* e) { HXS_TRY m->impl.addConstraint(e->impl); HXS_CATCH_VOID }
extern "C" void hxs_model_minimize(hxs_model* m, hxs_expression* e)       { HXS_TRY m->impl.minimize(e->impl);       HXS_CATCH_VOID }
extern "C" void hxs_model_maximize(hxs_model* m, hxs_expression* e)       { HXS_TRY m->impl.maximize(e->impl);       HXS_CATCH_VOID }
extern "C" void hxs_model_close(hxs_model* m)                              { HXS_TRY m->impl.close();                  HXS_CATCH_VOID }
extern "C" int  hxs_model_is_closed(hxs_model* m) { HXS_TRY return m->impl.isClosed() ? 1 : 0; HXS_CATCH_RET(-1) }

extern "C" int hxs_model_nb_expressions(hxs_model* m) { HXS_TRY return m->impl.getNbExpressions(); HXS_CATCH_RET(-1) }
extern "C" int hxs_model_nb_constraints(hxs_model* m) { HXS_TRY return m->impl.getNbConstraints(); HXS_CATCH_RET(-1) }
extern "C" int hxs_model_nb_objectives (hxs_model* m) { HXS_TRY return m->impl.getNbObjectives();  HXS_CATCH_RET(-1) }
extern "C" int hxs_model_nb_decisions  (hxs_model* m) { HXS_TRY return m->impl.getNbDecisions();   HXS_CATCH_RET(-1) }

/* ---------- Solution ---------- */
extern "C" hxs_int hxs_solution_int_value(hxs_solution* s, hxs_expression* e) {
    HXS_TRY return (hxs_int)s->impl.getIntValue(e->impl); HXS_CATCH_RET(0)
}
extern "C" hxs_float hxs_solution_float_value(hxs_solution* s, hxs_expression* e) {
    HXS_TRY return (hxs_float)s->impl.getDoubleValue(e->impl); HXS_CATCH_RET(0.0)
}
extern "C" hxs_solution_status hxs_solution_get_status(hxs_solution* s) {
    HXS_TRY return (hxs_solution_status)(int)s->impl.getStatus(); HXS_CATCH_RET(HXS_STATUS_INCONSISTENT)
}
extern "C" int hxs_solution_is_violated(hxs_solution* s, hxs_expression* e) {
    HXS_TRY return s->impl.isViolated(e->impl) ? 1 : 0; HXS_CATCH_RET(-1)
}
extern "C" int hxs_solution_is_undefined(hxs_solution* s, hxs_expression* e) {
    HXS_TRY return s->impl.isUndefined(e->impl) ? 1 : 0; HXS_CATCH_RET(-1)
}
extern "C" int hxs_solution_interval_value(hxs_solution* s, hxs_expression* e,
                                            hxs_int* out_start, hxs_int* out_end) {
    HXS_TRY
        HxInterval iv = s->impl.getIntervalValue(e->impl);
        if (iv.isVoid()) { *out_start = 0; *out_end = -1; return 0; }
        *out_start = (hxs_int)iv.getStart();
        *out_end   = (hxs_int)iv.getEnd();
        return 0;
    HXS_CATCH_RET(-1)
}
extern "C" int hxs_solution_collection_size(hxs_solution* s, hxs_expression* e) {
    HXS_TRY return s->impl.getCollectionValue(e->impl).count(); HXS_CATCH_RET(-1)
}
extern "C" int hxs_solution_collection_dump(hxs_solution* s, hxs_expression* e,
                                             hxs_int* out_buf, int max_out) {
    HXS_TRY
        HxCollection col = s->impl.getCollectionValue(e->impl);
        int n = col.count();
        int copy = (max_out < n) ? max_out : n;
        for (int i = 0; i < copy; ++i) out_buf[i] = (hxs_int)col.get(i);
        return n;
    HXS_CATCH_RET(-1)
}

extern "C" int hxs_solution_set_int_value(hxs_solution* s, hxs_expression* e, hxs_int v) {
    HXS_TRY s->impl.setIntValue(e->impl, (hxint)v); return 0; HXS_CATCH_RET(-1)
}
extern "C" int hxs_solution_set_float_value(hxs_solution* s, hxs_expression* e, hxs_float v) {
    HXS_TRY s->impl.setDoubleValue(e->impl, (hxdouble)v); return 0; HXS_CATCH_RET(-1)
}
extern "C" int hxs_solution_set_interval_value(hxs_solution* s, hxs_expression* e, hxs_int st, hxs_int ed) {
    HXS_TRY s->impl.setIntervalValue(e->impl, HxInterval((hxint)st, (hxint)ed)); return 0; HXS_CATCH_RET(-1)
}
extern "C" void hxs_solution_clear(hxs_solution* s) { HXS_TRY s->impl.clear(); HXS_CATCH_VOID }

/* ---------- Param ---------- */
extern "C" void hxs_param_set_time_limit(hxs_param* p, int seconds)              { HXS_TRY p->impl.setTimeLimit(seconds);            HXS_CATCH_VOID }
extern "C" void hxs_param_set_iteration_limit(hxs_param* p, long long iters)     { HXS_TRY p->impl.setIterationLimit(iters);         HXS_CATCH_VOID }
extern "C" void hxs_param_set_seed(hxs_param* p, int seed)                       { HXS_TRY p->impl.setSeed(seed);                    HXS_CATCH_VOID }
extern "C" void hxs_param_set_nb_threads(hxs_param* p, int n)                    { HXS_TRY p->impl.setNbThreads(n);                  HXS_CATCH_VOID }
extern "C" void hxs_param_set_verbosity(hxs_param* p, int level)                 { HXS_TRY p->impl.setVerbosity(level);              HXS_CATCH_VOID }
extern "C" void hxs_param_set_warning_level(hxs_param* p, int level)             { HXS_TRY p->impl.setWarningLevel(level);           HXS_CATCH_VOID }
extern "C" void hxs_param_set_time_between_displays(hxs_param* p, int seconds)   { HXS_TRY p->impl.setTimeBetweenDisplays(seconds);  HXS_CATCH_VOID }
extern "C" void hxs_param_set_time_between_ticks(hxs_param* p, int seconds)      { HXS_TRY p->impl.setTimeBetweenTicks(seconds);     HXS_CATCH_VOID }
extern "C" void hxs_param_set_iteration_between_ticks(hxs_param* p, long long n) { HXS_TRY p->impl.setIterationBetweenTicks(n);      HXS_CATCH_VOID }
extern "C" void hxs_param_set_log_file(hxs_param* p, const char* path)           { HXS_TRY p->impl.setLogFile(path ? path : "");     HXS_CATCH_VOID }
extern "C" void hxs_param_set_advanced_int   (hxs_param* p, const char* k, int v)        { HXS_TRY p->impl.setAdvancedParam(k ? k : "", v); HXS_CATCH_VOID }
extern "C" void hxs_param_set_advanced_double(hxs_param* p, const char* k, double v)     { HXS_TRY p->impl.setAdvancedParam(k ? k : "", v); HXS_CATCH_VOID }
extern "C" void hxs_param_set_advanced_string(hxs_param* p, const char* k, const char* v){ HXS_TRY p->impl.setAdvancedParam(k ? k : "", std::string(v ? v : "")); HXS_CATCH_VOID }
extern "C" void hxs_param_set_int_objective_threshold(hxs_param* p, int i, hxs_int t)    { HXS_TRY p->impl.setIntObjectiveThreshold(i, (hxint)t);    HXS_CATCH_VOID }
extern "C" void hxs_param_set_double_objective_threshold(hxs_param* p, int i, hxs_float t){ HXS_TRY p->impl.setDoubleObjectiveThreshold(i, (hxdouble)t); HXS_CATCH_VOID }

/* Wrapper destructors. */
extern "C" void hxs_model_free     (hxs_model* m)      { delete m; }
extern "C" void hxs_expression_free(hxs_expression* e) { delete e; }
extern "C" void hxs_solution_free  (hxs_solution* s)   { delete s; }
extern "C" void hxs_param_free     (hxs_param* p)      { delete p; }
