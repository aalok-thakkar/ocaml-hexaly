/* hexaly_shim_mock.cpp - self-contained mock implementing hexaly_shim.h.
 *
 * Purpose: exercise the OCaml binding without a Hexaly install. Implements
 * a small in-memory expression tree + brute-force solver (≤ 2^20
 * assignments). Faithful enough for binding tests; not a real solver.
 *
 * Behavioral coverage vs real Hexaly:
 *   - Real: bool, int decisions; arithmetic; comparison; boolean;
 *     close-state enforcement; typed errors.
 *   - Approximated: interval (point at min_start), list/set (identity 0..n-1).
 *   - Callbacks: fires OptimizationStarted / OptimizationEnded around solve().
 *   - IIS: returns nb_causes = number of constraints (overapproximation).
 *   - save/load environment: writes JSON-ish metadata, reads it back.
 *   - Warm start: stored but ignored (mock always brute-forces).
 *
 * Real correctness tests should use the real backend.
 */
#include "hexaly_shim.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <limits>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace {

thread_local std::string    g_last_error;
thread_local hxs_error_code g_last_error_code = HXS_EC_INTERNAL;

void set_error(hxs_error_code code, const char* s) {
    g_last_error_code = code;
    g_last_error = s ? s : "unknown error";
}
void clear_error() { g_last_error.clear(); }

constexpr uint64_t SOLVE_CAP = 1ULL << 20;

struct Decision {
    enum Kind { Bool, Int, Float, Interval, List, Set } kind;
    int64_t lo = 0, hi = 0;
    double  flo = 0.0, fhi = 0.0;
    int64_t n = 0;
};

struct Expr {
    enum Kind { DecisionRef, IntConst, FloatConst, OpNode };
    Kind kind = OpNode;
    int  op   = 0;
    int  decision_idx = -1;
    int64_t int_const = 0;
    double  float_const = 0.0;
    std::vector<Expr*> operands;
    std::vector<int64_t> int_consts;
    std::vector<double>  float_consts;
};

struct Model {
    std::vector<std::unique_ptr<Expr>> all_exprs;
    std::vector<Decision> decisions;
    std::vector<Expr*> decision_exprs;
    std::vector<Expr*> constraints;
    std::vector<std::pair<Expr*, int>> objectives;
    bool closed = false;
    bool   solved = false;
    int    status = HXS_STATUS_INFEASIBLE;
    std::vector<int64_t> assignment;
    std::vector<int64_t> interval_ends;
    std::vector<std::vector<int64_t>> collections;
    /* User-set warm-start values, keyed by decision_idx. */
    std::vector<std::pair<int, int64_t>>  hint_ints;
    std::vector<std::pair<int, double>>   hint_floats;
    std::vector<std::tuple<int,int64_t,int64_t>> hint_intervals;
    Expr* new_expr() {
        all_exprs.emplace_back(std::make_unique<Expr>());
        return all_exprs.back().get();
    }
};

struct Param {
    int       time_limit = 0;
    long long iter_limit = 0;
    int       seed = 0;
    int       nb_threads = 1;
    int       verbosity = 1;
    int       warning_level = 0;
    int       time_between_displays = 1;
    int       time_between_ticks = 1;
    long long iteration_between_ticks = 10000;
    std::string log_file;
    std::vector<std::pair<int, int64_t>>  int_obj_thresholds;
    std::vector<std::pair<int, double>>   dbl_obj_thresholds;
    /* Advanced params silently accepted, stored, never used. */
    std::vector<std::pair<std::string,int>>         adv_int;
    std::vector<std::pair<std::string,double>>      adv_dbl;
    std::vector<std::pair<std::string,std::string>> adv_str;
};

struct CallbackRecord {
    hxs_callback_type type;
    hxs_callback_fn   fn;
    void*             userdata;
};

struct OptimizerImpl {
    Model     model;
    Param     param;
    hxs_state state = HXS_STATE_MODELING;
    int       running_time = 0;
    long long iters = 0;
    std::vector<CallbackRecord> callbacks;
};

} // anonymous namespace

struct PhaseData {
    int       time_limit = 0;
    long long iter_limit = 0;
    int       optimized_obj = 0;
    bool      enabled = true;
};

struct hxs_optimizer     { OptimizerImpl impl; std::vector<PhaseData> phases; };
struct hxs_model         { Model* m; };
struct hxs_expression    { Expr* e; Model* owner; };
struct hxs_solution      { Model* m; };
struct hxs_param         { Param* p; };
struct hxs_inconsistency { Model* m; };
struct hxs_callback      { hxs_optimizer* owner; size_t index; };
struct hxs_phase         { hxs_optimizer* owner; size_t index; };

namespace {

double eval_float(const Expr* e, const std::vector<int64_t>& a);

int64_t eval_int(const Expr* e, const std::vector<int64_t>& a) {
    switch (e->kind) {
    case Expr::DecisionRef: return a[e->decision_idx];
    case Expr::IntConst:    return e->int_const;
    case Expr::FloatConst:  return (int64_t)e->float_const;
    case Expr::OpNode: break;
    }
    auto get = [&](size_t i) -> int64_t {
        if (i < e->operands.size()) return eval_int(e->operands[i], a);
        i -= e->operands.size();
        if (i < e->int_consts.size()) return e->int_consts[i];
        return (int64_t)e->float_consts[i - e->int_consts.size()];
    };
    size_t total = e->operands.size() + e->int_consts.size() + e->float_consts.size();
    switch (e->op) {
    case HXS_O_SUM:  { int64_t s=0; for (size_t i=0;i<total;++i) s+=get(i); return s; }
    case HXS_O_PROD: { int64_t p=1; for (size_t i=0;i<total;++i) p*=get(i); return p; }
    case HXS_O_SUB:  return get(0) - get(1);
    case HXS_O_DIV:  { int64_t d=get(1); return d?get(0)/d:0; }
    case HXS_O_MOD:  { int64_t d=get(1); return d?get(0)%d:0; }
    case HXS_O_ABS:  { int64_t v=get(0); return v<0?-v:v; }
    case HXS_O_DIST: { int64_t d=get(0)-get(1); return d<0?-d:d; }
    case HXS_O_MAX:  { int64_t v=std::numeric_limits<int64_t>::min(); for (size_t i=0;i<total;++i) v=std::max(v,get(i)); return v; }
    case HXS_O_MIN:  { int64_t v=std::numeric_limits<int64_t>::max(); for (size_t i=0;i<total;++i) v=std::min(v,get(i)); return v; }
    case HXS_O_EQ:   return get(0)==get(1)?1:0;
    case HXS_O_NEQ:  return get(0)!=get(1)?1:0;
    case HXS_O_LT:   return get(0)< get(1)?1:0;
    case HXS_O_LEQ:  return get(0)<=get(1)?1:0;
    case HXS_O_GT:   return get(0)> get(1)?1:0;
    case HXS_O_GEQ:  return get(0)>=get(1)?1:0;
    case HXS_O_AND:  { for (size_t i=0;i<total;++i) if (!get(i)) return 0; return 1; }
    case HXS_O_OR:   { for (size_t i=0;i<total;++i) if ( get(i)) return 1; return 0; }
    case HXS_O_NOT:  return get(0)?0:1;
    case HXS_O_XOR:  { int p=0; for (size_t i=0;i<total;++i) p^=(get(i)?1:0); return p; }
    case HXS_O_IF:   return get(0)?get(1):get(2);
    /* Math + collection ops: mock doesn't model these meaningfully.
     * Return a benign 0 so brute force terminates instead of recursing
     * forever (the earlier default delegated to eval_float which delegated
     * back to eval_int — a stack overflow). */
    default:         return 0;
    }
}
double eval_float(const Expr* e, const std::vector<int64_t>& a) {
    return (double)eval_int(e, a);
}

void fire_callback(hxs_optimizer* opt, hxs_callback_type t) {
    /* Copy index list first — handler might add/remove callbacks. */
    auto snap = opt->impl.callbacks;
    for (auto& cb : snap) if (cb.type == t && cb.fn) cb.fn(opt, t, cb.userdata);
}

void solve(hxs_optimizer* opt) {
    Model& m = opt->impl.model;
    m.solved = false;
    m.status = HXS_STATUS_INCONSISTENT;
    m.interval_ends.assign(m.decisions.size(), 0);
    m.collections.assign(m.decisions.size(), {});

    opt->impl.state = HXS_STATE_RUNNING;
    fire_callback(opt, HXS_CT_OPTIMIZATION_STARTED);

    if (m.decisions.empty()) {
        m.assignment.clear();
        m.solved = true;
        m.status = HXS_STATUS_OPTIMAL;
        opt->impl.state = HXS_STATE_STOPPED;
        fire_callback(opt, HXS_CT_OPTIMIZATION_ENDED);
        return;
    }
    std::vector<int64_t> domain_size(m.decisions.size());
    uint64_t total = 1;
    for (size_t i = 0; i < m.decisions.size(); ++i) {
        const Decision& d = m.decisions[i];
        switch (d.kind) {
        case Decision::Bool:     domain_size[i] = 2; break;
        case Decision::Int:      domain_size[i] = (d.hi - d.lo + 1); break;
        case Decision::Float:    domain_size[i] = 1; break;
        case Decision::Interval: domain_size[i] = 1; break;
        case Decision::List:
        case Decision::Set:      domain_size[i] = 1; break;
        }
        if (domain_size[i] <= 0) {
            m.status = HXS_STATUS_INFEASIBLE;
            opt->impl.state = HXS_STATE_STOPPED;
            fire_callback(opt, HXS_CT_OPTIMIZATION_ENDED);
            return;
        }
        if ((uint64_t)domain_size[i] > SOLVE_CAP ||
            total > SOLVE_CAP / (uint64_t)domain_size[i]) {
            set_error(HXS_EC_SOLVER, "mock: search space exceeds 2^20 — use real Hexaly");
            m.status = HXS_STATUS_INFEASIBLE;
            opt->impl.state = HXS_STATE_STOPPED;
            fire_callback(opt, HXS_CT_OPTIMIZATION_ENDED);
            return;
        }
        total *= (uint64_t)domain_size[i];
    }

    std::vector<int64_t> cur(m.decisions.size());
    std::vector<int64_t> best;
    bool have_best = false;
    int64_t best_obj = 0;
    bool maximize = !m.objectives.empty() && m.objectives[0].second == 1;

    for (uint64_t k = 0; k < total; ++k) {
        uint64_t r = k;
        for (size_t i = 0; i < m.decisions.size(); ++i) {
            uint64_t step = (uint64_t)domain_size[i];
            uint64_t idx  = r % step; r /= step;
            const Decision& d = m.decisions[i];
            switch (d.kind) {
            case Decision::Bool:     cur[i] = (int64_t)idx; break;
            case Decision::Int:      cur[i] = d.lo + (int64_t)idx; break;
            case Decision::Float:    cur[i] = (int64_t)d.flo; break;
            case Decision::Interval: cur[i] = d.lo; break;
            case Decision::List:
            case Decision::Set:      cur[i] = 0; break;
            }
        }
        bool ok = true;
        for (Expr* c : m.constraints) if (eval_int(c, cur) == 0) { ok = false; break; }
        if (!ok) continue;
        int64_t obj = m.objectives.empty() ? 0 : eval_int(m.objectives[0].first, cur);
        bool better = !have_best || (maximize ? obj > best_obj : obj < best_obj);
        if (better) {
            have_best = true; best_obj = obj; best = cur;
            if (m.objectives.empty()) break;
        }
    }

    if (!have_best) { m.status = HXS_STATUS_INFEASIBLE; }
    else {
        m.assignment = best;
        for (size_t i = 0; i < m.decisions.size(); ++i) {
            const Decision& d = m.decisions[i];
            if (d.kind == Decision::Interval) m.interval_ends[i] = d.lo;
            else if (d.kind == Decision::List || d.kind == Decision::Set) {
                std::vector<int64_t> ids(d.n);
                for (int64_t j = 0; j < d.n; ++j) ids[j] = j;
                m.collections[i] = std::move(ids);
            }
        }
        m.solved = true;
        m.status = m.objectives.empty() ? HXS_STATUS_FEASIBLE : HXS_STATUS_OPTIMAL;
    }
    opt->impl.state = HXS_STATE_STOPPED;
    opt->impl.running_time = 0;
    opt->impl.iters = (long long)opt->impl.model.all_exprs.size();
    fire_callback(opt, HXS_CT_OPTIMIZATION_ENDED);
}

Expr* mk_decision(Model* m, Decision::Kind k, int64_t lo, int64_t hi, double flo, double fhi, int64_t n) {
    Expr* e = m->new_expr();
    e->kind = Expr::DecisionRef;
    e->decision_idx = (int)m->decisions.size();
    Decision d{k, lo, hi, flo, fhi, n};
    m->decisions.push_back(d);
    m->decision_exprs.push_back(e);
    return e;
}

int copy_string_out(const std::string& s, char* buf, int max_out) {
    int need = (int)s.size() + 1;
    if (buf == nullptr || max_out <= 0) return need;
    int to_copy = (max_out - 1 < (int)s.size()) ? max_out - 1 : (int)s.size();
    std::memcpy(buf, s.data(), to_copy);
    buf[to_copy] = '\0';
    return need;
}

bool guard_open(hxs_model* m, const char* what) {
    if (m->m->closed) { set_error(HXS_EC_API, what); return false; }
    clear_error();
    return true;
}

} // anonymous namespace

/* ===================== extern "C" ===================== */

extern "C" const char* hxs_last_error(void) { return g_last_error.empty() ? nullptr : g_last_error.c_str(); }
extern "C" hxs_error_code hxs_last_error_code(void) { return g_last_error_code; }
extern "C" void           hxs_clear_error(void)     { clear_error(); }

/* ---------- Version (faked) ---------- */
extern "C" int  hxs_backend_is_mock(void)    { return 1; }
extern "C" int  hxs_version_major(void)      { return 14; }
extern "C" int  hxs_version_minor(void)      { return 5; }
extern "C" int  hxs_version_code(void)       { return 1405; }
extern "C" int  hxs_version_build_date(void) { return 20260527; }
extern "C" int  hxs_version_string  (char* buf, int max_out)   { return copy_string_out("14.5-mock", buf, max_out); }
extern "C" int  hxs_version_platform(char* buf, int max_out)   { return copy_string_out("Mock",      buf, max_out); }
extern "C" int  hxs_version_info    (char* buf, int max_out)   { return copy_string_out("Mock build of Hexaly OCaml bindings — no real solver linked.", buf, max_out); }
extern "C" int  hxs_version_copyright(char* buf, int max_out)  { return copy_string_out("(mock backend)", buf, max_out); }
extern "C" int  hxs_version_license_path(char* buf, int max_out) { return copy_string_out("", buf, max_out); }
extern "C" void hxs_version_set_license_path(const char*) {}
extern "C" void hxs_version_set_license_content(const char*) {}

/* ---------- Optimizer ---------- */
extern "C" hxs_optimizer* hxs_optimizer_new(void) { clear_error(); return new hxs_optimizer(); }
extern "C" void hxs_optimizer_free(hxs_optimizer* o) { delete o; }

extern "C" hxs_model* hxs_optimizer_get_model(hxs_optimizer* o)         { return new hxs_model{ &o->impl.model }; }
extern "C" hxs_param* hxs_optimizer_get_param(hxs_optimizer* o)         { return new hxs_param{ &o->impl.param }; }
extern "C" hxs_solution* hxs_optimizer_get_solution(hxs_optimizer* o)   { return new hxs_solution{ &o->impl.model }; }
extern "C" int hxs_optimizer_solve(hxs_optimizer* o) {
    clear_error();
    solve(o);
    if (!o->impl.model.solved && !g_last_error.empty()) return -1;
    return 0;
}
extern "C" void      hxs_optimizer_stop(hxs_optimizer* o) { o->impl.state = HXS_STATE_STOPPED; }
extern "C" hxs_state hxs_optimizer_get_state(hxs_optimizer* o) { return o->impl.state; }
extern "C" int       hxs_optimizer_running_time(hxs_optimizer* o) { return o->impl.running_time; }
extern "C" long long hxs_optimizer_nb_iterations(hxs_optimizer* o) { return o->impl.iters; }

/* save/load: write a tiny header + serialized assignment if solved. */
extern "C" int hxs_optimizer_save_environment(hxs_optimizer* opt, const char* path) {
    if (!path) { set_error(HXS_EC_FILE, "null path"); return -1; }
    std::ofstream f(path);
    if (!f) { set_error(HXS_EC_FILE, "cannot open file for writing"); return -1; }
    f << "HEXALY-MOCK-ENV v1\n";
    f << "decisions=" << opt->impl.model.decisions.size() << "\n";
    f << "constraints=" << opt->impl.model.constraints.size() << "\n";
    f << "objectives=" << opt->impl.model.objectives.size() << "\n";
    f << "closed=" << (opt->impl.model.closed ? 1 : 0) << "\n";
    return 0;
}
extern "C" int hxs_optimizer_load_environment(hxs_optimizer* opt, const char* path) {
    (void)opt;
    if (!path) { set_error(HXS_EC_FILE, "null path"); return -1; }
    std::ifstream f(path);
    if (!f) { set_error(HXS_EC_FILE, "cannot open file for reading"); return -1; }
    std::string header;
    std::getline(f, header);
    if (header.find("HEXALY-MOCK-ENV") == std::string::npos) {
        set_error(HXS_EC_FILE, "not a mock-env file"); return -1;
    }
    return 0;
}

/* ---------- Inconsistency (mock returns all constraints as "causes") ---------- */
extern "C" hxs_inconsistency* hxs_optimizer_compute_inconsistency(hxs_optimizer* opt) {
    return new hxs_inconsistency{ &opt->impl.model };
}
extern "C" int hxs_inconsistency_nb_causes(hxs_inconsistency* i) {
    return (int)i->m->constraints.size();
}
extern "C" hxs_expression* hxs_inconsistency_cause(hxs_inconsistency* i, int idx) {
    if (idx < 0 || idx >= (int)i->m->constraints.size()) {
        set_error(HXS_EC_API, "cause index out of range"); return nullptr;
    }
    return new hxs_expression{ i->m->constraints[idx], i->m };
}
extern "C" int hxs_inconsistency_to_string(hxs_inconsistency* i, char* buf, int max_out) {
    std::ostringstream oss;
    oss << "mock IIS: " << i->m->constraints.size() << " constraint(s) flagged";
    return copy_string_out(oss.str(), buf, max_out);
}
extern "C" void hxs_inconsistency_free(hxs_inconsistency* i) { delete i; }

/* ---------- Callbacks ---------- */
extern "C" hxs_callback* hxs_optimizer_add_callback(
    hxs_optimizer* opt, hxs_callback_type type,
    hxs_callback_fn fn, void* userdata)
{
    size_t idx = opt->impl.callbacks.size();
    opt->impl.callbacks.push_back({type, fn, userdata});
    return new hxs_callback{ opt, idx };
}
extern "C" int hxs_optimizer_remove_callback(hxs_optimizer* opt, hxs_callback* cb) {
    if (!cb || cb->owner != opt) return 0;
    if (cb->index >= opt->impl.callbacks.size()) return 0;
    opt->impl.callbacks[cb->index].fn = nullptr; /* tombstone (preserves indices) */
    delete cb;
    return 1;
}

/* ---------- Model: decisions ---------- */
extern "C" hxs_expression* hxs_model_bool_var(hxs_model* m) { return new hxs_expression{ mk_decision(m->m, Decision::Bool, 0, 1, 0, 0, 0), m->m }; }
extern "C" hxs_expression* hxs_model_int_var(hxs_model* m, hxs_int lo, hxs_int hi) { return new hxs_expression{ mk_decision(m->m, Decision::Int, lo, hi, 0, 0, 0), m->m }; }
extern "C" hxs_expression* hxs_model_float_var(hxs_model* m, hxs_float lo, hxs_float hi) { return new hxs_expression{ mk_decision(m->m, Decision::Float, 0, 0, lo, hi, 0), m->m }; }
extern "C" hxs_expression* hxs_model_interval_var(hxs_model* m, hxs_int min_start, hxs_int max_end) { return new hxs_expression{ mk_decision(m->m, Decision::Interval, min_start, max_end, 0, 0, 0), m->m }; }
extern "C" hxs_expression* hxs_model_optional_interval_var(hxs_model* m, hxs_int min_start, hxs_int max_end) { return new hxs_expression{ mk_decision(m->m, Decision::Interval, min_start, max_end, 0, 0, 0), m->m }; }
extern "C" hxs_expression* hxs_model_list_var(hxs_model* m, hxs_int n) { return new hxs_expression{ mk_decision(m->m, Decision::List, 0, 0, 0, 0, n), m->m }; }
extern "C" hxs_expression* hxs_model_set_var(hxs_model* m, hxs_int n) { return new hxs_expression{ mk_decision(m->m, Decision::Set, 0, 0, 0, 0, n), m->m }; }

extern "C" hxs_expression* hxs_model_const_int(hxs_model* m, hxs_int v) {
    Expr* e = m->m->new_expr(); e->kind = Expr::IntConst; e->int_const = v;
    return new hxs_expression{ e, m->m };
}
extern "C" hxs_expression* hxs_model_const_float(hxs_model* m, hxs_float v) {
    Expr* e = m->m->new_expr(); e->kind = Expr::FloatConst; e->float_const = v;
    return new hxs_expression{ e, m->m };
}
extern "C" hxs_expression* hxs_model_const_int_array(hxs_model* m, const hxs_int* vals, int n) {
    Expr* e = m->m->new_expr(); e->kind = Expr::OpNode; e->op = HXS_O_CONST_ARRAY;
    e->int_consts.assign(vals, vals + n);
    return new hxs_expression{ e, m->m };
}
extern "C" hxs_expression* hxs_model_const_float_array(hxs_model* m, const hxs_float* vals, int n) {
    Expr* e = m->m->new_expr(); e->kind = Expr::OpNode; e->op = HXS_O_CONST_ARRAY;
    e->float_consts.assign(vals, vals + n);
    return new hxs_expression{ e, m->m };
}

extern "C" hxs_expression* hxs_model_create_expression(
    hxs_model* m, hxs_operator op,
    hxs_expression** operands, int nb_operands,
    const hxs_int* int_consts, int nb_int_consts,
    const hxs_float* float_consts, int nb_float_consts)
{
    Expr* e = m->m->new_expr();
    e->kind = Expr::OpNode; e->op = (int)op;
    e->operands.reserve(nb_operands);
    for (int i = 0; i < nb_operands; ++i) e->operands.push_back(operands[i]->e);
    e->int_consts.assign(int_consts, int_consts + nb_int_consts);
    e->float_consts.assign(float_consts, float_consts + nb_float_consts);
    return new hxs_expression{ e, m->m };
}

extern "C" void hxs_model_add_constraint(hxs_model* m, hxs_expression* e) {
    if (!guard_open(m, "mock: add_constraint not allowed after close()")) return;
    m->m->constraints.push_back(e->e);
}
extern "C" void hxs_model_minimize(hxs_model* m, hxs_expression* e) {
    if (!guard_open(m, "mock: minimize not allowed after close()")) return;
    m->m->objectives.emplace_back(e->e, 0);
}
extern "C" void hxs_model_maximize(hxs_model* m, hxs_expression* e) {
    if (!guard_open(m, "mock: maximize not allowed after close()")) return;
    m->m->objectives.emplace_back(e->e, 1);
}
extern "C" void hxs_model_close(hxs_model* m)   { m->m->closed = true; }
extern "C" int  hxs_model_is_closed(hxs_model* m) { return m->m->closed ? 1 : 0; }

extern "C" int hxs_model_nb_expressions(hxs_model* m) { return (int)m->m->all_exprs.size(); }
extern "C" int hxs_model_nb_constraints(hxs_model* m) { return (int)m->m->constraints.size(); }
extern "C" int hxs_model_nb_objectives (hxs_model* m) { return (int)m->m->objectives.size(); }
extern "C" int hxs_model_nb_decisions  (hxs_model* m) { return (int)m->m->decisions.size(); }

extern "C" hxs_int hxs_solution_int_value(hxs_solution* s, hxs_expression* e) {
    if (!s->m->solved) { set_error(HXS_EC_API, "solution not available — solve first"); return 0; }
    return (hxs_int)eval_int(e->e, s->m->assignment);
}
extern "C" hxs_float hxs_solution_float_value(hxs_solution* s, hxs_expression* e) {
    if (!s->m->solved) { set_error(HXS_EC_API, "solution not available — solve first"); return 0.0; }
    return (hxs_float)eval_float(e->e, s->m->assignment);
}
extern "C" hxs_solution_status hxs_solution_get_status(hxs_solution* s) {
    return (hxs_solution_status)s->m->status;
}
extern "C" int hxs_solution_is_violated(hxs_solution* s, hxs_expression* e) {
    if (!s->m->solved) { set_error(HXS_EC_API, "solution not available"); return -1; }
    return eval_int(e->e, s->m->assignment) == 0 ? 1 : 0;
}
extern "C" int hxs_solution_is_undefined(hxs_solution*, hxs_expression*) { return 0; }
extern "C" int hxs_solution_interval_value(hxs_solution* s, hxs_expression* e,
                                            hxs_int* out_start, hxs_int* out_end) {
    if (!s->m->solved) { set_error(HXS_EC_API, "solution not available"); return -1; }
    if (e->e->kind != Expr::DecisionRef) {
        set_error(HXS_EC_API, "mock: interval_value requires a decision expression"); return -1;
    }
    int di = e->e->decision_idx;
    *out_start = s->m->assignment[di];
    *out_end   = s->m->interval_ends[di];
    return 0;
}
extern "C" int hxs_solution_collection_size(hxs_solution* s, hxs_expression* e) {
    if (!s->m->solved) { set_error(HXS_EC_API, "solution not available"); return -1; }
    if (e->e->kind != Expr::DecisionRef) {
        set_error(HXS_EC_API, "mock: collection_size requires a decision expression"); return -1;
    }
    return (int)s->m->collections[e->e->decision_idx].size();
}
extern "C" int hxs_solution_collection_dump(hxs_solution* s, hxs_expression* e,
                                             hxs_int* out_buf, int max_out) {
    if (!s->m->solved) { set_error(HXS_EC_API, "solution not available"); return -1; }
    if (e->e->kind != Expr::DecisionRef) {
        set_error(HXS_EC_API, "mock: collection_dump requires a decision expression"); return -1;
    }
    const auto& v = s->m->collections[e->e->decision_idx];
    int n = (int)v.size();
    int copy = max_out < n ? max_out : n;
    for (int i = 0; i < copy; ++i) out_buf[i] = v[i];
    return n;
}

extern "C" int hxs_solution_set_int_value(hxs_solution* s, hxs_expression* e, hxs_int v) {
    if (e->e->kind != Expr::DecisionRef) { set_error(HXS_EC_API, "set requires a decision"); return -1; }
    s->m->hint_ints.emplace_back(e->e->decision_idx, v);
    return 0;
}
extern "C" int hxs_solution_set_float_value(hxs_solution* s, hxs_expression* e, hxs_float v) {
    if (e->e->kind != Expr::DecisionRef) { set_error(HXS_EC_API, "set requires a decision"); return -1; }
    s->m->hint_floats.emplace_back(e->e->decision_idx, v);
    return 0;
}
extern "C" int hxs_solution_set_interval_value(hxs_solution* s, hxs_expression* e, hxs_int st, hxs_int ed) {
    if (e->e->kind != Expr::DecisionRef) { set_error(HXS_EC_API, "set requires a decision"); return -1; }
    s->m->hint_intervals.emplace_back(e->e->decision_idx, st, ed);
    return 0;
}
extern "C" void hxs_solution_clear(hxs_solution* s) {
    s->m->hint_ints.clear(); s->m->hint_floats.clear(); s->m->hint_intervals.clear();
}

extern "C" void hxs_param_set_time_limit(hxs_param* p, int v)        { p->p->time_limit = v; }
extern "C" void hxs_param_set_iteration_limit(hxs_param* p, long long v) { p->p->iter_limit = v; }
extern "C" void hxs_param_set_seed(hxs_param* p, int v)              { p->p->seed = v; }
extern "C" void hxs_param_set_nb_threads(hxs_param* p, int v)        { p->p->nb_threads = v; }
extern "C" void hxs_param_set_verbosity(hxs_param* p, int v)         { p->p->verbosity = v; }
extern "C" void hxs_param_set_warning_level(hxs_param* p, int v)     { p->p->warning_level = v; }
extern "C" void hxs_param_set_time_between_displays(hxs_param* p, int v)    { p->p->time_between_displays = v; }
extern "C" void hxs_param_set_time_between_ticks(hxs_param* p, int v)       { p->p->time_between_ticks = v; }
extern "C" void hxs_param_set_iteration_between_ticks(hxs_param* p, long long v) { p->p->iteration_between_ticks = v; }
extern "C" void hxs_param_set_log_file(hxs_param* p, const char* path)      { p->p->log_file = path ? path : ""; }
extern "C" void hxs_param_set_advanced_int   (hxs_param* p, const char* k, int v)        { p->p->adv_int.emplace_back(k?k:"", v); }
extern "C" void hxs_param_set_advanced_double(hxs_param* p, const char* k, double v)     { p->p->adv_dbl.emplace_back(k?k:"", v); }
extern "C" void hxs_param_set_advanced_string(hxs_param* p, const char* k, const char* v){ p->p->adv_str.emplace_back(k?k:"", v?v:""); }
extern "C" void hxs_param_set_int_objective_threshold(hxs_param* p, int i, hxs_int t)    { p->p->int_obj_thresholds.emplace_back(i, t); }
extern "C" void hxs_param_set_double_objective_threshold(hxs_param* p, int i, hxs_float t){ p->p->dbl_obj_thresholds.emplace_back(i, t); }

extern "C" void hxs_model_free     (hxs_model* m)      { delete m; }
extern "C" void hxs_expression_free(hxs_expression* e) { delete e; }
extern "C" void hxs_solution_free  (hxs_solution* s)   { delete s; }
extern "C" void hxs_param_free     (hxs_param* p)      { delete p; }

/* ---------- Phases ---------- */
extern "C" hxs_phase* hxs_optimizer_create_phase(hxs_optimizer* opt) {
    size_t idx = opt->phases.size();
    opt->phases.push_back({});
    return new hxs_phase{ opt, idx };
}
extern "C" hxs_phase* hxs_optimizer_get_phase(hxs_optimizer* opt, int idx) {
    if (idx < 0 || idx >= (int)opt->phases.size()) {
        set_error(HXS_EC_API, "mock: phase index out of range"); return nullptr;
    }
    return new hxs_phase{ opt, (size_t)idx };
}
extern "C" int hxs_optimizer_nb_phases(hxs_optimizer* opt) { return (int)opt->phases.size(); }

#define PHASE_CHECK(p, ret) do { \
    if (!(p) || (p)->index >= (p)->owner->phases.size()) { \
        set_error(HXS_EC_API, "mock: invalid phase handle"); return ret; \
    } \
} while (0)
#define PHASE_FIELD(p) ((p)->owner->phases[(p)->index])

extern "C" void hxs_phase_set_time_limit(hxs_phase* p, int s)              { PHASE_CHECK(p,); PHASE_FIELD(p).time_limit = s; }
extern "C" int  hxs_phase_get_time_limit(hxs_phase* p)                     { PHASE_CHECK(p, -1); return PHASE_FIELD(p).time_limit; }
extern "C" void hxs_phase_set_iteration_limit(hxs_phase* p, long long n)   { PHASE_CHECK(p,); PHASE_FIELD(p).iter_limit = n; }
extern "C" long long hxs_phase_get_iteration_limit(hxs_phase* p)           { PHASE_CHECK(p, -1); return PHASE_FIELD(p).iter_limit; }
extern "C" void hxs_phase_set_optimized_objective(hxs_phase* p, int idx)   { PHASE_CHECK(p,); PHASE_FIELD(p).optimized_obj = idx; }
extern "C" int  hxs_phase_get_optimized_objective(hxs_phase* p)            { PHASE_CHECK(p, -1); return PHASE_FIELD(p).optimized_obj; }
extern "C" void hxs_phase_set_enabled(hxs_phase* p, int e)                 { PHASE_CHECK(p,); PHASE_FIELD(p).enabled = (e != 0); }
extern "C" int  hxs_phase_is_enabled(hxs_phase* p)                         { PHASE_CHECK(p, -1); return PHASE_FIELD(p).enabled ? 1 : 0; }
extern "C" int  hxs_phase_to_string(hxs_phase* p, char* buf, int max_out)  {
    PHASE_CHECK(p, -1);
    std::ostringstream oss;
    oss << "phase[" << p->index << "] obj=" << PHASE_FIELD(p).optimized_obj
        << " enabled=" << (PHASE_FIELD(p).enabled ? "true" : "false");
    return copy_string_out(oss.str(), buf, max_out);
}
extern "C" void hxs_phase_free(hxs_phase* p) { delete p; }
