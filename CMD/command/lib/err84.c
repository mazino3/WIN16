/*	This is an automatic generated file

	DO NOT EDIT! SEE ERR_FCTS.SRC and SCANERR.PL.

	Error printing function providing a wrapper for STRINGS
 */

#include "../config.h"

#include "../include/misc.h"
#include "../err_fcts.h"
#include "../strings/strings.h"

#undef error_invalid_parameter
void error_invalid_parameter(const char * const str)
{	displayError(TEXT_ERROR_INVALID_PARAMETER, str);
}
