/*
 * Copyright 2011, Denys Vlasenko
 *
 * Licensed under GPLv2, see file LICENSE in this source tree.
 */

//kbuild:lib-y += get_shell_name.o

#include "libbb.h"

const char *get_shell_name(void)
{
	struct passwd *pw;
	char *shell;

	shell = getenv("SHELL");
	if (shell && shell[0])
		return shell;

#if !ENABLE_PLATFORM_MINGW32
	pw = getpwuid(getuid());
	if (pw && pw->pw_shell && pw->pw_shell[0])
		return pw->pw_shell;
#endif

	return DEFAULT_SHELL;
}