/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Checks of the layout file loader of tsx-overlay (kiosk/src/tsx-overlay-config.h).
 * Usage: overlay-config-check DIR SHIPPED. DIR holds the test files (see
 * tests/test-overlay-config.sh), SHIPPED is the default file of the package. Needs cJSON. */
#include <stdio.h>
#include <string.h>
#include "../kiosk/src/tsx-overlay-config.h"

static int fails;
#define CHECK(c, ...) do { if (c) printf("  ok: " __VA_ARGS__), puts(""); else { printf("  FAIL: " __VA_ARGS__), puts(""); fails++; } } while (0)

static int same(const struct ov_layout *a, const struct ov_layout *b)
{
	if (memcmp(&a->grid, &b->grid, sizeof a->grid) || a->n != b->n) return 0;
	for (int i = 0; i < a->n; i++)
		if (a->item[i].type != b->item[i].type || a->item[i].x != b->item[i].x || a->item[i].y != b->item[i].y
		    || a->item[i].w != b->item[i].w || a->item[i].h != b->item[i].h || strcmp(a->item[i].label, b->item[i].label))
			return 0;
	return 1;
}

int main(int argc, char **argv)
{
	struct ov_layout L, D;
	char msg[256], p[512], q[512];
	const char *paths[3];
	const char *dir = argc > 1 ? argv[1] : ".";
	int r;
	ov_layout_default(&D);

	snprintf(p, sizeof p, "%s/valid.json", dir);
	paths[0] = p;
	r = ov_layout_load(paths, 1, &L, msg, sizeof msg);
	CHECK(r == 0 && strstr(msg, "unknown type"), "a valid file loads, the log line names the unknown widget (%s)", msg);
	CHECK(L.grid.cols == 3 && L.grid.rows == 2 && L.grid.gap == 8 && L.grid.tile == 120, "grid 3x2, gap 8, tile 120");
	CHECK(L.n == 4, "four widgets (%d)", L.n);
	CHECK(L.timeout_s == 120, "timeout 120 s (%d)", L.timeout_s);
	CHECK(L.item[0].type == WT_CLOCK && L.item[0].w == 2 && L.item[0].x == -1, "clock, 2 wide, no place");
	CHECK(L.item[1].type == WT_REBOOT && !strcmp(L.item[1].label, "Restart now") && L.item[1].x == 2 && L.item[1].y == 1, "reboot with label at 2,1");
	CHECK(L.item[2].type == WT_VOLUME && L.item[2].x == -1 && L.item[2].y == -1, "an x without y gives no place");
	CHECK(L.item[3].type == WT_UNKNOWN && L.warn[0], "an unknown type stays as an empty widget with a warning (%s)", L.warn);

	snprintf(p, sizeof p, "%s/defaults.json", dir);
	r = ov_layout_load(paths, 1, &L, msg, sizeof msg);
	CHECK(r == 0 && L.grid.cols == 4 && L.grid.rows == 3 && L.grid.gap == 12 && L.grid.tile == 150, "a file with no grid has the default grid");
	CHECK(L.timeout_s == OV_TIMEOUT_DEFAULT, "a file with no timeout has the default timeout (%d)", L.timeout_s);

	static const char *const bad[] = { "invalid.json", "badversion.json", "nowidgets.json", "badgrid.json", "badtype.json", "badx.json", "badtimeout.json", "empty.json" };
	for (unsigned i = 0; i < sizeof bad / sizeof *bad; i++) {
		snprintf(p, sizeof p, "%s/%s", dir, bad[i]);
		r = ov_layout_load(paths, 1, &L, msg, sizeof msg);
		CHECK(r == -1 && same(&L, &D) && strstr(msg, bad[i]) && strstr(msg, "built-in"), "%s gives the built-in layout (%s)", bad[i], msg);
	}

	snprintf(p, sizeof p, "%s/nothere.json", dir);
	r = ov_layout_load(paths, 1, &L, msg, sizeof msg);
	CHECK(r == -1 && same(&L, &D) && msg[0], "a missing file gives the built-in layout (%s)", msg);
	CHECK(L.n == 9, "the built-in layout has 9 widgets (%d)", L.n);

	/* the order: the first file that exists wins, a missing one is skipped */
	snprintf(q, sizeof q, "%s/valid.json", dir);
	paths[0] = NULL; paths[1] = p; paths[2] = q;
	r = ov_layout_load(paths, 3, &L, msg, sizeof msg);
	CHECK(r == 2 && L.n == 4, "a missing file and a NULL path are skipped (index %d)", r);
	snprintf(p, sizeof p, "%s/invalid.json", dir);
	r = ov_layout_load(paths, 3, &L, msg, sizeof msg);
	CHECK(r == -1 && same(&L, &D), "a broken file in front is not skipped: the built-in layout");

	/* the shipped default file is the built-in layout */
	snprintf(p, sizeof p, "%s", argc > 2 ? argv[2] : "overlay.json");
	paths[0] = p;
	r = ov_layout_load(paths, 1, &L, msg, sizeof msg);
	CHECK(r == 0 && !msg[0] && same(&L, &D), "kiosk/usr/local/share/tsx/overlay.json is the built-in layout (%s)", msg);
	return fails != 0;
}
