/* tsx-conf.h: the layers of a settings file such as kiosk.conf.
 *
 * The package ships the defaults in /usr/local/share/tsx/defaults (the
 * environment variable TSX_DEFAULTS_DIR replaces the folder). The user file in
 * /etc holds only the keys that the user changed. Package updates replace the
 * defaults and never touch the user file. The layers, a later one wins:
 *   TSX_LAYER_DEFAULTS  the defaults file of the package
 *   TSX_LAYER_BOARD     the board file (NULL when the setting has none)
 *   TSX_LAYER_USER      the user file
 *   TSX_LAYER_RUN       the runtime file in /run/tsx (NULL when none)
 * The shell version is conf.sh and the Python version is tsx_conf.py, both in
 * /usr/local/lib/tsx. Keep all three the same.
 *
 *   int tsx_conf_each(name, board, user, run, fn, arg)
 *     Calls fn(path, layer, arg) for each layer file that exists and can be
 *     read, in order. The function opens and parses the file. It returns the
 *     number of files. A missing file is no error.
 *   const char *tsx_conf_defaults_path(name, buf, n)
 *     The path of the defaults file of NAME.
 */
#ifndef TSX_CONF_H
#define TSX_CONF_H

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

enum { TSX_LAYER_DEFAULTS, TSX_LAYER_BOARD, TSX_LAYER_USER, TSX_LAYER_RUN };

typedef void (*tsx_conf_fn)(const char *path, int layer, void *arg);

static inline const char *tsx_conf_defaults_path(const char *name, char *buf, size_t n)
{
	const char *d = getenv("TSX_DEFAULTS_DIR");
	snprintf(buf, n, "%s/%s", d && *d ? d : "/usr/local/share/tsx/defaults", name);
	return buf;
}

static inline int tsx_conf_each(const char *name, const char *board, const char *user, const char *run,
				tsx_conf_fn fn, void *arg)
{
	char def[4096];
	const char *p[4] = { tsx_conf_defaults_path(name, def, sizeof def), board, user, run };
	int n = 0;
	for (int i = 0; i < 4; i++) {
		if (!p[i] || !*p[i] || access(p[i], R_OK) != 0) continue;
		fn(p[i], i, arg);
		n++;
	}
	return n;
}

#endif
