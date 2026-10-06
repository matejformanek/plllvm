/*-------------------------------------------------------------------------
 *
 * plllvm_ir.c
 *
 *			  building a module of LLVM IR as text
 *
 * by Matěj Formánek 2026
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "lib/stringinfo.h"
#include "nodes/pg_list.h"

#include "plllvm_ir.h"

struct plllvm_ir
{
	StringInfoData decls;
	StringInfoData body;
	List	   *declared;		/* the declare lines so far */
	int			ntmp;
	int			nlabel;
	const char *current;		/* label of the current block */
};


plllvm_ir *
plllvm_ir_begin(void)
{
	plllvm_ir  *ir = palloc0_object(plllvm_ir);

	initStringInfo(&ir->decls);
	initStringInfo(&ir->body);
	return ir;
}

/*
 * A fresh SSA name
 */
const char *
plllvm_ir_tmp(plllvm_ir *ir)
{
	return psprintf("%%t%d", ++ir->ntmp);
}

/*
 * A fresh block name, without the %
 */
const char *
plllvm_ir_label(plllvm_ir *ir)
{
	return psprintf("L%d", ++ir->nlabel);
}

/*
 * Start a block; the caller has terminated the previous one
 */
void
plllvm_ir_block(plllvm_ir *ir, const char *label)
{
	appendStringInfo(&ir->body, "%s:\n", label);
	ir->current = label;
}

/*
 * The block the next instruction goes to, for the incoming edges of a phi
 */
const char *
plllvm_ir_current(plllvm_ir *ir)
{
	Assert(ir->current != NULL);
	return ir->current;
}

/*
 * One line of IR
 */
void
plllvm_ir_emit(plllvm_ir *ir, const char *fmt, ...)
{
	for (;;)
	{
		va_list		args;
		int			needed;

		va_start(args, fmt);
		needed = appendStringInfoVA(&ir->body, fmt, args);
		va_end(args);
		if (needed == 0)
			break;
		enlargeStringInfo(&ir->body, needed);
	}
	appendStringInfoChar(&ir->body, '\n');
}

/*
 * A "declare" line; repeating one is a no-op
 */
void
plllvm_ir_declare(plllvm_ir *ir, const char *decl)
{
	foreach_ptr(char, d, ir->declared)
	{
		if (strcmp(d, decl) == 0)
			return;
	}
	ir->declared = lappend(ir->declared, pstrdup(decl));
	appendStringInfo(&ir->decls, "%s\n", decl);
}

/*
 * The module: declarations, then the body
 */
char *
plllvm_ir_end(plllvm_ir *ir)
{
	appendStringInfo(&ir->decls, "\n%s", ir->body.data);
	return ir->decls.data;
}
