/*
 * tsx-overlay-layout.h: the size and layout math of tsx-overlay. It has no
 * Wayland or cairo code, so a host test can compile it on its own
 * (tests/test-orientation.sh).
 *
 * The slider (the small brightness bar) is a layer surface at the right edge
 * of the output, anchored top, right and bottom. The compositor gives it the
 * output height minus a top and a bottom margin. It is 600 px high on
 * 1280x800 and 400 px on 1024x600. A portrait output (800x1280 or 600x1024) is
 * much higher. The margins then grow, so the surface is never higher than on
 * the 10-inch landscape panel. The surface stays centered on the edge.
 *
 * The full overlay is a layer surface over the whole output. It dims the page
 * and holds a panel in the middle of the output. The panel is a grid of
 * tiles. The grid (columns, rows, gap, tile size) and the widgets come from
 * the layout file (tsx-overlay-config.h). A grid that does not fit the output
 * is scaled down. A touch outside the panel closes the overlay.
 */
#ifndef TSX_OVERLAY_LAYOUT_H
#define TSX_OVERLAY_LAYOUT_H

#include <string.h>

struct rect { int x, y, w, h; };

/* ---- the slider ----------------------------------------------------------- */
#define SLIDER_W 150
#define SLIDER_MARGIN_V 100
#define SLIDER_MAX_H 600
#define MARGIN_R 16

/* The top margin (the same as the bottom margin) of the slider surface on an
 * output out_h px high. out_h is 0 while the height is not known yet. */
static inline int overlay_margin_v(int out_h)
{
	int mv = SLIDER_MARGIN_V;
	if (out_h - 2 * mv > SLIDER_MAX_H) mv = (out_h - SLIDER_MAX_H) / 2;
	return mv;
}

/* The slider track, in surface coordinates, for a surface h px high. */
static inline struct rect overlay_slider_track(int h)
{
	if (h <= 0) h = 600;
	return (struct rect){ 40, 90, 70, h - 200 };
}

/* ---- the tile grid ---------------------------------------------------------- */
enum ov_type {
	WT_UNKNOWN = 0, WT_BRIGHTNESS, WT_AUTO_BRIGHTNESS, WT_SCREEN_OFF, WT_RELOAD_PAGE, WT_SETUP,
	WT_CLOSE, WT_VOLUME, WT_DARK_MODE, WT_KEYBOARD, WT_CLOCK, WT_INFO, WT_REBOOT, WT_LED_BAR, WT_COUNT
};

static const char *const ov_type_name[WT_COUNT] = {
	"unknown", "brightness", "auto_brightness", "screen_off", "reload_page", "setup",
	"close", "volume", "dark_mode", "keyboard", "clock", "info", "reboot", "led_bar"
};

static inline int ov_type_from_name(const char *s)
{
	for (int i = 1; i < WT_COUNT; i++) if (!strcmp(s, ov_type_name[i])) return i;
	return WT_UNKNOWN;
}

#define OV_MAX_ITEMS 48
#define OV_MAX_DIM 12
#define OV_GAP_MAX 40
#define OV_TILE_MIN 60
#define OV_TILE_MAX 400
#define OV_PAD 16          /* the space between the panel edge and the tiles */
#define OV_MARGIN 24       /* the least space between the panel and the output edge */

struct ov_grid { int cols, rows, gap, tile; };

/* x and y are -1 when the file gives none (the widget flows into a free place). */
struct ov_item { int type, x, y, w, h; char label[32]; };

/* The full overlay closes this many seconds after the last touch on it.
 * 0 = only a touch closes it. */
#define OV_TIMEOUT_DEFAULT 30
#define OV_TIMEOUT_MAX 3600

struct ov_layout {
	struct ov_grid grid;
	int timeout_s;     /* "timeout" of the file, OV_TIMEOUT_DEFAULT if none */
	int n;
	struct ov_item item[OV_MAX_ITEMS];
	char warn[96];     /* the first problem that did not stop the load, or "" */
};

static inline void ov_item_set(struct ov_layout *L, int type, int x, int y, int w, int h)
{
	struct ov_item *it = &L->item[L->n++];
	memset(it, 0, sizeof *it);
	it->type = type; it->x = x; it->y = y; it->w = w; it->h = h;
}

/* The built-in layout. The file kiosk/usr/local/share/tsx/overlay.json has
 * the same content (tests/test-overlay-config.sh checks it). */
static inline void ov_layout_default(struct ov_layout *L)
{
	memset(L, 0, sizeof *L);
	L->grid = (struct ov_grid){ 4, 3, 12, 150 };
	L->timeout_s = OV_TIMEOUT_DEFAULT;
	ov_item_set(L, WT_BRIGHTNESS, -1, -1, 1, 3);
	ov_item_set(L, WT_AUTO_BRIGHTNESS, -1, -1, 1, 1);
	ov_item_set(L, WT_SCREEN_OFF, -1, -1, 1, 1);
	ov_item_set(L, WT_RELOAD_PAGE, -1, -1, 1, 1);
	ov_item_set(L, WT_DARK_MODE, -1, -1, 1, 1);
	ov_item_set(L, WT_KEYBOARD, -1, -1, 1, 1);
	ov_item_set(L, WT_SETUP, -1, -1, 1, 1);
	ov_item_set(L, WT_VOLUME, -1, -1, 2, 1);
	ov_item_set(L, WT_CLOSE, -1, -1, 1, 1);
}

/* A widget with its cells. */
struct ov_slot { int item; struct rect cell; };

/* Do the cells x, y, w, h lie in the grid and are they all free? */
static inline int ov_fits(unsigned char occ[OV_MAX_DIM][OV_MAX_DIM], int cols, int rows, int x, int y, int w, int h)
{
	if (x < 0 || y < 0 || x + w > cols || y + h > rows) return 0;
	for (int yy = y; yy < y + h; yy++)
		for (int xx = x; xx < x + w; xx++) if (occ[yy][xx]) return 0;
	return 1;
}

/* Place the widgets in the grid. The rules are the rules of the cards of the
 * panel app (docs/panel-app.md, "Placement"): first the widgets with x and y,
 * in the order of the list. Then the others, each in the first free cells,
 * row by row. A widget that overlaps an earlier one, that leaves the grid or
 * that finds no free place is left out. Returns the number of placed widgets.
 * slot[] lists them in the order of the file. */
static inline int ov_place(const struct ov_layout *L, struct ov_slot slot[OV_MAX_ITEMS])
{
	unsigned char occ[OV_MAX_DIM][OV_MAX_DIM];
	int n = 0, cols = L->grid.cols, rows = L->grid.rows, done[OV_MAX_ITEMS] = { 0 };
	struct rect cell[OV_MAX_ITEMS] = { { 0, 0, 0, 0 } };
	memset(occ, 0, sizeof occ);
	if (cols < 1 || cols > OV_MAX_DIM || rows < 1 || rows > OV_MAX_DIM) return 0;
	for (int pass = 0; pass < 2; pass++)
		for (int i = 0; i < L->n && i < OV_MAX_ITEMS; i++) {
			const struct ov_item *it = &L->item[i];
			int w = it->w < 1 ? 1 : it->w, h = it->h < 1 ? 1 : it->h;
			int fixed = it->x >= 0 && it->y >= 0;
			if (fixed != (pass == 0)) continue;
			int fx = -1, fy = -1;
			if (fixed) {
				if (ov_fits(occ, cols, rows, it->x, it->y, w, h)) { fx = it->x; fy = it->y; }
			} else
				for (int y = 0; y < rows && fy < 0; y++)
					for (int x = 0; x < cols; x++)
						if (ov_fits(occ, cols, rows, x, y, w, h)) { fx = x; fy = y; break; }
			if (fx < 0) continue;
			for (int yy = fy; yy < fy + h; yy++) for (int xx = fx; xx < fx + w; xx++) occ[yy][xx] = 1;
			cell[i] = (struct rect){ fx, fy, w, h };
			done[i] = 1;
		}
	for (int i = 0; i < L->n && i < OV_MAX_ITEMS; i++)
		if (done[i]) { slot[n].item = i; slot[n].cell = cell[i]; n++; }
	return n;
}

/* The size of the grid on an output. */
struct ov_geom { struct rect panel; int tile, gap, pad; };

/* The panel in the middle of an output of ow x oh px. The panel is the grid
 * plus the space around it. A grid that leaves less than OV_MARGIN px around
 * the panel is scaled down: the tile, the gap and the space around it. */
static inline struct ov_geom ov_geometry(const struct ov_grid *g, int ow, int oh)
{
	struct ov_geom r;
	int tile = g->tile, gap = g->gap, pad = OV_PAD;
	long pw = (long)g->cols * tile + (long)(g->cols - 1) * gap + 2L * pad;
	long ph = (long)g->rows * tile + (long)(g->rows - 1) * gap + 2L * pad;
	long aw = ow - 2L * OV_MARGIN, ah = oh - 2L * OV_MARGIN;
	if (aw < 1) aw = 1;
	if (ah < 1) ah = 1;
	if (pw > aw || ph > ah) {
		long s = aw * 1000 / pw, s2 = ah * 1000 / ph;
		if (s2 < s) s = s2;
		tile = (int)(tile * s / 1000); gap = (int)(gap * s / 1000); pad = (int)(pad * s / 1000);
		if (tile < 1) tile = 1;
		pw = (long)g->cols * tile + (long)(g->cols - 1) * gap + 2L * pad;
		ph = (long)g->rows * tile + (long)(g->rows - 1) * gap + 2L * pad;
	}
	r.tile = tile; r.gap = gap; r.pad = pad;
	r.panel = (struct rect){ (int)((ow - pw) / 2), (int)((oh - ph) / 2), (int)pw, (int)ph };
	return r;
}

/* The rectangle of grid cells, in the coordinates of the panel. */
static inline struct rect ov_cell_rect(const struct ov_geom *g, struct rect cell)
{
	return (struct rect){ g->pad + cell.x * (g->tile + g->gap), g->pad + cell.y * (g->tile + g->gap),
			      cell.w * g->tile + (cell.w - 1) * g->gap, cell.h * g->tile + (cell.h - 1) * g->gap };
}

/* The slider offset for the level l on the base b of tsx-idled. The offset
 * has the range of the backlight (maxlvl), so a 0..4095 backlight can use the
 * whole slider. A fixed limit of 31 steps moved a 0..4095 backlight by 31 at
 * most. A 0..23 backlight keeps its old range, because |l - b| < 23 there. */
static inline int overlay_offset(int l, int b, int maxlvl)
{
	int off = l - b;
	if (maxlvl < 1) maxlvl = 1;
	if (off > maxlvl) off = maxlvl;
	if (off < -maxlvl) off = -maxlvl;
	return off;
}

/* The brightness as a percent of the backlight maximum, rounded. The overlay
 * shows it under the slider. A level of 0 or less shows 0. */
static inline int overlay_percent(int level, int maxlvl)
{
	if (level <= 0 || maxlvl <= 0) return 0;
	if (level >= maxlvl) return 100;
	return (int)(((long long)level * 100 + maxlvl / 2) / maxlvl);
}

#endif
