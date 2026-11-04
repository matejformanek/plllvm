/*-------------------------------------------------------------------------
 *
 * plllvm_pj_translate.c
 *
 *			  plpgsql_jit: from the planned expressions of a PL/pgSQL
 *			  function to LLVM IR
 *
 * by Matěj Formánek 2026
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) The trees are those PL/pgSQL left in expr_simple_expr after its first
 *    run of the function.  We copy them and never point into the plan,
 *    which the next invalidation frees.
 *
 * 2) The value of an expression converts to its target as exec_cast_value()
 *    does, by a tree over a CaseTestExpr bound to the value.  Only a cast that
 *    cannot raise compiles, or is folded into a constant, so every cast
 *    error comes from PL/pgSQL.
 *
 * 3) The statements are walked twice, in the same order and skipping the
 *    same unreachable ones: plllvm_pj_scope() collects the expressions and
 *    positions, emit_stmts() takes them back in that order.  An expression
 *    that PL/pgSQL has not planned yet becomes a deopt point.
 *
 * The rest is in docs/architecture.md.
 *
 */
#include "postgres.h"

#include "access/htup_details.h"
#include "access/transam.h"
#include "catalog/pg_cast.h"
#include "catalog/pg_proc.h"
#include "catalog/pg_type.h"
#include "lib/stringinfo.h"
#include "nodes/makefuncs.h"
#include "nodes/nodeFuncs.h"
#include "optimizer/optimizer.h"
#include "parser/parse_coerce.h"
#include "plpgsql.h"
#include "utils/builtins.h"
#include "utils/hsearch.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/plancache.h"
#include "utils/syscache.h"

#include "plllvm.h"
#include "plllvm_expr.h"
#include "plllvm_ir.h"
#include "plllvm_pj.h"

typedef struct PjEnv
{
	plllvm_expr_env base;
	PLpgSQL_function *func;
	PjHarvest  *h;
	/* reset for each expression checked */
	bool		need;
	int			ncalls;
	/* the sites made so far by an emit */
	List	   *sites;
} PjEnv;

/* the datums a tree reads */
typedef struct PjParams
{
	PLpgSQL_function *func;
	Bitmapset  *ids;
} PjParams;

typedef struct PjCastKey
{
	Oid			srctype;
	int32		srctypmod;
	Oid			dsttype;
} PjCastKey;

typedef struct PjCastEntry
{
	PjCastKey	key;
	PjCast		cast;
} PjCastEntry;

/* a block or loop that EXIT and CONTINUE may name */
typedef struct PjFrame
{
	const char *label;
	bool		loop;
	bool		fori;
	const char *exit_to;		/* emit only */
	const char *cont_to;
} PjFrame;

typedef struct PjScopeWalk
{
	PLpgSQL_function *func;
	PjScope    *scope;
	List	   *frames;			/* PjFrame, innermost first */
	int			cur_pos;		/* position of the statement or variable */
} PjScopeWalk;

typedef struct PjEmit
{
	plllvm_ir  *ir;
	PjEnv		env;
	PLpgSQL_function *func;
	PjHarvest  *h;
	bool		nopos;
	bool		all_boxed;		/* pj_codegen = boxed */
	bool		in_return;		/* emitting the value of a RETURN */
	bool		open;			/* the current block has no terminator yet */
	bool		poll_pending;	/* poll after the next position store */
	int			nboxed;			/* boxed evaluations emitted so far */
	int			next_expr;
	int			cur;			/* position stored in this block, or -1 */
	List	   *frames;
} PjEmit;

#define PJ_INIT_TEXT "during statement block local variable initialization"

static HTAB *casts = NULL;

static const char *walk_stmts(PjScopeWalk *w, List *stmts);
static const char *walk_stmt(PjScopeWalk *w, PLpgSQL_stmt *stmt);
static const char *walk_block(PjScopeWalk *w, PLpgSQL_stmt_block *block);
static const char *var_reason(PLpgSQL_function *func, int dno);
static void scope_pos(PjScopeWalk *w, PLpgSQL_stmt *stmt);
static void scope_expr(PjScopeWalk *w, const void *owner, PLpgSQL_expr *expr,
					   Oid dsttype, int32 dsttypmod);
static bool stmt_terminal(PLpgSQL_stmt *stmt);
static PjFrame *frame_push(List **frames, const char *label, bool loop,
						   bool fori);
static void frame_pop(List **frames);
static PjFrame *frame_find(List *frames, const char *label, bool loop_only,
						   bool *crossed_for);
static bool signature_polymorphic(PLpgSQL_function *func);
static void env_init(PjEnv *env, PLpgSQL_function *func, PjHarvest *h);
static bool param_check(plllvm_expr_env *env, const Param *p,
						StringInfo facts);
static void param_emit(plllvm_expr_env *env, plllvm_ir *ir, const Param *p,
					   plllvm_value *out);
static bool call_check(plllvm_expr_env *base, const Node *node);
static void call_emit(plllvm_expr_env *base, plllvm_ir *ir, const Node *node,
					  const plllvm_value *args, int nargs, plllvm_value *out);
static const char *bare_emit(plllvm_expr_env *base, plllvm_ir *ir, Oid funcid,
							 const char *const *args, int nargs);
static PjCast *cast_get(Oid srctype, int32 srctypmod, Oid dsttype,
						Expr **tree);
static bool cast_pinned(Oid srctype, Oid dsttype);
static Const *cast_fold(Expr *cast_tree, const Const *src, Oid dsttype);
static bool cast_has_io(Node *node, void *context);
static Node *cast_bind(Node *node, void *context);
static bool funcs_walker(Node *node, List **funcs);
static bool params_walker(Node *node, PjParams *ctx);
static void unbox(plllvm_ir *ir, const char *datum, const char *isnull,
				  Oid type, plllvm_value *out);
static PjPath expr_path(PjEmit *em, const PjExpr *pe);
static void boxed_value(PjEmit *em, int index, const PjExpr *pe,
						const char **datum, const char **isnull);
static bool funcs_callback(Oid funcid, void *context);
static const char *harvest_expr(PLpgSQL_function *func, PjHarvest *h,
								PjEnv *env, PjExpr *pe, List **funcs);
static PLpgSQL_var *arg_var(PLpgSQL_function *func, int dno);

static void emit_stmts(PjEmit *em, List *stmts);
static void emit_stmt(PjEmit *em, PLpgSQL_stmt *stmt);
static void emit_block(PjEmit *em, PLpgSQL_stmt_block *block);
static void emit_assign(PjEmit *em, PLpgSQL_stmt_assign *stmt);
static void emit_if(PjEmit *em, PLpgSQL_stmt_if *stmt);
static void emit_loop(PjEmit *em, PLpgSQL_stmt *stmt);
static void emit_fori(PjEmit *em, PLpgSQL_stmt_fori *stmt);
static void emit_exit(PjEmit *em, PLpgSQL_stmt_exit *stmt);
static void emit_return(PjEmit *em, PLpgSQL_stmt_return *stmt);
static void emit_body(PjEmit *em, List *body, int stmtid);
static bool cond_may_raise(PjEmit *em);
static bool may_raise(Node *node, void *context);
static void expr_value(PjEmit *em, const void *owner, const char **datum,
					   const char **isnull);
static const char *expr_taken(PjEmit *em, const void *owner);
static void store_var(PjEmit *em, int dno, const char *datum,
					  const char *isnull);
static void check_not_null(PjEmit *em, PLpgSQL_var *var, const char *isnull);
static void for_check(PjEmit *em, const char *failed, PjForError what);
static void site_done(PjEmit *em, int index, const PjExpr *pe);
static void set_found(PjEmit *em, bool value);
static void set_pos(PjEmit *em, int index);
static void stmt_enter(PjEmit *em, PLpgSQL_stmt *stmt);
static void poll(PjEmit *em, int stmtid);
static void poll_if_boxed(PjEmit *em, int boxed0);
static void begin_block(PjEmit *em, const char *label);
static void branch(PjEmit *em, const char *label);
static void branch_if(PjEmit *em, const char *cond, const char *yes,
					  const char *no);
static void reopen(PjEmit *em);
static const char *field_ptr(plllvm_ir *ir, const char *base, size_t offset);

/*
 * What the function does, as far as this translator goes
 *
 * scope->reason says why a function is out of scope.  exprs are those the
 * run can reach; their planned state is read by plllvm_pj_classify().
 */
void
plllvm_pj_scope(PLpgSQL_function *func, PjScope *scope)
{
	PjScopeWalk w = {func, scope, NIL};

	memset(scope, 0, sizeof(PjScope));

	if (func->fn_is_trigger != PLPGSQL_NOT_TRIGGER ||
		func->fn_prokind != PROKIND_FUNCTION ||
		func->fn_retset || func->fn_retistuple ||
		func->out_param_varno >= 0 ||
		signature_polymorphic(func))
	{
		scope->reason = "signature";
		return;
	}

	for (int i = 0; i < func->fn_nargs; i++)
	{
		PLpgSQL_datum *datum = func->datums[func->fn_argvarnos[i]];

		if (datum->dtype != PLPGSQL_DTYPE_VAR)
		{
			scope->reason = "datum:record";
			return;
		}
		if (!((PLpgSQL_var *) datum)->datatype->typbyval)
		{
			scope->reason = psprintf("datum:%s",
									 ((PLpgSQL_var *) datum)->datatype->typname);
			return;
		}
	}

	scope->npos = func->nstatements + 1 + func->ndatums;
	scope->pos = palloc0_array(PjPos, scope->npos);
	for (int i = 0; i < scope->npos; i++)
		scope->pos[i].expr = -1;

	scope->reason = walk_stmt(&w, (PLpgSQL_stmt *) func->action);
}

static const char *
walk_stmts(PjScopeWalk *w, List *stmts)
{
	foreach_ptr(PLpgSQL_stmt, stmt, stmts)
	{
		const char *reason = walk_stmt(w, stmt);

		if (reason != NULL)
			return reason;
		if (stmt_terminal(stmt))
			break;
	}

	return NULL;
}

static const char *
walk_stmt(PjScopeWalk *w, PLpgSQL_stmt *stmt)
{
	PLpgSQL_function *func = w->func;
	const char *reason;

	scope_pos(w, stmt);

	switch (stmt->cmd_type)
	{
		case PLPGSQL_STMT_BLOCK:
			return walk_block(w, (PLpgSQL_stmt_block *) stmt);

		case PLPGSQL_STMT_ASSIGN:
			{
				PLpgSQL_stmt_assign *assign = (PLpgSQL_stmt_assign *) stmt;
				PLpgSQL_var *var;

				reason = var_reason(func, assign->varno);
				if (reason != NULL)
					return reason;
				var = (PLpgSQL_var *) func->datums[assign->varno];
				scope_expr(w, assign->expr, assign->expr, var->datatype->typoid,
						   var->datatype->atttypmod);
				return NULL;
			}

		case PLPGSQL_STMT_IF:
			{
				PLpgSQL_stmt_if *ifs = (PLpgSQL_stmt_if *) stmt;

				scope_expr(w, ifs->cond, ifs->cond, BOOLOID, -1);
				reason = walk_stmts(w, ifs->then_body);
				if (reason != NULL)
					return reason;
				foreach_ptr(PLpgSQL_if_elsif, elif, ifs->elsif_list)
				{
					w->cur_pos = stmt->stmtid;
					scope_expr(w, elif->cond, elif->cond, BOOLOID, -1);
					reason = walk_stmts(w, elif->stmts);
					if (reason != NULL)
						return reason;
				}
				return walk_stmts(w, ifs->else_body);
			}

		case PLPGSQL_STMT_LOOP:
		case PLPGSQL_STMT_WHILE:
		case PLPGSQL_STMT_FORI:
			{
				const char *label;
				List	   *body;
				bool		fori = false;

				if (stmt->cmd_type == PLPGSQL_STMT_LOOP)
				{
					label = ((PLpgSQL_stmt_loop *) stmt)->label;
					body = ((PLpgSQL_stmt_loop *) stmt)->body;
				}
				else if (stmt->cmd_type == PLPGSQL_STMT_WHILE)
				{
					PLpgSQL_stmt_while *loop = (PLpgSQL_stmt_while *) stmt;

					label = loop->label;
					body = loop->body;
					scope_expr(w, loop->cond, loop->cond, BOOLOID, -1);
				}
				else
				{
					PLpgSQL_stmt_fori *loop = (PLpgSQL_stmt_fori *) stmt;

					label = loop->label;
					body = loop->body;
					fori = true;
					w->scope->fori = lappend_int(w->scope->fori, stmt->stmtid);
					scope_expr(w, loop->lower, loop->lower, INT4OID, -1);
					scope_expr(w, loop->upper, loop->upper, INT4OID, -1);
					if (loop->step != NULL)
						scope_expr(w, loop->step, loop->step, INT4OID, -1);
				}

				frame_push(&w->frames, label, true, fori);
				reason = walk_stmts(w, body);
				frame_pop(&w->frames);
				return reason;
			}

		case PLPGSQL_STMT_EXIT:
			{
				PLpgSQL_stmt_exit *ex = (PLpgSQL_stmt_exit *) stmt;

				if (ex->cond != NULL)
					scope_expr(w, ex->cond, ex->cond, BOOLOID, -1);
				if (frame_find(w->frames, ex->label, !ex->is_exit,
							   NULL) == NULL)
					return "label";
				return NULL;
			}

		case PLPGSQL_STMT_RETURN:
			{
				PLpgSQL_stmt_return *ret = (PLpgSQL_stmt_return *) stmt;

				if (ret->retvarno >= 0)
				{
					PLpgSQL_var *var = arg_var(func, ret->retvarno);

					if (var == NULL)
						return "datum:record";
					scope_expr(w, ret, NULL, func->fn_rettype, -1);
					((PjExpr *) llast(w->scope->exprs))->retvarno =
						ret->retvarno;
				}
				else if (ret->expr != NULL)
					scope_expr(w, ret->expr, ret->expr, func->fn_rettype, -1);
				return NULL;
			}

		default:
			return psprintf("statement:%s", plllvm_pj_stmt_typename(stmt));
	}
}

static const char *
walk_block(PjScopeWalk *w, PLpgSQL_stmt_block *block)
{
	PLpgSQL_function *func = w->func;
	const char *reason;

	if (block->exceptions != NULL)
		return "exception block";

	for (int i = 0; i < block->n_initvars; i++)
	{
		int			dno = block->initvarnos[i];
		PLpgSQL_var *var;
		PjPos	   *pos = &w->scope->pos[func->nstatements + 1 + dno];

		reason = var_reason(func, dno);
		if (reason != NULL)
			return reason;

		var = (PLpgSQL_var *) func->datums[dno];
		pos->lineno = var->lineno;
		pos->text = PJ_INIT_TEXT;
		w->cur_pos = func->nstatements + 1 + dno;
		if (var->default_val != NULL)
			scope_expr(w, var->default_val, var->default_val,
					   var->datatype->typoid, var->datatype->atttypmod);
	}

	if (block->label != NULL)
		frame_push(&w->frames, block->label, false, false);
	reason = walk_stmts(w, block->body);
	if (block->label != NULL)
		frame_pop(&w->frames);

	return reason;
}

/*
 * Why the variable cannot be declared or assigned here: its Datum must be
 * one we can keep in a slot, and a domain checks its value at every
 * assignment.  Reading one is another matter (arg_var).
 */
static const char *
var_reason(PLpgSQL_function *func, int dno)
{
	PLpgSQL_var *var;

	if (dno < 0 || dno >= func->ndatums ||
		func->datums[dno]->dtype != PLPGSQL_DTYPE_VAR)
		return "datum:record";

	var = (PLpgSQL_var *) func->datums[dno];
	if (!var->datatype->typbyval || var->datatype->typtype == TYPTYPE_DOMAIN)
		return psprintf("datum:%s", var->datatype->typname);

	return NULL;
}

static void
scope_pos(PjScopeWalk *w, PLpgSQL_stmt *stmt)
{
	PjPos	   *pos = &w->scope->pos[stmt->stmtid];

	pos->lineno = stmt->lineno;
	pos->stmt = plllvm_pj_stmt_typename(stmt);
	w->cur_pos = stmt->stmtid;
}

static void
scope_expr(PjScopeWalk *w, const void *owner, PLpgSQL_expr *expr,
		   Oid dsttype, int32 dsttypmod)
{
	PjExpr	   *pe = palloc0_object(PjExpr);

	pe->expr = expr;
	pe->owner = owner;
	pe->retvarno = -1;
	pe->dsttype = dsttype;
	pe->dsttypmod = dsttypmod;
	pe->pos = w->cur_pos;
	w->scope->exprs = lappend(w->scope->exprs, pe);
}

/*
 * Nothing after a RETURN, or an EXIT or CONTINUE with no condition, runs
 */
static bool
stmt_terminal(PLpgSQL_stmt *stmt)
{
	return stmt->cmd_type == PLPGSQL_STMT_RETURN ||
		(stmt->cmd_type == PLPGSQL_STMT_EXIT &&
		 ((PLpgSQL_stmt_exit *) stmt)->cond == NULL);
}

/*
 * The frame an EXIT or CONTINUE names, as the loops and blocks of PL/pgSQL
 * find it: an unlabeled one belongs to the innermost loop, a labeled one to
 * the innermost with that label, but CONTINUE never stops at a block.
 * *crossed_for, if given, says whether a FOR over integers lies between,
 * which sets FOUND on the way out.
 */
static PjFrame *
frame_push(List **frames, const char *label, bool loop, bool fori)
{
	PjFrame    *frame = palloc0_object(PjFrame);

	frame->label = label;
	frame->loop = loop;
	frame->fori = fori;
	*frames = lcons(frame, *frames);
	return frame;
}

static void
frame_pop(List **frames)
{
	*frames = list_delete_first(*frames);
}

static PjFrame *
frame_find(List *frames, const char *label, bool loop_only, bool *crossed_for)
{
	if (crossed_for != NULL)
		*crossed_for = false;

	foreach_ptr(PjFrame, frame, frames)
	{
		if (label == NULL ? frame->loop :
			(frame->label != NULL && strcmp(frame->label, label) == 0 &&
			 (frame->loop || !loop_only)))
			return frame;
		if (frame->fori && crossed_for != NULL)
			*crossed_for = true;
	}

	return NULL;
}

/*
 * Is a type of the signature polymorphic?  plpgsql_compile() keeps one
 * struct per signature, so the actual types of a call would be fixed
 */
static bool
signature_polymorphic(PLpgSQL_function *func)
{
	Oid		   *argtypes;
	int			nargs;
	Oid			rettype = get_func_signature(func->fn_oid, &argtypes, &nargs);

	if (IsPolymorphicType(rettype))
		return true;
	for (int i = 0; i < nargs; i++)
	{
		if (IsPolymorphicType(argtypes[i]))
			return true;
	}
	return false;
}

/*
 * An expression whose cached plan is stale counts as not planned: no tree is
 * read, and the interpreter replans it at its next evaluation.  The variable
 * of a RETURN has no plan to wait for.
 */
void
plllvm_pj_classify(PjScope *scope)
{
	foreach_ptr(PjExpr, pe, scope->exprs)
	{
		PLpgSQL_expr *expr = pe->expr;

		if (expr == NULL)
		{
			pe->h1 = PJ_H1_READY;
			continue;
		}

		if (expr->plan == NULL)
			pe->h1 = PJ_H1_UNPLANNED;
		else if (expr->expr_simple_expr == NULL)
			pe->h1 = PJ_H1_NOT_SIMPLE;
		else if (expr->expr_simple_plan == NULL ||
				 !CachedPlanIsSimplyValid(expr->expr_simple_plansource,
										  expr->expr_simple_plan, NULL))
			pe->h1 = PJ_H1_UNPLANNED;
		else
			pe->h1 = PJ_H1_READY;

		switch (pe->h1)
		{
			case PJ_H1_READY:
				scope->nready++;
				break;
			case PJ_H1_UNPLANNED:
				scope->nunplanned++;
				break;
			case PJ_H1_NOT_SIMPLE:
				scope->nnotsimple++;
				break;
		}
	}
}

/*
 * Copy what the code depends on into h, and decide how the value of each
 * expression is computed.  Returns the reason to decline the function, or
 * NULL.  The caller is in a temporary context; h->cxt takes the copies.
 */
const char *
plllvm_pj_harvest(PLpgSQL_function *func, const PjScope *scope, PjHarvest *h)
{
	MemoryContext oldcxt;
	PjEnv		env;
	List	   *funcs = NIL;
	const char *reason = NULL;

	env_init(&env, func, h);

	oldcxt = MemoryContextSwitchTo(h->cxt);
	/* then a copy of its statement's for each expression, naming it */
	h->nbase = scope->npos;
	h->npos = scope->npos + list_length(scope->exprs);
	h->pos = palloc_array(PjPos, h->npos);
	memcpy(h->pos, scope->pos, sizeof(PjPos) * scope->npos);
	for (int i = 0; i < list_length(scope->exprs); i++)
	{
		PjExpr	   *pe = list_nth(scope->exprs, i);

		h->pos[scope->npos + i] = scope->pos[pe->pos];
		h->pos[scope->npos + i].expr = i;
	}
	h->fori = list_copy(scope->fori);
	h->ndatums = func->ndatums;
	h->ptypes = palloc0_array(Oid, func->ndatums);
	for (int dno = 0; dno < func->ndatums; dno++)
	{
		PLpgSQL_var *var = arg_var(func, dno);

		if (var != NULL)
			h->ptypes[dno] = var->datatype->typoid;
	}
	MemoryContextSwitchTo(oldcxt);

	foreach_ptr(PjExpr, pe, scope->exprs)
	{
		PjExpr	   *copy = MemoryContextAlloc(h->cxt, sizeof(PjExpr));

		*copy = *pe;
		if (pe->h1 == PJ_H1_READY)
		{
			oldcxt = MemoryContextSwitchTo(h->cxt);
			if (pe->expr != NULL)
			{
				PLpgSQL_expr *expr = pe->expr;

				copy->tree = copyObject(expr->expr_simple_expr);
				copy->type = expr->expr_simple_type;
				copy->typmod = expr->expr_simple_typmod;
				copy->plansource = expr->expr_simple_plansource;
				copy->plan = expr->expr_simple_plan;
				copy->generation = expr->expr_simple_plan->generation;
				copy->need = expr->expr_simple_mutable && !func->fn_readonly;
			}
			else
			{
				PLpgSQL_var *var = arg_var(func, pe->retvarno);
				Param	   *p = makeNode(Param);

				p->paramkind = PARAM_EXTERN;
				p->paramid = pe->retvarno + 1;
				p->paramtype = var->datatype->typoid;
				p->paramtypmod = -1;
				copy->tree = (Expr *) p;
				copy->type = p->paramtype;
				copy->typmod = -1;
			}
			MemoryContextSwitchTo(oldcxt);

			if (reason == NULL)
				reason = harvest_expr(func, h, &env, copy, &funcs);
		}
		else
			h->nunplanned++;

		oldcxt = MemoryContextSwitchTo(h->cxt);
		h->exprs = lappend(h->exprs, copy);
		MemoryContextSwitchTo(oldcxt);
	}

	oldcxt = MemoryContextSwitchTo(h->cxt);
	h->funcids = list_copy(funcs);
	MemoryContextSwitchTo(oldcxt);

	return reason;
}

/*
 * How the value of one expression is computed and converted, decided
 * against the type of the value as exec_cast_value() is.  A conversion
 * compiles only if it cannot raise; the guard of its cast is kept even when
 * it needs no code.
 */
static const char *
harvest_expr(PLpgSQL_function *func, PjHarvest *h, PjEnv *env, PjExpr *pe,
			 List **funcs)
{
	Expr	   *tree = pe->tree;
	bool		move = false;
	bool		null_const = false;
	bool		dst_domain;
	bool		pinned;
	Expr	   *cast_tree;
	plllvm_repr repr;
	StringInfoData key;
	StringInfoData facts;
	const char *why = NULL;
	MemoryContext oldcxt;

	if (IsA(tree, Param))
	{
		Param	   *p = (Param *) tree;
		PLpgSQL_var *var = p->paramkind == PARAM_EXTERN ?
			arg_var(func, p->paramid - 1) : NULL;

		move = var != NULL && var->datatype->typoid == p->paramtype;
	}
	else if (IsA(tree, Const))
	{
		Const	   *c = (Const *) tree;

		/* a datum of a type passed by reference is the executor's */
		move = c->constisnull || c->constbyval;
		null_const = c->constisnull;
	}

	if (move)
		pe->path = PJ_PATH_MOVE;
	else
	{
		PjParams	params = {func, NULL};

		initStringInfo(&key);
		initStringInfo(&facts);
		env->need = pe->need;
		env->ncalls = 0;
		pe->path = plllvm_expr_check(tree, &env->base, &key, &facts, &why) ?
			PJ_PATH_NATIVE : PJ_PATH_BOXED;
		if (contain_volatile_functions((Node *) tree))
			return "volatile callee";
		if (pe->path == PJ_PATH_NATIVE)
			pe->ncalls = env->ncalls;

		/* a tree for the executor reads the datums by number */
		if (params_walker((Node *) tree, &params))
			return "node";
		oldcxt = MemoryContextSwitchTo(h->cxt);
		pe->params = bms_copy(params.ids);
		MemoryContextSwitchTo(oldcxt);
	}
	funcs_walker((Node *) tree, funcs);

	if (pe->type == pe->dsttype &&
		(pe->typmod == pe->dsttypmod || pe->dsttypmod == -1))
		return NULL;

	dst_domain = get_typtype(pe->dsttype) == TYPTYPE_DOMAIN;
	pinned = cast_pinned(pe->type, pe->dsttype);
	if (dst_domain || pe->dsttypmod != -1 || (!pinned && !null_const))
		return "cast";

	pe->cast = cast_get(pe->type, pe->typmod, pe->dsttype, &cast_tree);
	pe->cast_gen = pe->cast->gen;

	/* a mere relabeling needs no code: the value is the same Datum */
	if (cast_tree == NULL)
		return NULL;

	/*
	 * PL/pgSQL runs the cast of a NULL too.  Without a pg_cast row it is an
	 * I/O conversion, which does nothing for a NULL if the input function is
	 * strict; any other cast, and a user-made one, is its to run.
	 */
	if (!pinned)
	{
		Oid			input;
		Oid			ioparam;

		if (!IsA(cast_tree, CoerceViaIO))
			return "cast";
		getTypeInputInfo(pe->dsttype, &input, &ioparam);
		return func_strict(input) ? NULL : "cast";
	}
	funcs_walker((Node *) cast_tree, funcs);

	if (IsA(tree, Const))
	{
		Const	   *folded = cast_fold(cast_tree, (Const *) tree, pe->dsttype);

		if (folded != NULL)
		{
			oldcxt = MemoryContextSwitchTo(h->cxt);
			pe->folded = copyObject(folded);
			MemoryContextSwitchTo(oldcxt);
			pe->path = PJ_PATH_FOLD;
			return NULL;
		}
	}

	if (!plllvm_expr_type_repr(pe->type, &repr))
		return "cast";
	/* for the tests: a value of another representation than the placeholder */
	if (plllvm_debug_inject == PLLLVM_INJECT_PJ_BAD_CAST_REPR)
		repr = repr == PLLLVM_F64 ? PLLLVM_I64 : PLLLVM_F64;

	/* only a cast that cannot fail: a failure is for PL/pgSQL's own code */
	if (!((pe->type == INT4OID && (pe->dsttype == INT8OID ||
								   pe->dsttype == FLOAT8OID)) ||
		  (pe->type == INT8OID && pe->dsttype == FLOAT8OID)))
		return "cast";

	initStringInfo(&key);
	initStringInfo(&facts);
	if (!plllvm_expr_check_cast(cast_tree, &env->base, repr, &key, &facts,
								&why))
		return "cast";

	oldcxt = MemoryContextSwitchTo(h->cxt);
	pe->cast_tree = copyObject(cast_tree);
	MemoryContextSwitchTo(oldcxt);

	return NULL;
}

/*
 * The variable of a datum, if its Datum is one we can read: a variable of a
 * type passed by value
 */
static PLpgSQL_var *
arg_var(PLpgSQL_function *func, int dno)
{
	PLpgSQL_var *var;

	if (dno < 0 || dno >= func->ndatums)
		return NULL;
	var = (PLpgSQL_var *) func->datums[dno];
	if (var->dtype != PLPGSQL_DTYPE_VAR || !var->datatype->typbyval)
		return NULL;
	return var;
}

static void
env_init(PjEnv *env, PLpgSQL_function *func, PjHarvest *h)
{
	memset(env, 0, sizeof(PjEnv));
	env->base.param_check = param_check;
	env->base.param_emit = param_emit;
	env->base.call_check = call_check;
	env->base.call_emit = call_emit;
	env->base.bare_emit = bare_emit;
	env->base.arg = env;
	env->func = func;
	env->h = h;
}

/*
 * A Param is compilable when the interpreter would read one of our slots:
 * a variable of the type of the Param, passed by value
 */
static bool
param_check(plllvm_expr_env *base, const Param *p, StringInfo facts)
{
	PjEnv	   *env = (PjEnv *) base->arg;
	PLpgSQL_var *var;

	if (p->paramkind != PARAM_EXTERN)
		return false;
	var = arg_var(env->func, p->paramid - 1);
	if (var == NULL || var->datatype->typoid != p->paramtype)
		return false;
	appendStringInfo(facts, "%d:%u ", p->paramid, p->paramtype);
	return true;
}

static void
param_emit(plllvm_expr_env *base, plllvm_ir *ir, const Param *p,
		   plllvm_value *out)
{
	const char *value = plllvm_ir_tmp(ir);
	const char *isnull = plllvm_ir_tmp(ir);

	plllvm_ir_emit(ir, "%s = load i64, ptr %%v%d", value, p->paramid - 1);
	plllvm_ir_emit(ir, "%s = load i1, ptr %%n%d", isnull, p->paramid - 1);
	unbox(ir, value, isnull, p->paramtype, out);
}

/*
 * May the compiler call this function, or convert through the I/O functions,
 * as the executor would?  A volatile callee is refused by the caller
 * (admission), and an expression that needs a snapshot of its own is the
 * executor's.
 */
static bool
call_check(plllvm_expr_env *base, const Node *node)
{
	PjEnv	   *env = (PjEnv *) base->arg;
	int			nargs;

	if (env->need)
		return false;

	switch (nodeTag(node))
	{
		case T_FuncExpr:
			nargs = list_length(((const FuncExpr *) node)->args);
			break;
		case T_OpExpr:
			nargs = list_length(((const OpExpr *) node)->args);
			break;
		case T_CoerceViaIO:
			{
				const CoerceViaIO *io = (const CoerceViaIO *) node;
				Oid			input;
				Oid			ioparam;

				/* a NULL is not passed on, and a domain checks it */
				if (get_typtype(io->resulttype) == TYPTYPE_DOMAIN)
					return false;
				getTypeInputInfo(io->resulttype, &input, &ioparam);
				if (!func_strict(input))
					return false;
				nargs = 1;
				break;
			}
		default:
			return false;
	}
	if (nargs > FUNC_MAX_ARGS)
		return false;

	env->ncalls++;
	return true;
}

/* a CoerceViaIO is one call of the host, a function a call of its site */
static void
call_emit(plllvm_expr_env *base, plllvm_ir *ir, const Node *node,
		  const plllvm_value *args, int nargs, plllvm_value *out)
{
	PjEnv	   *env = (PjEnv *) base->arg;
	PjSiteDesc *desc = palloc0_object(PjSiteDesc);
	int			idx = list_length(env->sites);
	Oid			result;
	const char *datum;
	const char *flag;
	const char *byte = plllvm_ir_tmp(ir);

	desc->node = node;
	desc->nargs = nargs;
	switch (nodeTag(node))
	{
		case T_FuncExpr:
			desc->funcid = ((const FuncExpr *) node)->funcid;
			desc->collation = ((const FuncExpr *) node)->inputcollid;
			result = ((const FuncExpr *) node)->funcresulttype;
			break;
		case T_OpExpr:
			desc->funcid = ((const OpExpr *) node)->opfuncid;
			desc->collation = ((const OpExpr *) node)->inputcollid;
			result = ((const OpExpr *) node)->opresulttype;
			break;
		default:
			desc->kind = PJ_SITE_IO;
			result = ((const CoerceViaIO *) node)->resulttype;
			break;
	}
	env->sites = lappend(env->sites, desc);

	if (desc->kind == PJ_SITE_IO)
	{
		const char *z = plllvm_ir_tmp(ir);

		plllvm_ir_declare(ir, "declare i64 @plllvm_pj_io(ptr, i32, i64, i32)");
		plllvm_ir_emit(ir, "%s = zext i1 %s to i32", z, args[0].isnull);
		datum = plllvm_ir_tmp(ir);
		plllvm_ir_emit(ir, "%s = call i64 @plllvm_pj_io(ptr %%ctx, i32 %d, i64 %s, i32 %s)",
					   datum, idx, plllvm_expr_box(ir, &args[0]), z);
		flag = field_ptr(ir, "%ctx", offsetof(PjCtx, isnull));
	}
	else
	{
		const char *site = plllvm_ir_tmp(ir);
		const char *fcinfo = plllvm_ir_tmp(ir);

		plllvm_ir_declare(ir, "declare ptr @plllvm_pj_site(ptr, i32)");
		plllvm_ir_declare(ir, "declare i64 @plllvm_pj_invoke(ptr)");
		plllvm_ir_emit(ir, "%s = call ptr @plllvm_pj_site(ptr %%ctx, i32 %d)",
					   site, idx);
		plllvm_ir_emit(ir, "%s = load ptr, ptr %s", fcinfo, site);
		for (int i = 0; i < nargs; i++)
		{
			const char *z = plllvm_ir_tmp(ir);
			size_t		at = offsetof(FunctionCallInfoBaseData, args) +
				i * sizeof(NullableDatum);

			plllvm_ir_emit(ir, "store i64 %s, ptr %s", plllvm_expr_box(ir, &args[i]),
						   field_ptr(ir, fcinfo, at + offsetof(NullableDatum, value)));
			plllvm_ir_emit(ir, "%s = zext i1 %s to i8", z, args[i].isnull);
			plllvm_ir_emit(ir, "store i8 %s, ptr %s", z,
						   field_ptr(ir, fcinfo, at + offsetof(NullableDatum, isnull)));
		}
		datum = plllvm_ir_tmp(ir);
		plllvm_ir_emit(ir, "%s = call i64 @plllvm_pj_invoke(ptr %s)", datum, site);
		flag = field_ptr(ir, fcinfo, offsetof(FunctionCallInfoBaseData, isnull));
	}

	plllvm_ir_emit(ir, "%s = load i8, ptr %s", byte, flag);
	flag = plllvm_ir_tmp(ir);
	plllvm_ir_emit(ir, "%s = icmp ne i8 %s, 0", flag, byte);
	unbox(ir, datum, flag, result, out);
}

/*
 * An operator of the table as a call of its function: one fcinfo of the
 * harvest, a constant address.  Only a function that cannot re-enter, never
 * runs code of a user and allocates nothing is called this way.
 */
static const char *
bare_emit(plllvm_expr_env *base, plllvm_ir *ir, Oid funcid,
		  const char *const *args, int nargs)
{
	PjEnv	   *env = (PjEnv *) base->arg;
	FmgrInfo   *flinfo = MemoryContextAllocZero(env->h->cxt, sizeof(FmgrInfo));
	FunctionCallInfo fcinfo = MemoryContextAllocZero(env->h->cxt,
													 SizeForFunctionCallInfo(nargs));
	char	   *fc;
	const char *result = plllvm_ir_tmp(ir);

	fmgr_info_cxt(funcid, flinfo, env->h->cxt);
	InitFunctionCallInfoData(*fcinfo, flinfo, nargs, InvalidOid, NULL, NULL);
	fc = psprintf("inttoptr (i64 " UINT64_FORMAT " to ptr)",
				  (uint64) (uintptr_t) fcinfo);

	for (int i = 0; i < nargs; i++)
		plllvm_ir_emit(ir, "store i64 %s, ptr %s", args[i],
					   field_ptr(ir, fc,
								 offsetof(FunctionCallInfoBaseData, args) +
								 i * sizeof(NullableDatum) +
								 offsetof(NullableDatum, value)));
	plllvm_ir_emit(ir, "store i8 0, ptr %s",
				   field_ptr(ir, fc, offsetof(FunctionCallInfoBaseData, isnull)));
	plllvm_ir_emit(ir, "%s = call i64 inttoptr (i64 " UINT64_FORMAT " to ptr)(ptr %s)",
				   result, (uint64) (uintptr_t) flinfo->fn_addr, fc);

	return result;
}

/* a Datum of one of the types of the expression compiler, as its value */
static void
unbox(plllvm_ir *ir, const char *datum, const char *isnull, Oid type,
	  plllvm_value *out)
{
	const char *v = datum;

	switch (type)
	{
		case BOOLOID:
			out->repr = PLLLVM_I1;
			v = plllvm_ir_tmp(ir);
			plllvm_ir_emit(ir, "%s = icmp ne i64 %s, 0", v, datum);
			break;
		case INT4OID:
			out->repr = PLLLVM_I32;
			v = plllvm_ir_tmp(ir);
			plllvm_ir_emit(ir, "%s = trunc i64 %s to i32", v, datum);
			break;
		case INT8OID:
			out->repr = PLLLVM_I64;
			break;
		case FLOAT8OID:
			out->repr = PLLLVM_F64;
			v = plllvm_ir_tmp(ir);
			plllvm_ir_emit(ir, "%s = bitcast i64 %s to double", v, datum);
			break;
		default:
			out->repr = PLLLVM_DATUM;
	}

	out->v = v;
	out->isnull = isnull;
	out->type = type;
}

/*
 * Is there a pg_cast row for the pair that cannot be created or dropped?  A
 * cast made later than PL/pgSQL cached its own could differ from it, and
 * that cache cannot be read.
 */
static bool
cast_pinned(Oid srctype, Oid dsttype)
{
	HeapTuple	tup = SearchSysCache2(CASTSOURCETARGET,
									  ObjectIdGetDatum(srctype),
									  ObjectIdGetDatum(dsttype));
	bool		pinned = false;

	if (HeapTupleIsValid(tup))
	{
		pinned = ((Form_pg_cast) GETSTRUCT(tup))->oid < FirstUnpinnedObjectId;
		ReleaseSysCache(tup);
	}
	return pinned;
}

/*
 * The cast tree for (srctype, srctypmod) -> dsttype, built as
 * get_cast_hashentry() does (pl_exec.c) and rebuilt only when invalidated.
 * *tree is NULL for a relabeling.  May raise an ERROR, as the interpreter
 * would at the cast.
 */
static PjCast *
cast_get(Oid srctype, int32 srctypmod, Oid dsttype, Expr **tree)
{
	PjCastKey	key = {srctype, srctypmod, dsttype};
	PjCastEntry *entry;
	bool		found;

	if (casts == NULL)
	{
		HASHCTL		ctl = {0};

		ctl.keysize = sizeof(PjCastKey);
		ctl.entrysize = sizeof(PjCastEntry);
		ctl.hcxt = AllocSetContextCreate(TopMemoryContext,
										 "plllvm - pj casts context",
										 ALLOCSET_DEFAULT_SIZES);
		casts = hash_create("plllvm plpgsql_jit casts", 16, &ctl,
							HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
	}

	entry = hash_search(casts, &key, HASH_ENTER, &found);
	if (!found)
		memset(&entry->cast, 0, sizeof(PjCast));

	if (entry->cast.cexpr == NULL || !entry->cast.cexpr->is_valid)
	{
		Node	   *cast_expr;
		CachedExpression *cexpr;
		CaseTestExpr *placeholder = makeNode(CaseTestExpr);

		placeholder->typeId = srctype;
		placeholder->typeMod = srctypmod;
		placeholder->collation = get_typcollation(srctype);

		cast_expr = coerce_to_target_type(NULL, (Node *) placeholder,
										  srctype, dsttype, -1,
										  COERCION_PLPGSQL,
										  COERCE_IMPLICIT_CAST, -1);
		if (cast_expr == NULL)
			elog(ERROR, "no cast from type %u to %u", srctype, dsttype);

		/* built first: the old one stays if building raised an ERROR */
		cexpr = GetCachedExpression(cast_expr);
		if (entry->cast.cexpr != NULL)
			FreeCachedExpression(entry->cast.cexpr);
		entry->cast.cexpr = cexpr;
		entry->cast.gen++;
	}

	*tree = (Expr *) entry->cast.cexpr->expr;
	if (IsA(*tree, RelabelType) &&
		IsA(((RelabelType *) *tree)->arg, CaseTestExpr))
		*tree = NULL;

	return &entry->cast;
}

static bool
funcs_callback(Oid funcid, void *context)
{
	*(List **) context = list_append_unique_oid(*(List **) context, funcid);
	return false;
}

/*
 * The functions PL/pgSQL's executor checks EXECUTE for when it builds the
 * tree: not the I/O functions of a CoerceViaIO or the comparison functions of
 * a row comparison (execExpr.c), which check_functions_in_node() also reports
 */
static bool
funcs_walker(Node *node, List **funcs)
{
	if (node == NULL)
		return false;
	if (!IsA(node, CoerceViaIO) && !IsA(node, RowCompareExpr) &&
		check_functions_in_node(node, funcs_callback, funcs))
		return true;
	return expression_tree_walker(node, funcs_walker, funcs);
}

/*
 * Collect the datums of the Params of a tree; true if one is not a variable
 * of the function that the compiled code keeps in a slot
 */
static bool
params_walker(Node *node, PjParams *ctx)
{
	if (node == NULL)
		return false;

	if (IsA(node, Param))
	{
		Param	   *p = (Param *) node;
		PLpgSQL_var *var = p->paramkind == PARAM_EXTERN ?
			arg_var(ctx->func, p->paramid - 1) : NULL;

		if (var == NULL || var->datatype->typoid != p->paramtype)
			return true;
		ctx->ids = bms_add_member(ctx->ids, p->paramid - 1);
		return false;
	}

	return expression_tree_walker(node, params_walker, ctx);
}

/*
 * Fold the cast of a constant into a constant.  Only built-in, immutable
 * functions run, so no user code runs at translate time, and nothing that
 * reads a setting (the output of float8 reads extra_float_digits, date_in
 * is STABLE).  An ERROR from the evaluation declines the function, and
 * PL/pgSQL raises it at the cast.
 */
static Const *
cast_fold(Expr *cast_tree, const Const *src, Oid dsttype)
{
	List	   *funcs = NIL;
	Node	   *bound;
	Const	   *result;

	if (cast_has_io((Node *) cast_tree, NULL))
		return NULL;

	/* a function that is not strict runs for a NULL, whatever it does */
	funcs_walker((Node *) cast_tree, &funcs);
	foreach_oid(funcid, funcs)
	{
		if (funcid >= FirstUnpinnedObjectId ||
			(src->constisnull && !func_strict(funcid)))
			return NULL;
	}
	if (contain_mutable_functions((Node *) cast_tree))
		return NULL;

	bound = cast_bind((Node *) cast_tree, (void *) src);
	result = (Const *) eval_const_expressions(NULL, bound);

	if (!IsA(result, Const) || result->consttype != dsttype ||
		(!result->constisnull && !result->constbyval))
		return NULL;

	return result;
}

static bool
cast_has_io(Node *node, void *context)
{
	if (node == NULL)
		return false;
	if (IsA(node, CoerceViaIO) || IsA(node, ArrayCoerceExpr))
		return true;
	return expression_tree_walker(node, cast_has_io, context);
}

/* the cast tree with the constant in place of the CaseTestExpr */
static Node *
cast_bind(Node *node, void *context)
{
	if (node == NULL)
		return NULL;
	if (IsA(node, CaseTestExpr))
		return (Node *) copyObject((Const *) context);
	return expression_tree_mutator(node, cast_bind, context);
}

/*
 * Emit the code of a variant for the harvest, and compile it
 *
 * Returns false when plllvm.max_resident_compiles is reached; any other
 * failure raises an ERROR.
 */
PjEmitResult
plllvm_pj_emit(PLpgSQL_function *func, PjHarvest *h, PjVariant *v)
{
	MemoryContext cxt;
	MemoryContext oldcxt;
	PjEmit		em = {0};
	const char *entry;
	char	   *text;
	plllvm_jit_result result;
	bool		ok;
	bool		has_boxed = false;
	bool		has_compiled = false;
	bool		has_calls = false;

	em.all_boxed = v->codegen == PLLLVM_PJ_BOXED;
	foreach_ptr(PjExpr, pe, h->exprs)
	{
		if (pe->h1 != PJ_H1_READY)
			continue;
		if (expr_path(&em, pe) == PJ_PATH_BOXED)
			has_boxed = true;
		else
		{
			has_compiled = true;
			has_calls |= pe->ncalls > 0;
		}
	}

	/*
	 * Once the executor or any callee has run, a call cannot start again in
	 * the interpreter (a callee may send a message or run SQL, whatever it
	 * is), so code that runs them has no deopt point.
	 */
	if ((has_boxed || has_calls) && h->nunplanned > 0)
		return PJ_EMIT_WAITING;

	plllvm_jit_session_ensure();

	cxt = AllocSetContextCreate(CurrentMemoryContext,
								"plllvm - pj emit",
								ALLOCSET_DEFAULT_SIZES);
	oldcxt = MemoryContextSwitchTo(cxt);

	env_init(&em.env, func, h);
	em.env.base.no_native_ops = v->codegen == PLLLVM_PJ_V1;
	em.func = func;
	em.h = h;
	em.nopos = v->codegen == PLLLVM_PJ_NOPOS;
	em.ir = plllvm_ir_begin();

	plllvm_ir_declare(em.ir, "declare void @plllvm_cfi()");
	if (plllvm_debug_inject == PLLLVM_INJECT_PJ_BAD_SIGNATURE)
		plllvm_ir_emit(em.ir,
					   "define i64 @f(ptr %%fcinfo, ptr %%ctx, ptr %%extra) {");
	else
		plllvm_ir_emit(em.ir, "define i64 @f(ptr %%fcinfo, ptr %%ctx) {");
	entry = plllvm_ir_label(em.ir);
	begin_block(&em, entry);

	for (int dno = 0; dno < func->ndatums; dno++)
	{
		if (arg_var(func, dno) == NULL)
			continue;
		plllvm_ir_emit(em.ir, "%%v%d = alloca i64", dno);
		plllvm_ir_emit(em.ir, "%%n%d = alloca i1", dno);
	}
	foreach_int(id, h->fori)
	{
		plllvm_ir_emit(em.ir, "%%fc%d = alloca i32", id);
		plllvm_ir_emit(em.ir, "%%fe%d = alloca i32", id);
		plllvm_ir_emit(em.ir, "%%fs%d = alloca i32", id);
	}

	for (int dno = 0; dno < func->ndatums; dno++)
	{
		if (arg_var(func, dno) == NULL)
			continue;
		/* FOUND is false, other variables NULL, arguments are stored below */
		plllvm_ir_emit(em.ir, "store i64 0, ptr %%v%d", dno);
		plllvm_ir_emit(em.ir, "store i1 %s, ptr %%n%d",
					   dno == func->found_varno ? "false" : "true", dno);

		for (int i = 0; i < func->fn_nargs; i++)
		{
			const char *slot;
			const char *value;

			if (func->fn_argvarnos[i] != dno)
				continue;

			slot = field_ptr(em.ir, "%fcinfo",
							 offsetof(FunctionCallInfoBaseData, args) +
							 i * sizeof(NullableDatum) +
							 offsetof(NullableDatum, value));
			value = plllvm_ir_tmp(em.ir);
			plllvm_ir_emit(em.ir, "%s = load i64, ptr %s", value, slot);
			plllvm_ir_emit(em.ir, "store i64 %s, ptr %%v%d", value, dno);
			/* the handler dispatched NULL arguments to the interpreter */
			plllvm_ir_emit(em.ir, "store i1 false, ptr %%n%d", dno);
		}
	}

	poll(&em, -1);
	emit_stmt(&em, (PLpgSQL_stmt *) func->action);

	if (em.open)
	{
		plllvm_ir_declare(em.ir, "declare void @plllvm_pj_no_return()");
		set_pos(&em, PJ_POS_NONE);
		plllvm_ir_emit(em.ir, "call void @plllvm_pj_no_return()");
		plllvm_ir_emit(em.ir, "unreachable");
	}

	plllvm_ir_emit(em.ir, "}");
	text = plllvm_ir_end(em.ir);

	ok = plllvm_jit_compile_pj(text, v->opt_level, &result);

	MemoryContextSwitchTo(h->cxt);
	v->ir = pstrdup(text);
	MemoryContextSwitchTo(oldcxt);
	if (ok)
	{
		v->nsites = list_length(em.env.sites);
		v->sites = MemoryContextAlloc(h->cxt, sizeof(PjSiteDesc) * Max(v->nsites, 1));
		for (int i = 0; i < v->nsites; i++)
			v->sites[i] = *(PjSiteDesc *) list_nth(em.env.sites, i);
	}

	if (!ok)
	{
		if (result.capped)
		{
			MemoryContextDelete(cxt);
			return PJ_EMIT_CAPPED;
		}
		ereport(ERROR,
				(errcode(result.sqlerrcode),
				 errmsg_internal("%s", result.errmsg)));
	}

	MemoryContextDelete(cxt);

	v->mod = result.mod;
	v->code = (PjCode) result.mod->addr;
	v->native = has_compiled;
	v->boxed = has_boxed;
	v->restartable = !has_boxed && !has_calls;
	return PJ_EMIT_OK;
}

static void
emit_stmts(PjEmit *em, List *stmts)
{
	foreach_ptr(PLpgSQL_stmt, stmt, stmts)
	{
		emit_stmt(em, stmt);
		if (stmt_terminal(stmt))
			break;
	}
}

/*
 * The statements of a loop body.  A poll comes once per iteration, after
 * the position of the first statement, which is where PL/pgSQL's
 * CHECK_FOR_INTERRUPTS reports a cancel; an empty body has no statement for
 * it (exec_stmts).
 */
static void
emit_body(PjEmit *em, List *body, int stmtid)
{
	if (body == NIL)
		poll(em, stmtid);
	else
		em->poll_pending = true;
	emit_stmts(em, body);
}

static void
emit_stmt(PjEmit *em, PLpgSQL_stmt *stmt)
{
	reopen(em);

	stmt_enter(em, stmt);

	switch (stmt->cmd_type)
	{
		case PLPGSQL_STMT_BLOCK:
			emit_block(em, (PLpgSQL_stmt_block *) stmt);
			break;
		case PLPGSQL_STMT_ASSIGN:
			emit_assign(em, (PLpgSQL_stmt_assign *) stmt);
			break;
		case PLPGSQL_STMT_IF:
			emit_if(em, (PLpgSQL_stmt_if *) stmt);
			break;
		case PLPGSQL_STMT_LOOP:
		case PLPGSQL_STMT_WHILE:
			emit_loop(em, stmt);
			break;
		case PLPGSQL_STMT_FORI:
			emit_fori(em, (PLpgSQL_stmt_fori *) stmt);
			break;
		case PLPGSQL_STMT_EXIT:
			emit_exit(em, (PLpgSQL_stmt_exit *) stmt);
			break;
		case PLPGSQL_STMT_RETURN:
			emit_return(em, (PLpgSQL_stmt_return *) stmt);
			break;
		default:
			elog(ERROR, "unexpected statement type: %d", (int) stmt->cmd_type);
	}
}

/*
 * The variables of the block start NULL at every entry, then take their
 * default (exec_stmt_block)
 */
static void
emit_block(PjEmit *em, PLpgSQL_stmt_block *block)
{
	PLpgSQL_function *func = em->func;
	const char *end = NULL;

	for (int i = 0; i < block->n_initvars; i++)
	{
		int			dno = block->initvarnos[i];
		PLpgSQL_var *var = (PLpgSQL_var *) func->datums[dno];

		set_pos(em, var->default_val != NULL ? em->h->nbase + em->next_expr :
				func->nstatements + 1 + dno);
		store_var(em, dno, "0", "true");
		if (var->default_val != NULL)
		{
			const char *datum;
			const char *isnull;

			expr_value(em, var->default_val, &datum, &isnull);
			check_not_null(em, var, isnull);
			store_var(em, dno, datum, isnull);
		}
	}

	if (block->label != NULL)
	{
		end = plllvm_ir_label(em->ir);
		frame_push(&em->frames, block->label, false, false)->exit_to = end;
	}

	emit_stmts(em, block->body);

	if (end != NULL)
	{
		frame_pop(&em->frames);
		if (em->open)
			branch(em, end);
		begin_block(em, end);
	}
}

static void
emit_assign(PjEmit *em, PLpgSQL_stmt_assign *stmt)
{
	PLpgSQL_var *var = (PLpgSQL_var *) em->func->datums[stmt->varno];
	const char *datum;
	const char *isnull;

	expr_value(em, stmt->expr, &datum, &isnull);
	check_not_null(em, var, isnull);
	store_var(em, stmt->varno, datum, isnull);
}

static void
emit_if(PjEmit *em, PLpgSQL_stmt_if *stmt)
{
	const char *done = plllvm_ir_label(em->ir);
	List	   *conds = list_make1(stmt->cond);
	List	   *bodies = list_make1(stmt->then_body);
	int			boxed0 = em->nboxed;

	foreach_ptr(PLpgSQL_if_elsif, elif, stmt->elsif_list)
	{
		conds = lappend(conds, elif->cond);
		bodies = lappend(bodies, elif->stmts);
	}

	for (int i = 0; i < list_length(conds); i++)
	{
		PLpgSQL_expr *cond = list_nth(conds, i);
		const char *taken = expr_taken(em, cond);
		const char *then = plllvm_ir_label(em->ir);
		const char *next = plllvm_ir_label(em->ir);
		bool		pending = em->poll_pending;

		branch_if(em, taken, then, next);
		begin_block(em, then);
		emit_stmts(em, list_nth(bodies, i));
		if (em->open)
			branch(em, done);
		begin_block(em, next);
		em->poll_pending = pending;
	}

	emit_stmts(em, stmt->else_body);
	if (em->open)
		branch(em, done);
	begin_block(em, done);

	poll_if_boxed(em, boxed0);
}

/*
 * LOOP and WHILE: a head that EXIT leaves and CONTINUE returns to, the
 * condition of a WHILE at its head
 */
static void
emit_loop(PjEmit *em, PLpgSQL_stmt *stmt)
{
	bool		is_while = stmt->cmd_type == PLPGSQL_STMT_WHILE;
	PLpgSQL_stmt_while *wh = (PLpgSQL_stmt_while *) stmt;
	PLpgSQL_stmt_loop *lp = (PLpgSQL_stmt_loop *) stmt;
	const char *head = plllvm_ir_label(em->ir);
	const char *body = plllvm_ir_label(em->ir);
	const char *end = plllvm_ir_label(em->ir);
	int			boxed0 = em->nboxed;
	PjFrame    *frame;

	frame = frame_push(&em->frames, is_while ? wh->label : lp->label, true,
					   false);
	frame->exit_to = end;
	frame->cont_to = head;

	branch(em, head);
	begin_block(em, head);
	if (is_while)
	{
		/* an error after the body reports the WHILE again */
		if (cond_may_raise(em))
			set_pos(em, em->h->nbase + em->next_expr);
		branch_if(em, expr_taken(em, wh->cond), body, end);
		begin_block(em, body);
	}
	emit_body(em, is_while ? wh->body : lp->body, stmt->stmtid);
	if (em->open)
		branch(em, head);

	frame_pop(&em->frames);
	begin_block(em, end);
	poll_if_boxed(em, boxed0);
}

/*
 * Can the next expression raise?  The condition of a WHILE needs its
 * position stored again after the body, but not if all it does is compare:
 * the store is not dead to LLVM, which sees the poll after it.
 */
static bool
cond_may_raise(PjEmit *em)
{
	PjExpr	   *pe = list_nth(em->h->exprs, em->next_expr);

	if (pe->h1 != PJ_H1_READY)
		return false;
	return expr_path(em, pe) == PJ_PATH_BOXED ||
		(pe->path == PJ_PATH_NATIVE && may_raise((Node *) pe->tree, NULL));
}

static bool
may_raise(Node *node, void *context)
{
	if (node == NULL)
		return false;

	switch (nodeTag(node))
	{
		case T_Param:
		case T_Const:
		case T_BoolExpr:
		case T_NullTest:
		case T_BooleanTest:
			break;
		case T_OpExpr:
			{
				Oid			opno = ((OpExpr *) node)->opno;
				Oid			negator = get_negator(opno);

				if (get_op_index_interpretation(opno) == NIL &&
					(!OidIsValid(negator) ||
					 get_op_index_interpretation(negator) == NIL))
					return true;
				break;
			}
		default:
			return true;
	}

	return expression_tree_walker(node, may_raise, context);
}

/*
 * exec_stmt_fori: the bounds once, then a counter of our own, so that the
 * body may assign the variable
 */
static void
emit_fori(PjEmit *em, PLpgSQL_stmt_fori *stmt)
{
	plllvm_ir  *ir = em->ir;
	int			id = stmt->stmtid;
	const char *cmp = stmt->reverse ? "slt" : "sgt";
	const char *head = plllvm_ir_label(ir);
	const char *next = plllvm_ir_label(ir);
	const char *update = plllvm_ir_label(ir);
	const char *zero = plllvm_ir_label(ir);
	const char *more = plllvm_ir_label(ir);
	const char *done = plllvm_ir_label(ir);
	PjFrame    *frame;
	const char *datum;
	const char *isnull;
	const char *lo;
	const char *hi;
	const char *step;
	const char *c;
	const char *e;
	const char *out;
	int			boxed0 = em->nboxed;

	plllvm_ir_declare(ir, "declare void @plllvm_pj_for_error(i32)");

	expr_value(em, stmt->lower, &datum, &isnull);
	for_check(em, isnull, PJ_FOR_LOWER_NULL);
	lo = plllvm_ir_tmp(ir);
	plllvm_ir_emit(ir, "%s = trunc i64 %s to i32", lo, datum);

	expr_value(em, stmt->upper, &datum, &isnull);
	for_check(em, isnull, PJ_FOR_UPPER_NULL);
	hi = plllvm_ir_tmp(ir);
	plllvm_ir_emit(ir, "%s = trunc i64 %s to i32", hi, datum);

	if (stmt->step != NULL)
	{
		const char *bad = plllvm_ir_tmp(ir);

		expr_value(em, stmt->step, &datum, &isnull);
		for_check(em, isnull, PJ_FOR_BY_NULL);
		step = plllvm_ir_tmp(ir);
		plllvm_ir_emit(ir, "%s = trunc i64 %s to i32", step, datum);
		plllvm_ir_emit(ir, "%s = icmp sle i32 %s, 0", bad, step);
		for_check(em, bad, PJ_FOR_BY_NOT_POSITIVE);
	}
	else
		step = "1";

	plllvm_ir_emit(ir, "store i32 %s, ptr %%fc%d", lo, id);
	plllvm_ir_emit(ir, "store i32 %s, ptr %%fe%d", hi, id);
	plllvm_ir_emit(ir, "store i32 %s, ptr %%fs%d", step, id);

	/* FOUND is false when the body never runs, true after any exit */
	out = plllvm_ir_tmp(ir);
	plllvm_ir_emit(ir, "%s = icmp %s i32 %s, %s", out, cmp, lo, hi);
	branch_if(em, out, zero, head);

	frame = frame_push(&em->frames, stmt->label, true, true);
	frame->exit_to = more;
	frame->cont_to = next;

	begin_block(em, head);
	c = plllvm_ir_tmp(ir);
	plllvm_ir_emit(ir, "%s = load i32, ptr %%fc%d", c, id);
	datum = plllvm_ir_tmp(ir);
	plllvm_ir_emit(ir, "%s = sext i32 %s to i64", datum, c);
	store_var(em, stmt->var->dno, datum, "false");
	emit_body(em, stmt->body, stmt->stmtid);
	if (em->open)
		branch(em, next);

	frame_pop(&em->frames);

	/* step, unless it would overflow, in which case the loop ends */
	begin_block(em, next);
	{
		const char *s = plllvm_ir_tmp(ir);
		const char *lim = plllvm_ir_tmp(ir);
		const char *ov = plllvm_ir_tmp(ir);
		const char *nc = plllvm_ir_tmp(ir);

		c = plllvm_ir_tmp(ir);
		plllvm_ir_emit(ir, "%s = load i32, ptr %%fc%d", c, id);
		plllvm_ir_emit(ir, "%s = load i32, ptr %%fs%d", s, id);
		if (stmt->reverse)
			plllvm_ir_emit(ir, "%s = add i32 %s, -2147483648", lim, s);
		else
			plllvm_ir_emit(ir, "%s = sub i32 2147483647, %s", lim, s);
		plllvm_ir_emit(ir, "%s = icmp %s i32 %s, %s",
					   ov, stmt->reverse ? "slt" : "sgt", c, lim);
		branch_if(em, ov, more, update);

		begin_block(em, update);
		plllvm_ir_emit(ir, "%s = %s i32 %s, %s", nc,
					   stmt->reverse ? "sub" : "add", c, s);
		plllvm_ir_emit(ir, "store i32 %s, ptr %%fc%d", nc, id);
		e = plllvm_ir_tmp(ir);
		out = plllvm_ir_tmp(ir);
		plllvm_ir_emit(ir, "%s = load i32, ptr %%fe%d", e, id);
		plllvm_ir_emit(ir, "%s = icmp %s i32 %s, %s", out, cmp, nc, e);
		branch_if(em, out, more, head);
	}

	begin_block(em, zero);
	set_found(em, false);
	branch(em, done);
	begin_block(em, more);
	set_found(em, true);
	branch(em, done);
	begin_block(em, done);
	poll_if_boxed(em, boxed0);
}

static void
emit_exit(PjEmit *em, PLpgSQL_stmt_exit *stmt)
{
	PjFrame    *target;
	bool		crossed;
	const char *skip = NULL;

	if (stmt->cond != NULL)
	{
		const char *taken = expr_taken(em, stmt->cond);
		const char *go = plllvm_ir_label(em->ir);

		skip = plllvm_ir_label(em->ir);
		branch_if(em, taken, go, skip);
		begin_block(em, go);
	}

	target = frame_find(em->frames, stmt->label, !stmt->is_exit, &crossed);
	Assert(target != NULL);

	/* a FOR that is left sets FOUND (exec_stmt_fori) */
	if (crossed)
		set_found(em, true);
	branch(em, stmt->is_exit ? target->exit_to : target->cont_to);

	if (skip != NULL)
		begin_block(em, skip);
}

static void
emit_return(PjEmit *em, PLpgSQL_stmt_return *stmt)
{
	plllvm_ir  *ir = em->ir;
	const char *datum = "0";
	const char *isnull = "false";
	const char *at;
	const char *z;

	/*
	 * the handler copies a result passed by reference before anything resets
	 * it
	 */
	em->in_return = true;
	if (stmt->retvarno >= 0)
		expr_value(em, stmt, &datum, &isnull);
	else if (stmt->expr != NULL)
		expr_value(em, stmt->expr, &datum, &isnull);
	else if (em->func->fn_rettype != VOIDOID)
		isnull = "true";
	em->in_return = false;

	at = field_ptr(ir, "%fcinfo", offsetof(FunctionCallInfoBaseData, isnull));
	z = plllvm_ir_tmp(ir);
	plllvm_ir_emit(ir, "%s = zext i1 %s to i8", z, isnull);
	plllvm_ir_emit(ir, "store i8 %s, ptr %s", z, at);
	plllvm_ir_emit(ir, "ret i64 %s", datum);
	em->open = false;
}

/*
 * The next expression of the walk, as a Datum and a null flag.  An
 * expression that is not planned yet leaves the call to the interpreter.
 */
static void
expr_value(PjEmit *em, const void *owner, const char **datum,
		   const char **isnull)
{
	plllvm_ir  *ir = em->ir;
	int			index = em->next_expr++;
	PjExpr	   *pe = list_nth(em->h->exprs, index);

	if (pe->owner != owner)
		elog(ERROR, "plpgsql_jit: expression %d out of order", index);

	if (pe->h1 != PJ_H1_READY)
	{
		const char *at = field_ptr(ir, "%ctx", offsetof(PjCtx, deopt));

		plllvm_ir_emit(ir, "store i32 %d, ptr %s", index + 1, at);
		plllvm_ir_emit(ir, "ret i64 0");
		em->open = false;
		reopen(em);
		*datum = "0";
		*isnull = "true";
		return;
	}

	if (pe->path == PJ_PATH_FOLD)
	{
		*datum = psprintf(INT64_FORMAT, (int64) pe->folded->constvalue);
		*isnull = pe->folded->constisnull ? "true" : "false";
		return;
	}

	if (pe->path == PJ_PATH_MOVE && pe->cast_tree == NULL)
	{
		/* the Datum as it is, of any type passed by value */
		if (IsA(pe->tree, Const))
		{
			const Const *c = (const Const *) pe->tree;

			*datum = psprintf(INT64_FORMAT, (int64) c->constvalue);
			*isnull = c->constisnull ? "true" : "false";
		}
		else
		{
			int			dno = ((const Param *) pe->tree)->paramid - 1;

			*datum = plllvm_ir_tmp(ir);
			*isnull = plllvm_ir_tmp(ir);
			plllvm_ir_emit(ir, "%s = load i64, ptr %%v%d", *datum, dno);
			plllvm_ir_emit(ir, "%s = load i1, ptr %%n%d", *isnull, dno);
		}
		return;
	}

	{
		plllvm_value val;

		/* the position of an expression that can raise names it */
		if ((expr_path(em, pe) == PJ_PATH_BOXED ||
			 may_raise((Node *) pe->tree, NULL)) &&
			em->cur != em->h->nbase + index)
			set_pos(em, em->h->nbase + index);

		if (expr_path(em, pe) == PJ_PATH_BOXED)
		{
			boxed_value(em, index, pe, datum, isnull);
			if (pe->cast_tree == NULL)
				return;
			unbox(ir, *datum, *isnull, pe->type, &val);
		}
		else
		{
			plllvm_expr_emit(ir, pe->tree, &em->env.base, &val);
			if (pe->ncalls > 0)
				site_done(em, index, pe);
		}

		if (pe->cast_tree != NULL)
		{
			plllvm_value src = val;

			plllvm_expr_emit_cast(ir, pe->cast_tree, &em->env.base, &src, &val);
		}
		*datum = plllvm_expr_box(ir, &val);
		*isnull = val.isnull;
	}
}

/* what the code does with an expression: path, but for pj_codegen = boxed */
static PjPath
expr_path(PjEmit *em, const PjExpr *pe)
{
	if (pe->path == PJ_PATH_NATIVE && em->all_boxed)
		return PJ_PATH_BOXED;
	return pe->path;
}

/*
 * Run the expression in the executor: store the variables it reads into the
 * parameters, evaluate, and reset the memory the evaluation used once the
 * value is out (a RETURN is the handler's to copy)
 */
static void
boxed_value(PjEmit *em, int index, const PjExpr *pe, const char **datum,
			const char **isnull)
{
	plllvm_ir  *ir = em->ir;
	const char *raw = plllvm_ir_tmp(ir);
	const char *flag = plllvm_ir_tmp(ir);
	const char *null = plllvm_ir_tmp(ir);
	int			dno = -1;

	plllvm_ir_declare(ir, "declare ptr @plllvm_pj_params(ptr)");
	plllvm_ir_declare(ir, "declare i64 @plllvm_pj_boxed_eval(ptr, i32)");
	plllvm_ir_declare(ir, "declare void @plllvm_pj_boxed_reset(ptr)");

	if (pe->params != NULL)
	{
		const char *params = plllvm_ir_tmp(ir);

		plllvm_ir_emit(ir, "%s = call ptr @plllvm_pj_params(ptr %%ctx)",
					   params);
		while ((dno = bms_next_member(pe->params, dno)) >= 0)
		{
			const char *value = plllvm_ir_tmp(ir);
			const char *n = plllvm_ir_tmp(ir);
			const char *z = plllvm_ir_tmp(ir);
			size_t		at = dno * sizeof(ParamExternData);

			plllvm_ir_emit(ir, "%s = load i64, ptr %%v%d", value, dno);
			plllvm_ir_emit(ir, "store i64 %s, ptr %s", value,
						   field_ptr(ir, params,
									 at + offsetof(ParamExternData, value)));
			plllvm_ir_emit(ir, "%s = load i1, ptr %%n%d", n, dno);
			plllvm_ir_emit(ir, "%s = zext i1 %s to i8", z, n);
			plllvm_ir_emit(ir, "store i8 %s, ptr %s", z,
						   field_ptr(ir, params,
									 at + offsetof(ParamExternData, isnull)));
		}
	}

	plllvm_ir_emit(ir, "%s = call i64 @plllvm_pj_boxed_eval(ptr %%ctx, i32 %d)",
				   raw, index);
	plllvm_ir_emit(ir, "%s = load i8, ptr %s", flag,
				   field_ptr(ir, "%ctx", offsetof(PjCtx, isnull)));
	plllvm_ir_emit(ir, "%s = icmp ne i8 %s, 0", null, flag);
	if (!em->in_return)
		plllvm_ir_emit(ir, "call void @plllvm_pj_boxed_reset(ptr %%ctx)");

	/* a poll before the next statement, as PL/pgSQL's */
	em->nboxed++;
	em->poll_pending = true;

	*datum = raw;
	*isnull = null;
}

/*
 * After an expression with calls: what the evaluation of the executor does
 * once its value is out, but a RETURN's value is the handler's to copy, so
 * it is not freed.  The callee may have run user code, so EXECUTE is checked
 * again, and a poll comes before the next statement.
 */
static void
site_done(PjEmit *em, int index, const PjExpr *pe)
{
	int			flags = PJ_DONE_RECHECK | (em->in_return ? 0 : PJ_DONE_RESET);

	em->nboxed++;
	em->poll_pending = true;

	plllvm_ir_declare(em->ir, "declare void @plllvm_pj_site_done(ptr, i32, i32)");
	plllvm_ir_emit(em->ir, "call void @plllvm_pj_site_done(ptr %%ctx, i32 %d, i32 %d)",
				   index, flags);
}

/* is the next expression true? NULL is not */
static const char *
expr_taken(PjEmit *em, const void *owner)
{
	plllvm_ir  *ir = em->ir;
	const char *datum;
	const char *isnull;
	const char *nz = plllvm_ir_tmp(ir);
	const char *nn = plllvm_ir_tmp(ir);
	const char *taken = plllvm_ir_tmp(ir);

	expr_value(em, owner, &datum, &isnull);
	plllvm_ir_emit(ir, "%s = icmp ne i64 %s, 0", nz, datum);
	plllvm_ir_emit(ir, "%s = xor i1 %s, true", nn, isnull);
	plllvm_ir_emit(ir, "%s = and i1 %s, %s", taken, nz, nn);
	return taken;
}

static void
store_var(PjEmit *em, int dno, const char *datum, const char *isnull)
{
	plllvm_ir_emit(em->ir, "store i64 %s, ptr %%v%d", datum, dno);
	plllvm_ir_emit(em->ir, "store i1 %s, ptr %%n%d", isnull, dno);
}

/* a NOT NULL variable takes no NULL (exec_assign_value) */
static void
check_not_null(PjEmit *em, PLpgSQL_var *var, const char *isnull)
{
	plllvm_ir  *ir = em->ir;
	const char *bad = plllvm_ir_label(ir);
	const char *ok = plllvm_ir_label(ir);
	char	   *name;

	if (!var->notnull)
		return;

	name = MemoryContextStrdup(em->h->cxt, var->refname);
	plllvm_ir_declare(ir, "declare void @plllvm_pj_not_null(ptr)");
	branch_if(em, isnull, bad, ok);
	begin_block(em, bad);
	/* the expression is done: the error is the statement's */
	if (!em->nopos)
	{
		PjExpr	   *last = list_nth(em->h->exprs, em->next_expr - 1);

		plllvm_ir_emit(ir, "store i32 %d, ptr %%ctx", last->pos);
	}
	plllvm_ir_emit(ir,
				   "call void @plllvm_pj_not_null(ptr inttoptr (i64 "
				   UINT64_FORMAT " to ptr))",
				   (uint64) (uintptr_t) name);
	plllvm_ir_emit(ir, "unreachable");
	em->open = false;
	begin_block(em, ok);
}

/* raise the error what of a FOR, if failed is true */
static void
for_check(PjEmit *em, const char *failed, PjForError what)
{
	plllvm_ir  *ir = em->ir;
	const char *bad = plllvm_ir_label(ir);
	const char *ok = plllvm_ir_label(ir);

	branch_if(em, failed, bad, ok);
	begin_block(em, bad);
	/* the bound is done: the error is the statement's */
	if (!em->nopos)
	{
		PjExpr	   *last = list_nth(em->h->exprs, em->next_expr - 1);

		plllvm_ir_emit(ir, "store i32 %d, ptr %%ctx", last->pos);
	}
	plllvm_ir_emit(ir, "call void @plllvm_pj_for_error(i32 %d)", (int) what);
	plllvm_ir_emit(ir, "unreachable");
	em->open = false;
	begin_block(em, ok);
}

static void
set_found(PjEmit *em, bool value)
{
	store_var(em, em->func->found_varno, value ? "1" : "0", "false");
}

static void
set_pos(PjEmit *em, int index)
{
	if (!em->nopos)
		plllvm_ir_emit(em->ir, "store i32 %d, ptr %%ctx", index);
	em->cur = index;
}

/*
 * The position of the statement, where PL/pgSQL's err_stmt is while it runs
 */
static void
stmt_enter(PjEmit *em, PLpgSQL_stmt *stmt)
{
	int			index = stmt->stmtid;

	/* the statement's first expression names the position of both */
	if (em->next_expr < list_length(em->h->exprs) &&
		((PjExpr *) list_nth(em->h->exprs, em->next_expr))->pos == stmt->stmtid)
		index = em->h->nbase + em->next_expr;
	set_pos(em, index);
	if (em->poll_pending)
	{
		em->poll_pending = false;
		poll(em, stmt->stmtid);
	}
}

/*
 * A cancel is no error of an expression: stmtid, or none, is the position
 * while the interrupt is processed
 */
static void
poll(PjEmit *em, int stmtid)
{
	if (em->nopos || stmtid < 0)
	{
		plllvm_ir_emit(em->ir, "call void @plllvm_cfi()");
		return;
	}
	plllvm_ir_declare(em->ir, "declare void @plllvm_pj_cfi(ptr, i32)");
	plllvm_ir_emit(em->ir, "call void @plllvm_pj_cfi(ptr %%ctx, i32 %d)",
				   stmtid);
}

/* some path to here may have run the executor since boxed0 */
static void
poll_if_boxed(PjEmit *em, int boxed0)
{
	if (em->nboxed != boxed0)
		em->poll_pending = true;
}

static void
begin_block(PjEmit *em, const char *label)
{
	plllvm_ir_block(em->ir, label);
	em->open = true;
	em->cur = -1;
}

static void
branch(PjEmit *em, const char *label)
{
	plllvm_ir_emit(em->ir, "br label %%%s", label);
	em->open = false;
}

static void
branch_if(PjEmit *em, const char *cond, const char *yes, const char *no)
{
	plllvm_ir_emit(em->ir, "br i1 %s, label %%%s, label %%%s", cond, yes, no);
	em->open = false;
}

/* code after a terminator goes to a block that nothing reaches */
static void
reopen(PjEmit *em)
{
	if (!em->open)
		begin_block(em, plllvm_ir_label(em->ir));
}

static const char *
field_ptr(plllvm_ir *ir, const char *base, size_t offset)
{
	const char *addr = plllvm_ir_tmp(ir);

	plllvm_ir_emit(ir, "%s = getelementptr inbounds i8, ptr %s, i64 %zu",
				   addr, base, offset);
	return addr;
}
