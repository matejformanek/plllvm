/*-------------------------------------------------------------------------
 *
 * plllvm_ir.h
 *
 *			  building a module of LLVM IR as text
 *
 * by Matěj Formánek 2026
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) Temporaries are %t1, %t2, ...; labels are L1, L2, ... and are
 *    returned without the %, so a branch is written "br label %%%s".
 *
 * 2) Everything is allocated in CurrentMemoryContext.
 *
 */
#ifndef PLLLVM_IR_H
#define PLLLVM_IR_H

typedef struct plllvm_ir plllvm_ir;

extern plllvm_ir *plllvm_ir_begin(void);
extern const char *plllvm_ir_tmp(plllvm_ir *ir);
extern const char *plllvm_ir_label(plllvm_ir *ir);
extern void plllvm_ir_block(plllvm_ir *ir, const char *label);
extern const char *plllvm_ir_current(plllvm_ir *ir);
extern void plllvm_ir_emit(plllvm_ir *ir, const char *fmt, ...) pg_attribute_printf(2, 3);
extern void plllvm_ir_declare(plllvm_ir *ir, const char *decl);
extern char *plllvm_ir_end(plllvm_ir *ir);

#endif							/* PLLLVM_IR_H */
