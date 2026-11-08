/*
 * tsx-overlay-config.h: the layout file of tsx-overlay. It has no Wayland or
 * cairo code, so a host test can compile it with cJSON
 * (tests/test-overlay-config.sh).
 *
 * The file is JSON, a subset of the layout format of the panel app
 * (docs/panel-app.md):
 *   {"version": 1, "timeout": 30,
 *    "grid": {"columns": 4, "rows": 3, "gap": 12, "tile": 150},
 *    "widgets": [{"type": "brightness", "h": 3}, {"type": "close"}]}
 * "timeout" is the time in seconds from the last touch to the close
 * (0 to OV_TIMEOUT_MAX, 0 = only a touch closes the overlay).
 * A widget has "type" and, optional, "x", "y" (both or none), "w", "h" and
 * "label". The first file that exists wins: the file in the environment
 * variable TSX_OVERLAY_LAYOUT (tests), the file of the user, the file of the
 * package. A missing, broken or invalid file gives the built-in layout, so
 * the overlay always opens.
 */
#ifndef TSX_OVERLAY_CONFIG_H
#define TSX_OVERLAY_CONFIG_H

#include <stdio.h>
#include <stdlib.h>
#include <cjson/cJSON.h>
#include "tsx-overlay-layout.h"

#define OV_FILE_USER "/var/lib/tsx/overlay.json"
#define OV_FILE_PACKAGE "/usr/local/share/tsx/overlay.json"
#define OV_FILE_MAX 65536

/* A number of the file that must be an integer from lo to hi. Return 0 and
 * set *out, or -1 and write the reason to err. */
static inline int ov_int(const cJSON *o, const char *key, int lo, int hi, int *out, char *err, size_t en)
{
	const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, key);
	if (!v) return 1;   /* not there */
	if (!cJSON_IsNumber(v) || v->valuedouble != (double)(long)v->valuedouble || v->valuedouble < lo || v->valuedouble > hi) {
		snprintf(err, en, "\"%s\" must be a whole number from %d to %d", key, lo, hi);
		return -1;
	}
	*out = (int)v->valuedouble;
	return 0;
}

/* Read the text of a layout file into L. Return 0, or -1 with the reason in
 * err. L is not complete after an error: use ov_layout_default. */
static inline int ov_layout_parse(const char *text, struct ov_layout *L, char *err, size_t en)
{
	cJSON *root = cJSON_Parse(text);
	const cJSON *g, *ws, *w;
	int v = 0, i = 0;
	if (en) err[0] = 0;
	memset(L, 0, sizeof *L);
	L->grid = (struct ov_grid){ 4, 3, 12, 150 };
	L->timeout_s = OV_TIMEOUT_DEFAULT;
	if (!root) { snprintf(err, en, "not valid JSON"); return -1; }
	if (!cJSON_IsObject(root)) { snprintf(err, en, "the top level is not an object"); goto bad; }
	if (ov_int(root, "version", 1, 1, &v, err, en) != 0) { if (!*err) snprintf(err, en, "\"version\" is missing"); goto bad; }
	if (ov_int(root, "timeout", 0, OV_TIMEOUT_MAX, &L->timeout_s, err, en) < 0) goto bad;
	if ((g = cJSON_GetObjectItemCaseSensitive(root, "grid"))) {
		int r;
		if (!cJSON_IsObject(g)) { snprintf(err, en, "\"grid\" is not an object"); goto bad; }
		if ((r = ov_int(g, "columns", 1, OV_MAX_DIM, &L->grid.cols, err, en)) < 0) goto bad;
		if ((r = ov_int(g, "rows", 1, OV_MAX_DIM, &L->grid.rows, err, en)) < 0) goto bad;
		if ((r = ov_int(g, "gap", 0, OV_GAP_MAX, &L->grid.gap, err, en)) < 0) goto bad;
		if ((r = ov_int(g, "tile", OV_TILE_MIN, OV_TILE_MAX, &L->grid.tile, err, en)) < 0) goto bad;
	}
	ws = cJSON_GetObjectItemCaseSensitive(root, "widgets");
	if (!cJSON_IsArray(ws)) { snprintf(err, en, "\"widgets\" is missing or not a list"); goto bad; }
	if (cJSON_GetArraySize(ws) < 1 || cJSON_GetArraySize(ws) > OV_MAX_ITEMS) {
		snprintf(err, en, "\"widgets\" needs 1 to %d entries", OV_MAX_ITEMS); goto bad;
	}
	cJSON_ArrayForEach(w, ws) {
		const cJSON *t = cJSON_GetObjectItemCaseSensitive(w, "type"), *lab;
		struct ov_item *it;
		int x = -1, y = -1, iw = 1, ih = 1, r;
		i++;
		if (!cJSON_IsObject(w) || !cJSON_IsString(t) || !t->valuestring) {
			snprintf(err, en, "widget %d has no \"type\" text", i); goto bad;
		}
		if ((r = ov_int(w, "x", 0, OV_MAX_DIM - 1, &x, err, en)) < 0) goto bad;
		if ((r = ov_int(w, "y", 0, OV_MAX_DIM - 1, &y, err, en)) < 0) goto bad;
		if ((r = ov_int(w, "w", 1, OV_MAX_DIM, &iw, err, en)) < 0) goto bad;
		if ((r = ov_int(w, "h", 1, OV_MAX_DIM, &ih, err, en)) < 0) goto bad;
		if (x < 0 || y < 0) x = y = -1;     /* give both or none */
		ov_item_set(L, ov_type_from_name(t->valuestring), x, y, iw, ih);
		it = &L->item[L->n - 1];
		if (it->type == WT_UNKNOWN && !L->warn[0])
			snprintf(L->warn, sizeof L->warn, "widget %d: unknown type \"%.40s\"", i, t->valuestring);
		if ((lab = cJSON_GetObjectItemCaseSensitive(w, "label")) && cJSON_IsString(lab) && lab->valuestring)
			snprintf(it->label, sizeof it->label, "%s", lab->valuestring);
	}
	cJSON_Delete(root);
	return 0;
bad:
	cJSON_Delete(root);
	return -1;
}

/* Load the layout. The first of the paths that can be opened wins (a path
 * may be NULL or empty). A file that cannot be read as a layout gives the
 * built-in layout. msg gets one line for the log, or "" when all is well.
 * Return the index of the used path, or -1 for the built-in layout. */
static inline int ov_layout_load(const char *const *path, int npath, struct ov_layout *L, char *msg, size_t mn)
{
	static char buf[OV_FILE_MAX + 1];
	char err[96] = "";
	msg[0] = 0;
	for (int i = 0; i < npath; i++) {
		FILE *f;
		size_t n;
		if (!path[i] || !path[i][0] || !(f = fopen(path[i], "r"))) continue;
		n = fread(buf, 1, OV_FILE_MAX, f);
		fclose(f);
		buf[n] = 0;
		if (n == OV_FILE_MAX) snprintf(err, sizeof err, "more than %d bytes", OV_FILE_MAX);
		else if (ov_layout_parse(buf, L, err, sizeof err) == 0) {
			if (L->warn[0]) snprintf(msg, mn, "%.150s: %s", path[i], L->warn);
			return i;
		}
		snprintf(msg, mn, "%.150s: %s, using the built-in layout", path[i], err);
		ov_layout_default(L);
		return -1;
	}
	snprintf(msg, mn, "no layout file, using the built-in layout");
	ov_layout_default(L);
	return -1;
}

#endif
