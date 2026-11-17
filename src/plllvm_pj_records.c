/*-------------------------------------------------------------------------
 *
 * plllvm_pj_records.c
 *
 *			  plpgsql_jit: the result of a function with a composite type
 *
 * by Matěj Formánek 2026
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) What plpgsql_exec_function() does with a composite result, and
 *    coerce_function_result_tuple() and make_tuple_from_row() under it.  It
 *    is PL/pgSQL's logic again, since its helpers are static and a function
 *    that returns a row needs it at every exit: tools/pl-drift lists what
 *    follows and fails when the source of PostgreSQL changes it.
 *
 * 2) Compiled code has no SPI connection, and a call that only returns a row
 *    must not make one.  So SPI_returntuple() and SPI_datumTransfer() give
 *    way to heap_copy_tuple_as_datum() and the datumCopy() of the handler;
 *    what SPI_returntuple() does beyond the copy, a typmod for a RECORD
 *    tupdesc, stays.  Whatever is made here lives in the datum context of
 *    the level, which the handler resets once it has copied the result.
 *
 * 3) A result that is an expanded record (a callee returned one) is
 *    flattened by the detoast of DatumGetHeapTupleHeader(), where PL/pgSQL
 *    tells the two apart: the tuple is the same.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/htup_details.h"
#include "access/tupconvert.h"
#include "funcapi.h"
#include "utils/lsyscache.h"
#include "utils/typcache.h"

#include "plllvm.h"
#include "plllvm_pj.h"

/*
 * The row of the OUT parameters: values and nulls, as the code has them in
 * its slots, formed over the descriptor of the harvest.  It is blessed here,
 * on first use; PL/pgSQL blesses its own copy at its first return, and
 * descriptors that agree get one typmod.
 */
Datum
plllvm_pj_ret_row(PjCtx *ctx, Datum *values, bool *nulls)
{
	PjHarvest  *h = ctx->harvest;
	PjLevel    *lv = plllvm_pj_level(ctx);
	MemoryContext oldcxt;
	HeapTuple	tuple;
	Datum		result;

	BlessTupleDesc(h->rowdesc);

	oldcxt = MemoryContextSwitchTo(lv->datum_cxt);
	tuple = heap_form_tuple(h->rowdesc, values, nulls);
	result = HeapTupleGetDatum(tuple);
	MemoryContextSwitchTo(oldcxt);

	return result;
}

/*
 * The value of a RETURN as the declared composite result: the conversion at
 * the end of plpgsql_exec_function().  The value, of valtype, is not NULL
 * unless isnull says so, and a NULL is returned as it is.
 */
Datum
plllvm_pj_ret_tuple(PjCtx *ctx, FunctionCallInfo fcinfo, Datum value,
					bool isnull, Oid valtype)
{
	PjLevel    *lv;
	MemoryContext oldcxt;
	Oid			resulttype;
	TupleDesc	tupdesc;
	TupleDesc	retdesc;
	TupleConversionMap *tupmap;
	HeapTupleData tmptup;
	HeapTupleHeader td;
	HeapTuple	rettup;
	Datum		result;

	if (isnull)
		return (Datum) 0;

	/* the harvest declined a value that is no row: PL/pgSQL raises that */
	if (!type_is_rowtype(valtype))
		elog(ERROR, "plpgsql_jit: a value of type %u returned as a row", valtype);

	/* no coercion if the rowtype is known to match */
	if (ctx->harvest->rettype == valtype && valtype != RECORDOID)
		return value;

	lv = plllvm_pj_level(ctx);
	oldcxt = MemoryContextSwitchTo(lv->datum_cxt);

	/* the type is looked up at every call, as PL/pgSQL does */
	switch (get_call_result_type(fcinfo, &resulttype, &tupdesc))
	{
		case TYPEFUNC_COMPOSITE:
			break;

		case TYPEFUNC_RECORD:

			/*
			 * The caller expects any row: it is passed as it is, and the
			 * handler copies it
			 */
			MemoryContextSwitchTo(oldcxt);
			return value;

		default:

			/*
			 * what is no composite type: a composite domain is out of scope,
			 * so this is stock's arm for what cannot happen
			 */
			elog(ERROR, "return type must be a row type");
			break;
	}

	/* the tuple and its descriptor, as deconstruct_composite_datum() */
	td = DatumGetHeapTupleHeader(value);
	tmptup.t_len = HeapTupleHeaderGetDatumLength(td);
	ItemPointerSetInvalid(&(tmptup.t_self));
	tmptup.t_tableOid = InvalidOid;
	tmptup.t_data = td;
	retdesc = lookup_rowtype_tupdesc(HeapTupleHeaderGetTypeId(td),
									 HeapTupleHeaderGetTypMod(td));

	/* check rowtype compatibility */
	tupmap = convert_tuples_by_position(retdesc, tupdesc,
										gettext_noop("returned record type does not match expected record type"));
	rettup = &tmptup;
	if (tupmap)
		rettup = execute_attr_map_tuple(rettup, tupmap);

	/*
	 * Labelled with the type the caller expects.  For RECORD this is where
	 * SPI_returntuple() makes sure a typmod has been assigned.
	 */
	if (tupdesc->tdtypeid == RECORDOID && tupdesc->tdtypmod < 0)
		assign_record_type_typmod(tupdesc);
	result = heap_copy_tuple_as_datum(rettup, tupdesc);

	ReleaseTupleDesc(retdesc);
	MemoryContextSwitchTo(oldcxt);

	return result;
}
