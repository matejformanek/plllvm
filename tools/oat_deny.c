/*
 * An object access hook that raises when the function named by
 * pj_oat.deny is about to be executed, for pj_cmodule_pins.sh
 */
#include "postgres.h"

#include "catalog/objectaccess.h"
#include "fmgr.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"

PG_MODULE_MAGIC;

static object_access_hook_type prev_hook = NULL;
static char *deny_name = NULL;

static void
oat_deny_hook(ObjectAccessType access, Oid classId, Oid objectId,
			  int subId, void *arg)
{
	if (prev_hook)
		prev_hook(access, classId, objectId, subId, arg);

	if (access == OAT_FUNCTION_EXECUTE && deny_name != NULL &&
		deny_name[0] != '\0')
	{
		char	   *name = get_func_name(objectId);

		if (name != NULL && strcmp(name, deny_name) == 0)
			ereport(ERROR,
					(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
					 errmsg("hook denies execution of function \"%s\"", name)));
	}
}

void
_PG_init(void)
{
	DefineCustomStringVariable("pj_oat.deny",
							   "Name of the function the hook refuses.",
							   NULL,
							   &deny_name,
							   "",
							   PGC_USERSET,
							   0,
							   NULL, NULL, NULL);

	prev_hook = object_access_hook;
	object_access_hook = oat_deny_hook;
}
