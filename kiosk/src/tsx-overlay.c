/*
 * tsx-overlay: local quick settings for the kiosk (sway session only).
 *
 * A wlr-layer-shell surface on the OVERLAY layer. The surface stays hidden (no
 * surface at all) until tsx-idled (the five-finger hold) or tsx-buttons (a
 * key) asks for it over /run/tsx/overlay.ctl:
 *   slider   compact brightness bar at the right edge of the screen, shown
 *            while a finger slides along the front keys. When the panel hangs
 *            in portrait, it stays at the right edge, at most as high as on a
 *            landscape panel, and centered (tsx-overlay-layout.h). It hides
 *            OVERLAY_SLIDER_MS after the last step.
 *   full     a grid of tiles in the middle of the screen. The surface covers
 *            the whole output: it dims the page and holds the panel. A touch
 *            on the dim part (outside the panel) closes it
 *            (OVERLAY_DIM_GUARD_MS after the show at the earliest). It hides
 *            "timeout" seconds (layout file, default 30) after the last touch on it.
 *   hide, toggle
 * The grid, the size of the tiles and the widgets come from a layout file
 * (tsx-overlay-config.h): TSX_OVERLAY_LAYOUT (tests), /var/lib/tsx/overlay.json
 * (the user), /usr/local/share/tsx/overlay.json (the package). The first file
 * that exists wins. A missing or bad file gives the built-in layout, so the
 * overlay always opens. The program reads the file again at each show. The
 * format is in docs/buttons.md ("Quick-settings overlay").
 * Keyboard interactivity is NONE. The overlay never takes the keyboard focus
 * from Chromium, so the on-screen keyboard keeps working. Touches outside the
 * slider surface still go to the page. The full overlay takes all touches.
 *
 * The overlay shows state (/run/tsx/brightness.state from tsx-idled,
 * /run/tsx/als.state from tsx-als, and "tsx-panelctl get/has" for the rest).
 * It hands every action to tsx-panelctl (FIFO /run/tsx/panelctl, group kiosk,
 * a fixed command list). The widgets and their commands:
 *   brightness       the slider: brightness-offset N. The local manual setting
 *                    is an offset on top of ALS or the day/night schedule.
 *                    The slider runs from the floor (the "min" line of
 *                    brightness.state) to the top level. On a wide range, the
 *                    position maps to the level with a square (tsx-level.h),
 *                    so the dark end has finer steps. The label shows the
 *                    level as a percent of the top level.
 *   auto_brightness  als auto on|off
 *   screen_off       blank on
 *   reload_page      reload-page
 *   setup            setup: brings the on-panel setup page back up for about
 *                    15 minutes, even on an already-configured panel (see the
 *                    "Setup page" docs of the board repository).
 *   close            no command
 *   volume           the slider: volume N (get volume, get mute)
 *   dark_mode        dark-mode on|off (get dark-mode). The kiosk restarts.
 *   keyboard         no command: runs "tsx-osk toggle" itself (it works for
 *                    user kiosk) and closes the overlay.
 *   clock, info      no tap action
 *   reboot           reboot, after a second tap within 3 s
 *   led_bar          ledbar on|off (has ledbar, get ledbar)
 * It runs as the kiosk user, never as root.
 *
 * Why C and cairo on wl_shm: the process stays resident, so the slider appears
 * on the first slide step. A GTK or Python client needs seconds to start on
 * this CPU and 40+ MB to stay resident. Here the idle cost is one sleeping
 * process of a few MB and no wakeups while the overlay is hidden. Touch and
 * pointer input both work (pointer: a mouse, or a virtual pointer in tests).
 *
 * Build: cc -Wall -Wextra -o tsx-overlay tsx-overlay.c wlr-layer-shell-
 * unstable-v1-protocol.c xdg-shell-protocol.c $(pkg-config --cflags --libs
 * cairo wayland-client) -lcjson
 *
 * Env (tests / tuning): TSX_RUN_DIR (/run/tsx), OVERLAY_SLIDER_MS (1500),
 * OVERLAY_FULL_MS (replaces the "timeout" of the layout file), OVERLAY_DIM (the alpha of the dim part, 0.55),
 * OVERLAY_DIM_GUARD_MS (400), TSX_OVERLAY_LAYOUT (a layout file in front of
 * the others), TSX_PANELCTL_BIN (/usr/local/sbin/tsx-panelctl), TSX_OSK_BIN
 * (/usr/local/bin/tsx-osk), TSX_OVERLAY_VERBOSE=1.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <limits.h>
#include <math.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>

#include <cairo.h>
#include <wayland-client.h>
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include "tsx-overlay-config.h"
#include "tsx-level.h"

enum mode { HIDDEN, SLIDER, FULL };

struct buffer { struct wl_buffer *wb; void *data; size_t size; int busy, w, h; cairo_surface_t *cs; };

static struct wl_display *dpy;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct wl_touch *touch;
static struct wl_pointer *pointer;
static struct zwlr_layer_shell_v1 *layer_shell;
static struct wl_surface *surface;
static struct zwlr_layer_surface_v1 *layer;
static struct buffer bufs[2];

static const char *rundir = "/run/tsx";
static char ctlpath[PATH_MAX], panelctl[PATH_MAX], bstate[PATH_MAX], astate[PATH_MAX];
static char ctlbin[PATH_MAX] = "/usr/local/sbin/tsx-panelctl", oskbin[PATH_MAX] = "/usr/local/bin/tsx-osk";
static int ctl_fd = -1, verbose, slider_ms = 1500, full_ms = -1, dim_guard_ms = 400;   /* full_ms -1: the layout file */
static double dim = 0.55;
static volatile sig_atomic_t sig_term;

static enum mode mode = HIDDEN, want_mode = HIDDEN;
static int configured, surf_w, surf_h;
static int cur_mv, out_h;                /* the top and bottom margin of the slider surface, and the output height */
static long long hide_at, shown_at;
static struct rect pan;                  /* the panel in surface coordinates (the slider: the whole surface) */
static int damage_all;                   /* the next commit damages the whole surface (the dim part) */

/* the state on show */
static int level = -1, base = -1, offset, override, maxlvl = 31, minlvl = 1, als_auto = -1;
static int drag_level = -1;              /* level under the finger while dragging */
static long long drag_hold;              /* ...shown until tsx-idled reports it (or until this time) */

/* The state of the other widgets. -1 = the panel has none of it. */
static int vol = -1, mute = -1, vol_drag = -1, dark = -1, ledbar = -1;
static long long vol_sent, vol_read_at, reboot_armed;
static int clock_min = -1;
static char info_host[64], info_ip[48], info_ver[48];

#define NOPRESS (-1)
#define PRESS_SLIDER 1000                /* the press on the slider surface (mode SLIDER) */
static int pressed = NOPRESS, press_inside, touch_id = -1, ptr_down;
static double ptr_x, ptr_y;

/*
 * The full overlay: lay is the layout file, slot[] the widgets that found a
 * place, tile[] their rectangles in panel coordinates. The slider: r_track
 * (see tsx-overlay-layout.h). The slider surface spans the output height
 * minus a top and a bottom margin. It is at most 600 px high. On a portrait
 * output the margins grow, so the surface is no higher than that.
 */
static struct ov_layout lay;
static struct ov_slot slot[OV_MAX_ITEMS];
static struct rect tile[OV_MAX_ITEMS];
static struct ov_geom geom;
static int nslot;
static struct rect r_track;
static char last_msg[256];

static void logm(const char *fmt, ...)
{
	va_list ap; va_start(ap, fmt);
	fprintf(stderr, "tsx-overlay: "); vfprintf(stderr, fmt, ap); fputc('\n', stderr);
	va_end(ap);
}

static long long now_ms(void)
{
	struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int in_rect(const struct rect *r, double x, double y)
{
	return x >= r->x && x < r->x + r->w && y >= r->y && y < r->y + r->h;
}

/* ---- state files ---------------------------------------------------------- */
static int field(const char *path, const char *key, char *out, size_t n)
{
	FILE *f = fopen(path, "r"); char line[128]; size_t kl = strlen(key); int ok = -1;
	if (!f) return -1;
	while (fgets(line, sizeof line, f))
		if (!strncmp(line, key, kl) && line[kl] == ' ') {
			line[strcspn(line, "\n")] = 0;
			snprintf(out, n, "%s", line + kl + 1); ok = 0; break;
		}
	fclose(f);
	return ok;
}

static int ifield(const char *path, const char *key, int def)
{
	char b[32];
	return field(path, key, b, sizeof b) ? def : atoi(b);
}

/* The top level before tsx-idled has written the "max" line of
 * brightness.state: max_brightness of the first backlight device (the lowest
 * name), else 31. This is the rule of bl_max in tsx-panelctl. The board sets
 * no number here. Test hook: TSX_BACKLIGHT_DIR. */
static int fallback_max(void)
{
	const char *dir = getenv("TSX_BACKLIGHT_DIR");
	char best[NAME_MAX + 1] = "", p[PATH_MAX + NAME_MAX + 32];
	struct dirent *e;
	int max = 0;
	DIR *d;
	if (!dir) dir = "/sys/class/backlight";
	if (!(d = opendir(dir))) return 31;
	while ((e = readdir(d))) {
		FILE *f; int v = 0;
		if (e->d_name[0] == '.' || (best[0] && strcmp(e->d_name, best) >= 0)) continue;
		snprintf(p, sizeof p, "%s/%s/max_brightness", dir, e->d_name);
		if (!(f = fopen(p, "r"))) continue;
		if (fscanf(f, "%d", &v) == 1 && v >= 2) { snprintf(best, sizeof best, "%s", e->d_name); max = v; }
		fclose(f);
	}
	closedir(d);
	return max >= 2 ? max : 31;
}

/* Return 1 if anything shown changed. */
static int read_state(void)
{
	char b[32];
	int l = ifield(bstate, "level", -1), ba = ifield(bstate, "base", -1), of = ifield(bstate, "offset", 0);
	int ov = ifield(bstate, "override", 0), mx = ifield(bstate, "max", 0), mn = ifield(bstate, "min", 1), a = -1;
	if (!field(astate, "auto", b, sizeof b)) a = !strcmp(b, "on");
	if (mx < 2) mx = fallback_max();
	if (mn < 1 || mn >= mx) mn = 1;
	int ch = l != level || ba != base || of != offset || ov != override || mx != maxlvl || mn != minlvl || a != als_auto;
	level = l; base = ba; offset = of; override = ov; maxlvl = mx; minlvl = mn; als_auto = a;
	return ch;
}

/* ---- actions (tsx-panelctl) ------------------------------------------------ */
static void panelctl_send(const char *fmt, ...)
{
	char line[96]; va_list ap; int fd;
	va_start(ap, fmt); vsnprintf(line, sizeof line - 1, fmt, ap); va_end(ap);
	strcat(line, "\n");
	if ((fd = open(panelctl, O_WRONLY | O_NONBLOCK | O_CLOEXEC)) < 0) {
		logm("tsx-panelctl not listening (%s): %s", panelctl, strerror(errno)); return;
	}
	if (write(fd, line, strlen(line)) < 0) logm("write %s: %s", panelctl, strerror(errno));
	close(fd);
	if (verbose) logm("-> panelctl: %s", line);
}

static void set_level(int l)
{
	if (l < minlvl) l = minlvl;     /* the floor: the slider never blanks the screen */
	if (l > maxlvl) l = maxlvl;
	if (l == drag_level) return;
	drag_level = l;
	/* The offset is relative to the base of tsx-idled (ALS or schedule).
	 * Without a base (an old tsx-idled), the current level replaces it. */
	int b = base > 0 ? base : (level > 0 ? level - offset : l);
	panelctl_send("brightness-offset %d", overlay_offset(l, b, maxlvl));
}
static void rounded(cairo_t *c, double x, double y, double w, double h, double r)
{
	cairo_new_sub_path(c);
	cairo_arc(c, x + w - r, y + r, r, -M_PI / 2, 0);
	cairo_arc(c, x + w - r, y + h - r, r, 0, M_PI / 2);
	cairo_arc(c, x + r, y + h - r, r, M_PI / 2, M_PI);
	cairo_arc(c, x + r, y + r, r, M_PI, 3 * M_PI / 2);
	cairo_close_path(c);
}

static void text_center(cairo_t *c, const char *s, double cx, double cy, double size, int bold)
{
	cairo_text_extents_t te;
	cairo_select_font_face(c, "DejaVu Sans", CAIRO_FONT_SLANT_NORMAL, bold ? CAIRO_FONT_WEIGHT_BOLD : CAIRO_FONT_WEIGHT_NORMAL);
	cairo_set_font_size(c, size);
	cairo_text_extents(c, s, &te);
	cairo_move_to(c, cx - te.width / 2 - te.x_bearing, cy - te.height / 2 - te.y_bearing);
	cairo_show_text(c, s);
}

static void sun(cairo_t *c, double cx, double cy, double r)
{
	cairo_arc(c, cx, cy, r * 0.45, 0, 2 * M_PI);
	cairo_fill(c);
	cairo_set_line_width(c, r * 0.14);
	cairo_set_line_cap(c, CAIRO_LINE_CAP_ROUND);
	for (int i = 0; i < 8; i++) {
		double a = i * M_PI / 4;
		cairo_move_to(c, cx + cos(a) * r * 0.68, cy + sin(a) * r * 0.68);
		cairo_line_to(c, cx + cos(a) * r, cy + sin(a) * r);
	}
	cairo_stroke(c);
}

static int slot_type(int si) { return lay.item[slot[si].item].type; }

static int has_widget(int type)
{
	for (int i = 0; i < nslot; i++) if (slot_type(i) == type) return 1;
	return 0;
}

/* ---- the other widgets: state ------------------------------------------------ */
/* Run a command, keep the first line of its output. Return 0 if it exits 0. */
static int run_read(const char *what, char *out, size_t n)
{
	char cmd[PATH_MAX + 48]; FILE *p; int st;
	snprintf(cmd, sizeof cmd, "%s %s 2>/dev/null", ctlbin, what);
	if (out) out[0] = 0;
	if (!(p = popen(cmd, "r"))) return -1;
	if (out && fgets(out, n, p)) out[strcspn(out, "\r\n")] = 0;
	st = pclose(p);
	return st == 0 ? 0 : -1;
}

/* Return 1 if anything shown changed. */
static int read_volume(void)
{
	char b[32] = ""; int v = -1, m = -1, ch;
	if (run_read("get volume", b, sizeof b) == 0 && b[0]) { v = atoi(b); if (v < 0) v = 0; if (v > 100) v = 100; }
	if (v >= 0 && run_read("get mute", b, sizeof b) == 0) m = !strcmp(b, "on");
	ch = v != vol || m != mute;
	vol = v; mute = m;
	return ch;
}

static void read_info(void)
{
	static const char *const ifs[] = { "eth0", "wlan0" };
	struct ifaddrs *ifa, *p; FILE *f; char line[160];
	if (gethostname(info_host, sizeof info_host - 1)) snprintf(info_host, sizeof info_host, "?");
	snprintf(info_ip, sizeof info_ip, "no network");
	if (!getifaddrs(&ifa)) {
		for (unsigned i = 0; i < sizeof ifs / sizeof *ifs; i++)
			for (p = ifa; p; p = p->ifa_next)
				if (p->ifa_addr && p->ifa_addr->sa_family == AF_INET && !strcmp(p->ifa_name, ifs[i])) {
					inet_ntop(AF_INET, &((struct sockaddr_in *)p->ifa_addr)->sin_addr, info_ip, sizeof info_ip);
					i = 99; break;
				}
		freeifaddrs(ifa);
	}
	info_ver[0] = 0;
	if ((f = fopen("/etc/tsx-release", "r"))) {
		if (fgets(line, sizeof line, f)) { line[strcspn(line, "\r\n")] = 0; snprintf(info_ver, sizeof info_ver, "%.47s", line); }
		fclose(f);
	}
	if (!info_ver[0] && (f = fopen("/lib/apk/db/installed", "r"))) {
		int mine = 0;
		while (fgets(line, sizeof line, f)) {
			if (line[0] == '\n') mine = 0;
			else if (!strncmp(line, "P:", 2)) mine = !strncmp(line + 2, "tsx-kiosk\n", 10);
			else if (mine && !strncmp(line, "V:", 2)) {
				line[strcspn(line, "\r\n")] = 0;
				snprintf(info_ver, sizeof info_ver, "tsx %.43s", line + 2); break;
			}
		}
		fclose(f);
	}
}

/* Read the state that only the full overlay shows, once on each show. */
static void read_ext(void)
{
	char b[48];
	if (has_widget(WT_VOLUME)) { read_volume(); vol_read_at = now_ms() + 2000; }
	if (has_widget(WT_DARK_MODE)) dark = run_read("get dark-mode", b, sizeof b) ? -1 : !strcmp(b, "on");
	if (has_widget(WT_LED_BAR)) {
		int a, c, d;
		ledbar = -1;
		if (run_read("has ledbar", NULL, 0) == 0) {
			ledbar = 0;
			if (run_read("get ledbar", b, sizeof b) == 0 && sscanf(b, "%d %d %d", &a, &c, &d) == 3) ledbar = a || c || d;
		}
	}
	if (has_widget(WT_INFO)) read_info();
	clock_min = -1;
}

/* Changes that come with time: the clock, the volume, the restart question. */
static int tick_widgets(void)
{
	int ch = 0; long long t = now_ms();
	if (mode != FULL) return 0;
	if (reboot_armed && t >= reboot_armed) { reboot_armed = 0; ch = 1; }
	if (has_widget(WT_CLOCK)) { int m = (int)(time(NULL) / 60); if (m != clock_min) { clock_min = m; ch = 1; } }
	if (has_widget(WT_VOLUME) && vol_drag < 0 && t >= vol_read_at) { vol_read_at = t + 2000; ch |= read_volume(); }
	return ch;
}

/* The layout file, read again at each show. The log gets a line only when
 * the problem is new. */
static void load_layout(void)
{
	const char *p[3] = { getenv("TSX_OVERLAY_LAYOUT"), OV_FILE_USER, OV_FILE_PACKAGE };
	char msg[sizeof last_msg];
	ov_layout_load(p, 3, &lay, msg, sizeof msg);
	if (strcmp(msg, last_msg)) {
		snprintf(last_msg, sizeof last_msg, "%s", msg);
		if (msg[0]) logm("layout: %s", msg);
	}
}

static void run_osk(void)
{
	pid_t pid = fork();
	if (pid == 0) {
		setsid();
		execl(oskbin, "tsx-osk", "toggle", (char *)NULL);
		_exit(127);
	}
	if (pid < 0) logm("fork: %s", strerror(errno));
}

static void set_vol(int v)
{
	long long t = now_ms();
	if (v < 0) v = 0;
	if (v > 100) v = 100;
	if (v == vol_drag) return;
	vol_drag = v;
	if (t - vol_sent >= 80) { vol_sent = t; panelctl_send("volume %d", v); }   /* the last value goes out on release */
}


static void speaker(cairo_t *c, double cx, double cy, double r, int muted)
{
	cairo_move_to(c, cx - r * 0.9, cy - r * 0.3);
	cairo_line_to(c, cx - r * 0.45, cy - r * 0.3);
	cairo_line_to(c, cx + r * 0.05, cy - r * 0.8);
	cairo_line_to(c, cx + r * 0.05, cy + r * 0.8);
	cairo_line_to(c, cx - r * 0.45, cy + r * 0.3);
	cairo_line_to(c, cx - r * 0.9, cy + r * 0.3);
	cairo_close_path(c);
	cairo_fill(c);
	cairo_set_line_width(c, r * 0.14);
	cairo_set_line_cap(c, CAIRO_LINE_CAP_ROUND);
	if (muted) {
		cairo_move_to(c, cx + r * 0.35, cy - r * 0.35); cairo_line_to(c, cx + r * 0.95, cy + r * 0.35);
		cairo_move_to(c, cx + r * 0.95, cy - r * 0.35); cairo_line_to(c, cx + r * 0.35, cy + r * 0.35);
	} else {
		cairo_new_sub_path(c); cairo_arc(c, cx + r * 0.05, cy, r * 0.5, -M_PI / 4, M_PI / 4);
		cairo_new_sub_path(c); cairo_arc(c, cx + r * 0.05, cy, r * 0.95, -M_PI / 4, M_PI / 4);
	}
	cairo_stroke(c);
}

static double text_w(cairo_t *c, const char *s, double size, int bold)
{
	cairo_text_extents_t te;
	cairo_select_font_face(c, "DejaVu Sans", CAIRO_FONT_SLANT_NORMAL, bold ? CAIRO_FONT_WEIGHT_BOLD : CAIRO_FONT_WEIGHT_NORMAL);
	cairo_set_font_size(c, size);
	cairo_text_extents(c, s, &te);
	return te.x_advance;
}

/* One line of text, made smaller until it fits maxw. */
static void fit_center(cairo_t *c, const char *s, double cx, double cy, double maxw, double size, int bold)
{
	while (size > 11 && text_w(c, s, size, bold) > maxw) size *= 0.92;
	text_center(c, s, cx, cy, size, bold);
}

/* A title of one line, or of two lines when it does not fit in one. */
static void title_center(cairo_t *c, const char *s, double cx, double cy, double maxw, double size, int bold)
{
	char a[64], *sp = NULL, *p;
	if (text_w(c, s, size, bold) <= maxw || !strchr(s, ' ')) { fit_center(c, s, cx, cy, maxw, size, bold); return; }
	snprintf(a, sizeof a, "%s", s);
	for (p = a; *p; p++)    /* the space nearest to the middle */
		if (*p == ' ' && (!sp || labs(p - a - (long)strlen(a) / 2) < labs(sp - a - (long)strlen(a) / 2))) sp = p;
	*sp = 0;
	while (size > 11 && (text_w(c, a, size, bold) > maxw || text_w(c, sp + 1, size, bold) > maxw)) size *= 0.92;
	text_center(c, a, cx, cy - size * 0.6, size, bold);
	text_center(c, sp + 1, cx, cy + size * 0.6, size, bold);
}

static void layout(void)
{
	if (mode == FULL) {
		nslot = 0;
		if (surf_w <= 0 || surf_h <= 0) return;
		geom = ov_geometry(&lay.grid, surf_w, surf_h);
		pan = geom.panel;
		nslot = ov_place(&lay, slot);
		for (int i = 0; i < nslot; i++) tile[i] = ov_cell_rect(&geom, slot[i].cell);
	} else {
		pan = (struct rect){ 0, 0, surf_w, surf_h };
		r_track = overlay_slider_track(pan.h);
	}
}

/* The scale of the text and the icons: 1 on a tile of 150 px. */
static double kscale(void)
{
	double k = geom.tile / 150.0;
	return k < 0.5 ? 0.5 : k > 1.5 ? 1.5 : k;
}

/* The track of a slider tile r (panel coordinates). A tile that is wider than
 * high has a horizontal track. */
static void tile_track(struct rect r, double k, struct rect *t, int *vert, int *compact)
{
	*vert = r.h >= r.w;
	*compact = r.h < 250 * k;
	if (*vert) {
		double tw = 70 * k, top = r.y + (*compact ? 56 : 90) * k, bot = r.y + r.h - (*compact ? 56 : 80) * k;
		if (tw > r.w * 0.6) tw = r.w * 0.6;
		if (bot - top < 20) bot = top + 20;
		*t = (struct rect){ (int)(r.x + (r.w - tw) / 2), (int)top, (int)tw, (int)(bot - top) };
	} else {
		double th = 44 * k, left = r.x + 64 * k, right = r.x + r.w - 116 * k;   /* room for "100 %" */
		if (th > r.h * 0.5) th = r.h * 0.5;
		if (right - left < 30) right = left + 30;
		*t = (struct rect){ (int)left, (int)(r.y + (r.h - th) / 2 - 8 * k), (int)(right - left), (int)th };
	}
}

/* A slider on the track t. frac < 0 = no value. The slider mode and the tiles
 * both use it, with k = 1 for the slider mode. */
static void draw_slider(cairo_t *c, struct rect t, int vert, int compact, double k, double frac, int speaker_icon,
			int muted, const char *txt, const char *sub, const double col[3])
{
	cairo_set_source_rgba(c, col[0], col[1], col[2], 1);
	if (vert) {
		double cx = t.x + t.w / 2.0, iy = t.y - (compact ? 28 : 50) * k, ir = (compact ? 16 : 22) * k;
		if (speaker_icon) speaker(c, cx, iy, ir, muted); else sun(c, cx, iy, ir);
	} else {
		double iy = t.y + t.h / 2.0;
		if (speaker_icon) speaker(c, t.x - 32 * k, iy, 20 * k, muted); else sun(c, t.x - 32 * k, iy, 20 * k);
	}
	rounded(c, t.x, t.y, t.w, t.h, (vert ? t.w : t.h) / 2.0);
	cairo_set_source_rgba(c, 1, 1, 1, 0.14);
	cairo_fill(c);
	if (frac >= 0) {
		if (vert) {
			double fh = t.w + frac * (t.h - t.w);
			rounded(c, t.x, t.y + t.h - fh, t.w, fh, t.w / 2.0);
		} else {
			double fw = t.h + frac * (t.w - t.h);
			rounded(c, t.x, t.y, fw, t.h, t.h / 2.0);
		}
		cairo_set_source_rgba(c, col[0], col[1], col[2], 0.95);
		cairo_fill(c);
	}
	cairo_set_source_rgba(c, 1, 1, 1, 0.95);
	if (vert) {
		double cx = t.x + t.w / 2.0;
		text_center(c, txt, cx, t.y + t.h + (compact ? 28 : 32) * k, (compact ? 24 : 30) * k, 1);
		if (sub[0] && !compact) {
			cairo_set_source_rgba(c, 1, 1, 1, 0.6);
			text_center(c, sub, cx, t.y + t.h + 66 * k, 18 * k, 0);
		}
	} else {
		text_center(c, txt, t.x + t.w + 58 * k, t.y + t.h / 2.0, 26 * k, 1);
		if (sub[0]) {
			cairo_set_source_rgba(c, 1, 1, 1, 0.6);
			text_center(c, sub, t.x + t.w / 2.0, t.y + t.h + 22 * k, 18 * k, 0);
		}
	}
}

/* How the level came about: auto (ALS) plus or minus the manual offset, or a
 * fixed level from Home Assistant or a key action. */
static void bright_text(char *s, size_t n, int shown, char *sub, size_t sn)
{
	if (shown > 0) snprintf(s, n, "%d %%", overlay_percent(shown, maxlvl)); else snprintf(s, n, "-");
	if (override > 0) snprintf(sub, sn, "fixed");
	else if (offset) snprintf(sub, sn, "%s %+d", als_auto == 1 ? "auto" : "sched", offset);
	else snprintf(sub, sn, "%s", als_auto == 1 ? "auto" : "sched");
}

static const double COL_SUN[3] = { 1.0, 0.78, 0.30 }, COL_VOL[3] = { 0.45, 0.75, 1.0 };
static const char *const def_label[WT_COUNT] = {
	"", "", "Auto brightness", "Screen off", "Reload page", "Setup", "Close", "", "Dark mode", "Keyboard",
	"", "", "Restart", "LED bar"
};

static void draw_tile(cairo_t *c, int si)
{
	const struct ov_item *it = &lay.item[slot[si].item];
	struct rect r = tile[si], t;
	double k = kscale(), cx = r.x + r.w / 2.0, cy = r.y + r.h / 2.0, radius = 22 * k;
	int type = it->type, vert, compact, down = pressed == si && press_inside;
	int armed = type == WT_REBOOT && reboot_armed && now_ms() < reboot_armed;
	int on = 0, dis = 0;
	const char *title = it->label[0] ? it->label : def_label[type], *sub = "";
	char s[64], s2[64];

	if (type == WT_UNKNOWN) return;      /* its cells stay empty */
	switch (type) {
	case WT_AUTO_BRIGHTNESS: dis = als_auto < 0; on = als_auto == 1; sub = dis ? "no sensor" : on ? "on" : "off"; break;
	case WT_DARK_MODE: dis = dark < 0; on = dark == 1; sub = dis ? "n/a" : on ? "on" : "off"; break;
	case WT_LED_BAR: dis = ledbar < 0; on = ledbar == 1; sub = dis ? "no LED bar" : on ? "on" : "off"; break;
	case WT_VOLUME: dis = vol < 0; break;
	default: break;
	}
	rounded(c, r.x, r.y, r.w, r.h, radius);
	if (armed) cairo_set_source_rgba(c, 0.80, 0.18, 0.18, down ? 1.0 : 0.9);
	else if (down && type != WT_BRIGHTNESS && type != WT_VOLUME) cairo_set_source_rgba(c, 1, 1, 1, 0.35);
	else if (on) cairo_set_source_rgba(c, 1.0, 0.78, 0.30, 0.85);
	else cairo_set_source_rgba(c, 1, 1, 1, dis ? 0.05 : type == WT_CLOCK || type == WT_INFO ? 0.08 : 0.13);
	cairo_fill(c);

	switch (type) {
	case WT_BRIGHTNESS: {
		int shown = drag_level > 0 ? drag_level : level;
		tile_track(r, k, &t, &vert, &compact);
		bright_text(s, sizeof s, shown, s2, sizeof s2);
		draw_slider(c, t, vert, compact, k, shown > 0 ? tsx_level_to_pos(shown, minlvl, maxlvl) : -1, 0, 0, s, s2, COL_SUN);
		break;
	}
	case WT_VOLUME: {
		int v = vol_drag >= 0 ? vol_drag : vol;
		if (dis) {
			cairo_set_source_rgba(c, 1, 1, 1, 0.35);
			speaker(c, cx, cy - 24 * k, 20 * k, 0);
			fit_center(c, "no audio", cx, cy + 22 * k, r.w - 16, 20 * k, 0);
			break;
		}
		tile_track(r, k, &t, &vert, &compact);
		snprintf(s, sizeof s, "%d %%", v);
		draw_slider(c, t, vert, compact, k, v / 100.0, 1, mute == 1, s, mute == 1 ? "muted" : "", COL_VOL);
		break;
	}
	case WT_CLOCK: {
		time_t now = time(NULL); struct tm tm; localtime_r(&now, &tm);
		strftime(s, sizeof s, "%H:%M", &tm); strftime(s2, sizeof s2, "%a %d %b", &tm);
		cairo_set_source_rgba(c, 1, 1, 1, 0.95);
		fit_center(c, s, cx, cy - 12 * k, r.w - 16, 48 * k, 1);
		cairo_set_source_rgba(c, 1, 1, 1, 0.6);
		fit_center(c, s2, cx, cy + 30 * k, r.w - 16, 20 * k, 0);
		break;
	}
	case WT_INFO:
		cairo_set_source_rgba(c, 1, 1, 1, 0.95);
		fit_center(c, info_host, cx, cy - 26 * k, r.w - 16, 20 * k, 1);
		cairo_set_source_rgba(c, 1, 1, 1, 0.75);
		fit_center(c, info_ip, cx, cy, r.w - 16, 18 * k, 0);
		fit_center(c, info_ver, cx, cy + 26 * k, r.w - 16, 16 * k, 0);
		break;
	default:
		if (on) cairo_set_source_rgba(c, 0.08, 0.09, 0.11, 1);
		else cairo_set_source_rgba(c, 1, 1, 1, dis ? 0.35 : 0.95);
		if (armed) title = "Tap again to restart";
		{
			int two = text_w(c, title, 24 * k, 1) > r.w - 16 && strchr(title, ' ');
			title_center(c, title, cx, cy - (sub[0] ? (two ? 26 : 14) * k : 0), r.w - 16, 24 * k, 1);
			if (sub[0]) fit_center(c, sub, cx, cy + (two ? 38 : 24) * k, r.w - 16, 20 * k, 0);
		}
		break;
	}
}

static void draw(cairo_t *c)
{
	cairo_set_operator(c, CAIRO_OPERATOR_SOURCE);
	cairo_set_source_rgba(c, 0, 0, 0, mode == FULL ? dim : 0);   /* the dim part */
	cairo_paint(c);
	cairo_set_operator(c, CAIRO_OPERATOR_OVER);
	cairo_translate(c, pan.x, pan.y);
	rounded(c, 1, 1, pan.w - 2, pan.h - 2, 28);
	cairo_set_source_rgba(c, 0.08, 0.09, 0.11, 0.95);
	cairo_fill_preserve(c);
	cairo_set_source_rgba(c, 1, 1, 1, 0.15);
	cairo_set_line_width(c, 2);
	cairo_stroke(c);

	if (mode == FULL) {
		for (int i = 0; i < nslot; i++) draw_tile(c, i);
		return;
	}
	/* the slider mode */
	{
		int shown = drag_level > 0 ? drag_level : level;
		char s[32], sub[32];
		bright_text(s, sizeof s, shown, sub, sizeof sub);
		draw_slider(c, r_track, 1, 0, 1, shown > 0 ? tsx_level_to_pos(shown, minlvl, maxlvl) : -1, 0, 0, s, sub, COL_SUN);
	}
}
/* ---- wl_shm buffers --------------------------------------------------------- */
static void buffer_release(void *data, struct wl_buffer *wb) { (void)wb; ((struct buffer *)data)->busy = 0; }
static const struct wl_buffer_listener buffer_listener = { .release = buffer_release };

static void buffer_free(struct buffer *b)
{
	if (b->cs) cairo_surface_destroy(b->cs);
	if (b->wb) wl_buffer_destroy(b->wb);
	if (b->data) munmap(b->data, b->size);
	memset(b, 0, sizeof *b);
}

static struct buffer *buffer_get(int w, int h)
{
	struct buffer *b = NULL;
	for (int i = 0; i < 2; i++) {
		if (bufs[i].busy) continue;
		if (bufs[i].wb && (bufs[i].w != w || bufs[i].h != h)) buffer_free(&bufs[i]);
		b = &bufs[i]; break;
	}
	if (!b) return NULL;
	if (b->wb) return b;
	int stride = w * 4, fd = memfd_create("tsx-overlay", MFD_CLOEXEC);
	b->size = (size_t)stride * h;
	if (fd < 0 || ftruncate(fd, b->size)) { logm("shm: %s", strerror(errno)); if (fd >= 0) close(fd); return NULL; }
	b->data = mmap(NULL, b->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (b->data == MAP_FAILED) { b->data = NULL; close(fd); return NULL; }
	struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, b->size);
	b->wb = wl_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_ARGB8888);
	wl_shm_pool_destroy(pool);
	close(fd);
	wl_buffer_add_listener(b->wb, &buffer_listener, b);
	b->cs = cairo_image_surface_create_for_data(b->data, CAIRO_FORMAT_ARGB32, w, h, stride);
	b->w = w; b->h = h;
	return b;
}

static void redraw(void)
{
	if (!surface || !configured) return;
	struct buffer *b = buffer_get(surf_w, surf_h);
	if (!b) return;          /* both busy: the next event redraws */
	cairo_t *c = cairo_create(b->cs);
	draw(c);
	cairo_destroy(c);
	cairo_surface_flush(b->cs);
	b->busy = 1;
	wl_surface_attach(surface, b->wb, 0, 0);
	/* The dim part never changes: after the first frame, only the panel. */
	if (damage_all) { wl_surface_damage(surface, 0, 0, surf_w, surf_h); damage_all = 0; }
	else wl_surface_damage(surface, pan.x, pan.y, pan.w, pan.h);
	wl_surface_commit(surface);
}

/* ---- layer surface ------------------------------------------------------------ */
static void surface_destroy(void);

static void layer_configure(void *data, struct zwlr_layer_surface_v1 *l, uint32_t serial, uint32_t w, uint32_t h)
{
	(void)data;
	zwlr_layer_surface_v1_ack_configure(l, serial);
	if (w) surf_w = w;
	if (mode == FULL) {
		/* The surface covers the output, so its size is the output size. */
		if (h) out_h = surf_h = h;
	} else if (h) {
		/* The output height. It also changes when the screen turns. If
		 * another margin is due, set it and wait for the next configure. */
		out_h = (int)h + 2 * cur_mv;
		int mv = overlay_margin_v(out_h);
		if (mv != cur_mv) {
			cur_mv = mv;
			zwlr_layer_surface_v1_set_margin(l, mv, MARGIN_R, mv, 0);
			wl_surface_commit(surface);
			return;
		}
		surf_h = h;
	}
	layout();       /* the height comes from the output */
	configured = 1;
	damage_all = 1;
	redraw();
}

static void layer_closed(void *data, struct zwlr_layer_surface_v1 *l)
{
	(void)data; (void)l;
	surface_destroy(); mode = HIDDEN;
}

static const struct zwlr_layer_surface_v1_listener layer_listener = {
	.configure = layer_configure, .closed = layer_closed,
};

static void surface_destroy(void)
{
	if (layer) zwlr_layer_surface_v1_destroy(layer);
	if (surface) wl_surface_destroy(surface);
	layer = NULL; surface = NULL; configured = 0;
	for (int i = 0; i < 2; i++) buffer_free(&bufs[i]);
	pressed = NOPRESS; touch_id = -1; ptr_down = 0; drag_level = -1;
}

static void show(enum mode m)
{
	int w = SLIDER_W, mv = overlay_margin_v(out_h);
	read_state();
	if (m == mode && surface) return;
	/* The slider and the full overlay have other anchors: a new surface. */
	if (surface) surface_destroy();
	mode = m;
	surf_w = w;
	surf_h = 0;     /* the configure event brings the size */
	shown_at = now_ms();
	reboot_armed = 0;
	if (m == FULL) {
		load_layout();        /* an edit of the file applies at the next show */
		nslot = ov_place(&lay, slot);
		read_ext();
	}
	layout();
	if (!surface) {
		surface = wl_compositor_create_surface(compositor);
		layer = zwlr_layer_shell_v1_get_layer_surface(layer_shell, surface, NULL,
			ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, "tsx-overlay");
		zwlr_layer_surface_v1_add_listener(layer, &layer_listener, NULL);
		zwlr_layer_surface_v1_set_anchor(layer, ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT |
			ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
			(m == FULL ? ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT : 0));
		zwlr_layer_surface_v1_set_exclusive_zone(layer, -1);   /* never moves the page */
		zwlr_layer_surface_v1_set_keyboard_interactivity(layer, ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
		configured = 0;
	}
	if (m == FULL) {
		/* size 0 x 0 + four anchors: the compositor gives the whole output */
		cur_mv = 0;
		zwlr_layer_surface_v1_set_margin(layer, 0, 0, 0, 0);
		zwlr_layer_surface_v1_set_size(layer, 0, 0);
	} else {
		/* height 0 + top/bottom anchors: the compositor sizes it to the output */
		cur_mv = mv;
		zwlr_layer_surface_v1_set_margin(layer, mv, MARGIN_R, mv, 0);
		zwlr_layer_surface_v1_set_size(layer, w, 0);
	}
	wl_surface_commit(surface);     /* -> configure -> redraw */
	if (verbose) logm("show %s", m == FULL ? "full" : "slider");
}

static void hide(void)
{
	if (mode == HIDDEN) return;
	surface_destroy();
	mode = HIDDEN;
	reboot_armed = 0; vol_drag = -1;
	if (verbose) logm("hide");
}


/* The full overlay: OVERLAY_FULL_MS (tests) or the "timeout" of the layout
 * file. A timeout of 0 keeps it open until a touch closes it. */
static void keep_open(void)
{
	long long ms = slider_ms;
	if (mode == FULL) ms = full_ms > 0 ? full_ms : lay.timeout_s > 0 ? lay.timeout_s * 1000LL : 365LL * 86400000;
	hide_at = now_ms() + ms;
}

/* ---- input -------------------------------------------------------------------- */
static int hit(double x, double y)
{
	for (int i = 0; i < nslot; i++) if (in_rect(&tile[i], x, y)) return i;
	return NOPRESS;
}

static int is_slider(int p)
{
	return p == PRESS_SLIDER || (p >= 0 && (slot_type(p) == WT_BRIGHTNESS || (slot_type(p) == WT_VOLUME && vol >= 0)));
}

/* The finger is at x, y (panel coordinates) on the slider p. */
static void slider_at(int p, double x, double y)
{
	struct rect t; int vert, compact;
	double frac;
	if (p == PRESS_SLIDER) { t = r_track; vert = 1; }
	else tile_track(tile[p], kscale(), &t, &vert, &compact);
	frac = vert ? (t.y + t.h - y) / t.h : (x - t.x) / t.w;
	if (frac < 0) frac = 0;
	if (frac > 1) frac = 1;
	if (p != PRESS_SLIDER && slot_type(p) == WT_VOLUME) set_vol((int)(frac * 100 + 0.5));
	else set_level(tsx_pos_to_level(frac, minlvl, maxlvl));
}

/* A press on the dim part of the full overlay (outside the panel) closes it.
 * The guard time after the show keeps a finger of the opening gesture from
 * closing it. */
static int press_outside(double x, double y)
{
	if (mode != FULL || in_rect(&pan, x, y)) return 0;
	if (now_ms() - shown_at >= dim_guard_ms) {
		if (verbose) logm("touch outside the panel: close");
		hide();
	}
	return 1;
}

static void press_down(double x, double y)
{
	if (press_outside(x, y)) return;
	x -= pan.x; y -= pan.y;
	keep_open();
	if (mode == SLIDER) pressed = y >= 60 && y < pan.h - 40 ? PRESS_SLIDER : NOPRESS;
	else pressed = hit(x, y);
	press_inside = 1;
	if (is_slider(pressed)) {
		if (pressed == PRESS_SLIDER || slot_type(pressed) == WT_BRIGHTNESS) { drag_level = -1; read_state(); }
		slider_at(pressed, x, y);
	}
	redraw();
}

static void press_move(double x, double y)
{
	if (pressed == NOPRESS) return;
	x -= pan.x; y -= pan.y;
	keep_open();
	if (is_slider(pressed)) { slider_at(pressed, x, y); redraw(); return; }
	int in = in_rect(&tile[pressed], x, y);
	if (in != press_inside) { press_inside = in; redraw(); }
}

static void press_up(void)
{
	int p = pressed;
	pressed = NOPRESS;
	if (p == NOPRESS) { redraw(); return; }
	if (is_slider(p)) {
		keep_open();
		if (p != PRESS_SLIDER && slot_type(p) == WT_VOLUME) {
			if (vol_drag >= 0) { panelctl_send("volume %d", vol_drag); vol = vol_drag; vol_drag = -1; vol_read_at = now_ms() + 1500; }
		} else drag_hold = now_ms() + 700;
		redraw(); return;
	}
	if (!press_inside) { redraw(); return; }
	switch (slot_type(p)) {
	case WT_AUTO_BRIGHTNESS:
		if (als_auto >= 0) { panelctl_send("als auto %s", als_auto == 1 ? "off" : "on"); als_auto = !als_auto; }
		keep_open(); redraw(); break;
	case WT_SCREEN_OFF: panelctl_send("blank on"); hide(); break;
	case WT_RELOAD_PAGE: panelctl_send("reload-page"); hide(); break;
	case WT_SETUP: panelctl_send("setup"); hide(); break;
	case WT_CLOSE: hide(); break;
	case WT_DARK_MODE:
		/* the kiosk restarts, so this overlay goes with it */
		if (dark >= 0) { panelctl_send("dark-mode %s", dark ? "off" : "on"); dark = !dark; hide(); }
		else redraw();
		break;
	case WT_KEYBOARD: hide(); run_osk(); break;
	case WT_LED_BAR:
		if (ledbar >= 0) { panelctl_send("ledbar %s", ledbar ? "off" : "on"); ledbar = !ledbar; }
		keep_open(); redraw(); break;
	case WT_REBOOT:
		if (reboot_armed && now_ms() < reboot_armed) { reboot_armed = 0; panelctl_send("reboot"); hide(); }
		else { reboot_armed = now_ms() + 3000; keep_open(); redraw(); }
		break;
	default: redraw(); break;     /* clock, info, an unknown widget: no action */
	}
}

static void touch_down(void *d, struct wl_touch *t, uint32_t serial, uint32_t time, struct wl_surface *s,
		       int32_t id, wl_fixed_t x, wl_fixed_t y)
{
	(void)d; (void)t; (void)serial; (void)time;
	if (s != surface || touch_id >= 0) return;
	touch_id = id;
	press_down(wl_fixed_to_double(x), wl_fixed_to_double(y));
}
static void touch_up(void *d, struct wl_touch *t, uint32_t serial, uint32_t time, int32_t id)
{
	(void)d; (void)t; (void)serial; (void)time;
	if (id != touch_id) return;
	touch_id = -1; press_up();
}
static void touch_motion(void *d, struct wl_touch *t, uint32_t time, int32_t id, wl_fixed_t x, wl_fixed_t y)
{
	(void)d; (void)t; (void)time;
	if (id == touch_id) press_move(wl_fixed_to_double(x), wl_fixed_to_double(y));
}
static void touch_frame(void *d, struct wl_touch *t) { (void)d; (void)t; }
static void touch_cancel(void *d, struct wl_touch *t) { (void)d; (void)t; touch_id = -1; pressed = NOPRESS; redraw(); }
static void touch_shape(void *d, struct wl_touch *t, int32_t id, wl_fixed_t a, wl_fixed_t b) { (void)d; (void)t; (void)id; (void)a; (void)b; }
static void touch_orient(void *d, struct wl_touch *t, int32_t id, wl_fixed_t o) { (void)d; (void)t; (void)id; (void)o; }
static const struct wl_touch_listener touch_listener = {
	.down = touch_down, .up = touch_up, .motion = touch_motion, .frame = touch_frame,
	.cancel = touch_cancel, .shape = touch_shape, .orientation = touch_orient,
};

static int ptr_on;
static void ptr_enter(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *s, wl_fixed_t x, wl_fixed_t y)
{
	(void)d; (void)p; (void)serial;
	ptr_on = s == surface; ptr_x = wl_fixed_to_double(x); ptr_y = wl_fixed_to_double(y);
}
static void ptr_leave(void *d, struct wl_pointer *p, uint32_t serial, struct wl_surface *s)
{
	(void)d; (void)p; (void)serial; (void)s;
	ptr_on = 0;
	if (ptr_down) { ptr_down = 0; press_inside = 0; press_up(); }
}
static void ptr_motion(void *d, struct wl_pointer *p, uint32_t time, wl_fixed_t x, wl_fixed_t y)
{
	(void)d; (void)p; (void)time;
	ptr_x = wl_fixed_to_double(x); ptr_y = wl_fixed_to_double(y);
	if (ptr_down) press_move(ptr_x, ptr_y);
}
static void ptr_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t time, uint32_t button, uint32_t st)
{
	(void)d; (void)p; (void)serial; (void)time; (void)button;
	if (!ptr_on) return;
	if (st == WL_POINTER_BUTTON_STATE_PRESSED && !ptr_down) { ptr_down = 1; press_down(ptr_x, ptr_y); }
	else if (st == WL_POINTER_BUTTON_STATE_RELEASED && ptr_down) { ptr_down = 0; press_up(); }
}
static void ptr_axis(void *d, struct wl_pointer *p, uint32_t time, uint32_t axis, wl_fixed_t v) { (void)d; (void)p; (void)time; (void)axis; (void)v; }
static void ptr_frame(void *d, struct wl_pointer *p) { (void)d; (void)p; }
static void ptr_axis_source(void *d, struct wl_pointer *p, uint32_t s) { (void)d; (void)p; (void)s; }
static void ptr_axis_stop(void *d, struct wl_pointer *p, uint32_t t, uint32_t a) { (void)d; (void)p; (void)t; (void)a; }
static void ptr_axis_discrete(void *d, struct wl_pointer *p, uint32_t a, int32_t v) { (void)d; (void)p; (void)a; (void)v; }
static void ptr_axis_v120(void *d, struct wl_pointer *p, uint32_t a, int32_t v) { (void)d; (void)p; (void)a; (void)v; }
static void ptr_axis_dir(void *d, struct wl_pointer *p, uint32_t a, uint32_t v) { (void)d; (void)p; (void)a; (void)v; }
static const struct wl_pointer_listener pointer_listener = {
	.enter = ptr_enter, .leave = ptr_leave, .motion = ptr_motion, .button = ptr_button,
	.axis = ptr_axis, .frame = ptr_frame, .axis_source = ptr_axis_source, .axis_stop = ptr_axis_stop,
	.axis_discrete = ptr_axis_discrete, .axis_value120 = ptr_axis_v120,
	.axis_relative_direction = ptr_axis_dir,
};

static void seat_caps(void *d, struct wl_seat *s, uint32_t caps)
{
	(void)d;
	if ((caps & WL_SEAT_CAPABILITY_TOUCH) && !touch) {
		touch = wl_seat_get_touch(s); wl_touch_add_listener(touch, &touch_listener, NULL);
	} else if (!(caps & WL_SEAT_CAPABILITY_TOUCH) && touch) { wl_touch_destroy(touch); touch = NULL; }
	if ((caps & WL_SEAT_CAPABILITY_POINTER) && !pointer) {
		pointer = wl_seat_get_pointer(s); wl_pointer_add_listener(pointer, &pointer_listener, NULL);
	} else if (!(caps & WL_SEAT_CAPABILITY_POINTER) && pointer) { wl_pointer_destroy(pointer); pointer = NULL; }
}
static void seat_name(void *d, struct wl_seat *s, const char *n) { (void)d; (void)s; (void)n; }
static const struct wl_seat_listener seat_listener = { .capabilities = seat_caps, .name = seat_name };

static void reg_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver)
{
	(void)d;
#define MIN(a, b) ((a) < (b) ? (a) : (b))
	if (!strcmp(iface, wl_compositor_interface.name))
		compositor = wl_registry_bind(r, name, &wl_compositor_interface, MIN(ver, 4));
	else if (!strcmp(iface, wl_shm_interface.name))
		shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
	else if (!strcmp(iface, wl_seat_interface.name) && !seat) {
		seat = wl_registry_bind(r, name, &wl_seat_interface, MIN(ver, 7));
		wl_seat_add_listener(seat, &seat_listener, NULL);
	} else if (!strcmp(iface, zwlr_layer_shell_v1_interface.name))
		layer_shell = wl_registry_bind(r, name, &zwlr_layer_shell_v1_interface, MIN(ver, 4));
#undef MIN
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t name) { (void)d; (void)r; (void)name; }
static const struct wl_registry_listener reg_listener = { .global = reg_global, .global_remove = reg_remove };

/* ---- control FIFO ------------------------------------------------------------- */
static void ctl_open(void)
{
	struct stat st;
	if (ctl_fd >= 0) return;
	/* Open it read-write, so it never gives EOF when tsx-buttons closes its end. Group kiosk. */
	if ((ctl_fd = open(ctlpath, O_RDWR | O_NONBLOCK | O_CLOEXEC)) < 0) return;
	if (fstat(ctl_fd, &st) || !S_ISFIFO(st.st_mode)) { close(ctl_fd); ctl_fd = -1; return; }
	logm("listening on %s", ctlpath);
}

static void ctl_read(void)
{
	static char buf[256]; static size_t len;
	ssize_t r;
	while ((r = read(ctl_fd, buf + len, sizeof buf - 1 - len)) > 0) {
		len += r; buf[len] = 0;
		char *nl;
		while ((nl = strchr(buf, '\n'))) {
			*nl = 0;
			if (!strcmp(buf, "slider")) { want_mode = mode == FULL ? FULL : SLIDER; }
			else if (!strcmp(buf, "full")) want_mode = FULL;
			else if (!strcmp(buf, "hide")) want_mode = HIDDEN;
			else if (!strcmp(buf, "toggle")) want_mode = mode == HIDDEN ? FULL : HIDDEN;
			else logm("unknown command '%.40s'", buf);
			if (want_mode == HIDDEN) hide();
			else {
				show(want_mode); keep_open();
				if (read_state()) redraw();
			}
			memmove(buf, nl + 1, len - (nl + 1 - buf) + 1); len -= nl + 1 - buf;
		}
		if (len >= sizeof buf - 1) len = 0;
	}
}

static void on_sig(int s) { (void)s; sig_term = 1; }

int main(void)
{
	struct sigaction sa = { .sa_handler = on_sig };
	if (getenv("TSX_RUN_DIR")) rundir = getenv("TSX_RUN_DIR");
	if (getenv("OVERLAY_SLIDER_MS")) slider_ms = atoi(getenv("OVERLAY_SLIDER_MS"));
	if (getenv("OVERLAY_FULL_MS")) full_ms = atoi(getenv("OVERLAY_FULL_MS"));
	if (getenv("OVERLAY_DIM")) dim = atof(getenv("OVERLAY_DIM"));
	if (dim < 0) dim = 0;
	if (dim > 1) dim = 1;
	if (getenv("TSX_PANELCTL_BIN")) snprintf(ctlbin, sizeof ctlbin, "%s", getenv("TSX_PANELCTL_BIN"));
	if (getenv("TSX_OSK_BIN")) snprintf(oskbin, sizeof oskbin, "%s", getenv("TSX_OSK_BIN"));
	ov_layout_default(&lay);
	if (getenv("OVERLAY_DIM_GUARD_MS")) dim_guard_ms = atoi(getenv("OVERLAY_DIM_GUARD_MS"));
	verbose = getenv("TSX_OVERLAY_VERBOSE") && atoi(getenv("TSX_OVERLAY_VERBOSE"));
	snprintf(ctlpath, sizeof ctlpath, "%s/overlay.ctl", rundir);
	snprintf(panelctl, sizeof panelctl, "%s/panelctl", rundir);
	snprintf(bstate, sizeof bstate, "%s/brightness.state", rundir);
	snprintf(astate, sizeof astate, "%s/als.state", rundir);
	sigemptyset(&sa.sa_mask);
	sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);

	if (!(dpy = wl_display_connect(NULL))) { logm("no Wayland display (WAYLAND_DISPLAY)"); return 1; }
	struct wl_registry *reg = wl_display_get_registry(dpy);
	wl_registry_add_listener(reg, &reg_listener, NULL);
	wl_display_roundtrip(dpy);
	wl_display_roundtrip(dpy);
	if (!compositor || !shm || !layer_shell) {
		logm("compositor lacks %s", !layer_shell ? "wlr-layer-shell (cage?)" : "wl_compositor/wl_shm");
		return 1;
	}
	/* Load the fonts now, not on the first slide step. */
	{
		cairo_surface_t *cs = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 8, 8);
		cairo_t *c = cairo_create(cs);
		text_center(c, "0", 4, 4, 20, 1); text_center(c, "0", 4, 4, 20, 0);
		cairo_destroy(c); cairo_surface_destroy(cs);
	}
	ctl_open();
	logm("ready (%s%s)", ctlpath, ctl_fd < 0 ? ": not there yet, retrying" : "");

	while (!sig_term) {
		long long t = now_ms();
		int to = -1;
		if (mode != HIDDEN) {
			if (t >= hide_at && pressed == NOPRESS) { hide(); continue; }
			to = drag_level > 0 ? 100 : 250;   /* follow tsx-idled/ALS changes while shown */
			if (hide_at - t < to) to = hide_at - t < 0 ? 0 : (int)(hide_at - t);
		}
		if (ctl_fd < 0) { ctl_open(); if (ctl_fd < 0 && (to < 0 || to > 5000)) to = 5000; }

		while (waitpid(-1, NULL, WNOHANG) > 0) ;   /* the keyboard command */
		while (wl_display_prepare_read(dpy) != 0) wl_display_dispatch_pending(dpy);
		if (wl_display_flush(dpy) < 0 && errno != EAGAIN) { wl_display_cancel_read(dpy); break; }
		struct pollfd pfd[2] = { { .fd = wl_display_get_fd(dpy), .events = POLLIN }, { .fd = ctl_fd, .events = POLLIN } };
		int n = poll(pfd, ctl_fd >= 0 ? 2 : 1, to);
		if (n < 0) {
			wl_display_cancel_read(dpy);
			if (errno == EINTR) continue;
			logm("poll: %s", strerror(errno)); break;
		}
		if (pfd[0].revents & (POLLERR | POLLHUP)) { wl_display_cancel_read(dpy); logm("compositor gone"); break; }
		if (pfd[0].revents & POLLIN) { if (wl_display_read_events(dpy) < 0) break; }
		else wl_display_cancel_read(dpy);
		if (wl_display_dispatch_pending(dpy) < 0) break;
		if (ctl_fd >= 0 && (pfd[1].revents & POLLIN)) ctl_read();
		if (mode != HIDDEN && pressed == NOPRESS) {
			int ch = read_state() | tick_widgets();
			/* The slider keeps the released value until tsx-idled has it. */
			if (drag_level > 0 && (level == drag_level || now_ms() >= drag_hold)) { drag_level = -1; ch = 1; }
			if (ch) redraw();
		}
	}
	hide();
	wl_display_flush(dpy);
	wl_display_disconnect(dpy);
	return 0;
}
