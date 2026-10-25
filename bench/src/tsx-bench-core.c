/*
 * tsx-bench-core: the measuring part of tsx-bench.
 *
 * One static program, plain C99 + POSIX threads, no other library. Every
 * command prints one JSON value on stdout and progress lines on stderr.
 *
 *   tsx-bench-core info                        hardware and software facts
 *   tsx-bench-core state                       load, governors, temperatures, kiosk
 *   tsx-bench-core cpu [-s SCALE] [-q]         integer and float scores
 *   tsx-bench-core mem [-q]                    bandwidth and latency
 *   tsx-bench-core sustained SECONDS [-t MC]   all cores busy, log freq and temp
 *   tsx-bench-core storage [-d DEV|-f FILE] [-q]   read speed (no write)
 *   tsx-bench-core browser HTML [-p PORT] [-r FILE]  run a page in the kiosk browser
 *   tsx-bench-core restore [-p PORT] [-r FILE]       load the saved kiosk address again
 *   tsx-bench-core net IPV4 PORT [-s SEC]      TCP throughput to a server
 *   tsx-bench-core netserver PORT [IDLE_SEC]   the server side of "net"
 *   tsx-bench-core timeit LABEL COMMAND [N]   time a shell command line, best of N
 *   tsx-bench-core gen FILE MIB                write text-like test data to tmpfs
 *
 * Safety: the program writes only the file that "gen" names (it must be on a
 * tmpfs), the file of "browser -r" and /proc/sys/vm/drop_caches. It opens a
 * block device O_RDONLY and nothing else.
 */
#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64 /* offsets above 2 GiB on a 32-bit CPU */
#include <arpa/inet.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define TOOL_VERSION "0.2.0"

#ifndef BLKGETSIZE64
#define BLKGETSIZE64 _IOR(0x12, 114, size_t)
#endif

/* ------------------------------------------------------------------ */
/* helpers                                                            */
/* ------------------------------------------------------------------ */

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void say(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	fflush(stderr);
}

static void die(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "tsx-bench-core: ");
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(1);
}

/* Read a small text file into buf and strip the trailing white space. */
static int slurp(const char *path, char *buf, size_t n)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0)
		return -1;
	ssize_t r = read(fd, buf, n - 1);
	close(fd);
	if (r < 0)
		return -1;
	buf[r] = 0;
	while (r > 0 && isspace((unsigned char)buf[r - 1]))
		buf[--r] = 0;
	return 0;
}

static long slurp_long(const char *path, long dflt)
{
	char b[64], *e;
	if (slurp(path, b, sizeof b))
		return dflt;
	long v = strtol(b, &e, 0);
	return e == b ? dflt : v;
}

static int cmp_dbl(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

static uint64_t rng_next(uint64_t *s)
{
	uint64_t x = *s;
	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	return *s = x;
}

static volatile sig_atomic_t g_stop;

static void on_signal(int sig)
{
	(void)sig;
	g_stop = 1;
}

/* ------------------------------------------------------------------ */
/* JSON writer: it tracks the commas. Keys are plain ASCII names.     */
/* ------------------------------------------------------------------ */

static int jdepth;
static char jfirst[32] = {1};

static void jsep(const char *key)
{
	if (!jfirst[jdepth])
		putchar(',');
	jfirst[jdepth] = 0;
	if (key)
		printf("\"%s\":", key);
}

static void jputs(const char *s)
{
	putchar('"');
	for (; *s; s++) {
		unsigned char c = *s;
		if (c == '"' || c == '\\')
			printf("\\%c", c);
		else if (c < 0x20)
			printf("\\u%04x", c);
		else
			putchar(c);
	}
	putchar('"');
}

static void jopen(const char *key, char br)
{
	jsep(key);
	putchar(br);
	jdepth++;
	jfirst[jdepth] = 1;
}

static void jclose(char br)
{
	jdepth--;
	putchar(br);
}

#define JOBJ(k) jopen(k, '{')
#define JARR(k) jopen(k, '[')
#define JEND() jclose('}')
#define JAEND() jclose(']')

static void jstr(const char *key, const char *v)
{
	jsep(key);
	jputs(v);
}

static void jnum(const char *key, double v)
{
	jsep(key);
	if (!isfinite(v))
		printf("null");
	else if (v == floor(v) && fabs(v) < 1e15)
		printf("%.0f", v);
	else
		printf("%.6g", v);
}

static void jint(const char *key, long long v)
{
	jsep(key);
	printf("%lld", v);
}

static void jbool(const char *key, int v)
{
	jsep(key);
	fputs(v ? "true" : "false", stdout);
}

static void jnull(const char *key)
{
	jsep(key);
	fputs("null", stdout);
}

/* A value that is already JSON text. */
static void jraw(const char *key, const char *v)
{
	jsep(key);
	fputs(v, stdout);
}

static void jfile(const char *key, const char *path)
{
	char b[512], *o = b, *i;
	if (slurp(path, b, sizeof b)) {
		jnull(key);
		return;
	}
	for (i = b; *i; i++) /* some cards report control characters in the name */
		if ((unsigned char)*i >= 0x20)
			*o++ = *i;
	*o = 0;
	jstr(key, b);
}

/* ------------------------------------------------------------------ */
/* CPU topology                                                       */
/* ------------------------------------------------------------------ */

#define MAXCPU 64
#define MAXCL 8

struct cluster {
	int ncpu;
	int cpu[MAXCPU];
	char key[160];
	long max_khz, min_khz, capacity;
	char governor[32];
	char part[16];
};

static int ncpu_online;
static int online_cpu[MAXCPU];
static struct cluster cl[MAXCL];
static int ncl;

static void read_cpu_parts(char parts[MAXCPU][16])
{
	FILE *f = fopen("/proc/cpuinfo", "r");
	char line[256];
	int cur = -1;
	if (!f)
		return;
	while (fgets(line, sizeof line, f)) {
		char *c = strchr(line, ':');
		if (!c)
			continue;
		if (!strncmp(line, "processor", 9)) {
			cur = atoi(c + 1);
		} else if (!strncmp(line, "CPU part", 8) && cur >= 0 && cur < MAXCPU) {
			c++;
			while (*c == ' ' || *c == '\t')
				c++;
			snprintf(parts[cur], 16, "%s", c);
			char *nl = strchr(parts[cur], '\n');
			if (nl)
				*nl = 0;
		}
	}
	fclose(f);
}

static void topo_init(void)
{
	char path[160], parts[MAXCPU][16];
	memset(parts, 0, sizeof parts);
	read_cpu_parts(parts);
	for (int i = 0; i < MAXCPU; i++) {
		snprintf(path, sizeof path, "/sys/devices/system/cpu/cpu%d", i);
		if (access(path, F_OK))
			continue;
		snprintf(path, sizeof path, "/sys/devices/system/cpu/cpu%d/online", i);
		if (slurp_long(path, 1) == 0)
			continue;
		online_cpu[ncpu_online++] = i;
	}
	if (!ncpu_online) {
		long n = sysconf(_SC_NPROCESSORS_ONLN);
		for (int i = 0; i < n && i < MAXCPU; i++)
			online_cpu[ncpu_online++] = i;
	}
	/* A cluster is a group of CPUs of one kind: the same core type, the same
	 * maximum frequency and the same capacity. */
	for (int k = 0; k < ncpu_online; k++) {
		int c = online_cpu[k], j;
		char key[160];
		long maxf, minf, capa;
		snprintf(path, sizeof path, "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", c);
		maxf = slurp_long(path, 0);
		snprintf(path, sizeof path, "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_min_freq", c);
		minf = slurp_long(path, 0);
		snprintf(path, sizeof path, "/sys/devices/system/cpu/cpu%d/cpu_capacity", c);
		capa = slurp_long(path, 0);
		snprintf(key, sizeof key, "%s/%ld/%ld", parts[c], maxf, capa);
		for (j = 0; j < ncl; j++)
			if (!strcmp(cl[j].key, key))
				break;
		if (j == ncl) {
			if (ncl == MAXCL) {
				j = ncl - 1;
			} else {
				ncl++;
				memset(&cl[j], 0, sizeof cl[j]);
				snprintf(cl[j].key, sizeof cl[j].key, "%s", key);
				snprintf(cl[j].part, sizeof cl[j].part, "%s", parts[c]);
				cl[j].max_khz = maxf;
				cl[j].min_khz = minf;
				cl[j].capacity = capa;
				snprintf(path, sizeof path, "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_governor", c);
				if (slurp(path, cl[j].governor, sizeof cl[j].governor))
					cl[j].governor[0] = 0;
			}
		}
		cl[j].cpu[cl[j].ncpu++] = c;
	}
	/* The biggest cluster comes first: by capacity, then by max frequency. */
	for (int a = 0; a < ncl; a++)
		for (int b = a + 1; b < ncl; b++) {
			int swap = cl[b].capacity > cl[a].capacity ||
				   (cl[b].capacity == cl[a].capacity && cl[b].max_khz > cl[a].max_khz);
			if (swap) {
				struct cluster t = cl[a];
				cl[a] = cl[b];
				cl[b] = t;
			}
		}
}

static void pin_to(int cpu)
{
	cpu_set_t s;
	CPU_ZERO(&s);
	CPU_SET(cpu, &s);
	sched_setaffinity(0, sizeof s, &s);
}

static void unpin(void)
{
	cpu_set_t s;
	CPU_ZERO(&s);
	for (int i = 0; i < ncpu_online; i++)
		CPU_SET(online_cpu[i], &s);
	sched_setaffinity(0, sizeof s, &s);
}

static void jclusters(const char *key)
{
	JARR(key);
	for (int j = 0; j < ncl; j++) {
		JOBJ(NULL);
		jint("index", j);
		JARR("cpus");
		for (int i = 0; i < cl[j].ncpu; i++)
			jint(NULL, cl[j].cpu[i]);
		JAEND();
		jstr("cpu_part", cl[j].part);
		jint("max_khz", cl[j].max_khz);
		jint("min_khz", cl[j].min_khz);
		jint("capacity", cl[j].capacity);
		jstr("governor", cl[j].governor);
		JEND();
	}
	JAEND();
}

/* ------------------------------------------------------------------ */
/* thermal zones                                                      */
/* ------------------------------------------------------------------ */

#define MAXZONE 24

static int nzone;
static int zone_id[MAXZONE];

static void zones_init(void)
{
	char p[128];
	nzone = 0;
	for (int i = 0; i < 64 && nzone < MAXZONE; i++) {
		snprintf(p, sizeof p, "/sys/class/thermal/thermal_zone%d/temp", i);
		if (access(p, R_OK) == 0)
			zone_id[nzone++] = i;
	}
}

/* Temperature in milli-degrees, or -1 when the zone gives no valid value. */
static long zone_temp(int k)
{
	char p[128];
	snprintf(p, sizeof p, "/sys/class/thermal/thermal_zone%d/temp", zone_id[k]);
	long v = slurp_long(p, -1000000);
	return (v < -40000 || v > 150000) ? -1000000 : v;
}

static long max_temp(void)
{
	long m = -1000000;
	for (int k = 0; k < nzone; k++) {
		long t = zone_temp(k);
		if (t > m)
			m = t;
	}
	return m;
}

static void jtemps(const char *key)
{
	JARR(key);
	for (int k = 0; k < nzone; k++) {
		long t = zone_temp(k);
		if (t == -1000000)
			jnull(NULL);
		else
			jint(NULL, t);
	}
	JAEND();
}

static void jzones(const char *key)
{
	char p[128], b[64];
	JARR(key);
	for (int k = 0; k < nzone; k++) {
		snprintf(p, sizeof p, "/sys/class/thermal/thermal_zone%d/type", zone_id[k]);
		if (slurp(p, b, sizeof b))
			snprintf(b, sizeof b, "zone%d", zone_id[k]);
		jstr(NULL, b);
	}
	JAEND();
}

static long cur_khz(int j)
{
	char p[128];
	snprintf(p, sizeof p, "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq", cl[j].cpu[0]);
	return slurp_long(p, -1);
}

/* ------------------------------------------------------------------ */
/* info                                                               */
/* ------------------------------------------------------------------ */

/* The driver name of a sysfs device: the last part of its "driver" link. */
static int driver_of_dev(const char *dev, char *out, size_t n)
{
	char p[400], l[200];
	snprintf(p, sizeof p, "%s/driver", dev);
	ssize_t r = readlink(p, l, sizeof l - 1);
	if (r < 0)
		return -1;
	l[r] = 0;
	char *s = strrchr(l, '/');
	snprintf(out, n, "%.*s", (int)n - 1, s ? s + 1 : l);
	return 0;
}

static void cmd_info(void)
{
	char b[512], p[320];
	struct utsname u;
	uname(&u);
	JOBJ(NULL);
	jfile("model", "/proc/device-tree/model");
	{
		FILE *f = fopen("/proc/device-tree/compatible", "r");
		if (f) {
			size_t r = fread(b, 1, sizeof b - 1, f);
			b[r] = 0;
			fclose(f);
			jstr("compatible", b); /* the first entry of the list */
		} else {
			jnull("compatible");
		}
	}
	jstr("kernel", u.release);
	jstr("kernel_build", u.version);
	jstr("arch", u.machine);
	jint("pointer_bits", (long long)sizeof(void *) * 8);
	{
		FILE *f = fopen("/etc/os-release", "r");
		char l[256];
		const char *v = NULL;
		if (f) {
			while (fgets(l, sizeof l, f))
				if (!strncmp(l, "PRETTY_NAME=", 12)) {
					char *s = l + 12;
					size_t n = strlen(s);
					while (n && (s[n - 1] == '\n' || s[n - 1] == '"'))
						s[--n] = 0;
					if (*s == '"')
						s++;
					v = s;
					break;
				}
			if (v)
				jstr("os", v);
			else
				jnull("os");
			fclose(f);
		} else {
			jnull("os");
		}
	}
	jint("cpu_count", ncpu_online);
	jclusters("clusters");
	{
		FILE *f = fopen("/proc/meminfo", "r");
		char l[128];
		long total = 0, swap = 0;
		if (f) {
			while (fgets(l, sizeof l, f)) {
				if (!strncmp(l, "MemTotal:", 9))
					total = atol(l + 9);
				if (!strncmp(l, "SwapTotal:", 10))
					swap = atol(l + 10);
			}
			fclose(f);
		}
		jint("mem_total_kb", total);
		jint("swap_total_kb", swap);
	}
	/* GPU and display drivers: the driver name of each DRM card */
	JARR("drm_drivers");
	{
		char seen[8][48];
		int ns = 0;
		for (int i = 0; i < 8; i++) {
			char dn[48];
			snprintf(p, sizeof p, "/sys/class/drm/card%d/device", i);
			if (driver_of_dev(p, dn, sizeof dn))
				continue;
			int dup = 0;
			for (int k = 0; k < ns; k++)
				if (!strcmp(seen[k], dn))
					dup = 1;
			if (dup)
				continue;
			snprintf(seen[ns++], 48, "%s", dn);
			JOBJ(NULL);
			jint("card", i);
			jstr("driver", dn);
			JEND();
		}
	}
	JAEND();
	/* devfreq devices (the GPU and the memory on some boards) */
	JARR("devfreq");
	{
		DIR *d = opendir("/sys/class/devfreq");
		struct dirent *e;
		if (d) {
			while ((e = readdir(d))) {
				if (e->d_name[0] == '.')
					continue;
				JOBJ(NULL);
				jstr("name", e->d_name);
				snprintf(p, sizeof p, "/sys/class/devfreq/%s/governor", e->d_name);
				jfile("governor", p);
				snprintf(p, sizeof p, "/sys/class/devfreq/%s/cur_freq", e->d_name);
				jfile("cur_hz", p);
				snprintf(p, sizeof p, "/sys/class/devfreq/%s/max_freq", e->d_name);
				jfile("max_hz", p);
				JEND();
			}
			closedir(d);
		}
	}
	JAEND();
	/* connected display outputs and their first mode */
	JARR("displays");
	{
		DIR *d = opendir("/sys/class/drm");
		struct dirent *e;
		if (d) {
			while ((e = readdir(d))) {
				if (strncmp(e->d_name, "card", 4) || !strchr(e->d_name, '-'))
					continue;
				snprintf(p, sizeof p, "/sys/class/drm/%s/status", e->d_name);
				if (slurp(p, b, sizeof b) || strcmp(b, "connected"))
					continue;
				JOBJ(NULL);
				jstr("output", e->d_name);
				snprintf(p, sizeof p, "/sys/class/drm/%s/modes", e->d_name);
				{
					char m[128];
					FILE *f = fopen(p, "r");
					if (f && fgets(m, sizeof m, f)) {
						m[strcspn(m, "\n")] = 0;
						jstr("mode", m);
					} else {
						jnull("mode");
					}
					if (f)
						fclose(f);
				}
				JEND();
			}
			closedir(d);
		}
	}
	JAEND();
	JEND();
	putchar('\n');
}

/* ------------------------------------------------------------------ */
/* state                                                              */
/* ------------------------------------------------------------------ */

struct pidsnap {
	int pid;
	char comm[20];
	unsigned long ticks;
};

static int snap_pids(struct pidsnap *out, int max)
{
	DIR *d = opendir("/proc");
	struct dirent *e;
	int n = 0;
	if (!d)
		return 0;
	while ((e = readdir(d)) && n < max) {
		if (!isdigit((unsigned char)e->d_name[0]))
			continue;
		char p[300], b[512];
		snprintf(p, sizeof p, "/proc/%s/stat", e->d_name);
		if (slurp(p, b, sizeof b))
			continue;
		char *lp = strchr(b, '('), *rp = strrchr(b, ')');
		if (!lp || !rp || rp < lp)
			continue;
		out[n].pid = atoi(e->d_name);
		size_t l = rp - lp - 1;
		if (l > 15)
			l = 15;
		memcpy(out[n].comm, lp + 1, l);
		out[n].comm[l] = 0;
		/* fields after ")": state(3) ... utime(14) stime(15) */
		char *s = rp + 2;
		unsigned long ut = 0, st = 0;
		int f = 3;
		while (f < 14 && *s) {
			s = strchr(s, ' ');
			if (!s)
				break;
			s++;
			f++;
		}
		if (s && f == 14)
			sscanf(s, "%lu %lu", &ut, &st);
		out[n].ticks = ut + st;
		n++;
	}
	closedir(d);
	return n;
}

struct hog {
	char comm[20];
	double pct;
};

static int cmp_hog(const void *a, const void *b)
{
	double x = ((const struct hog *)a)->pct, y = ((const struct hog *)b)->pct;
	return (x < y) - (x > y);
}

static void cpu_stat(unsigned long long *busy, unsigned long long *total)
{
	FILE *f = fopen("/proc/stat", "r");
	unsigned long long v[8] = {0};
	if (f) {
		if (fscanf(f, "cpu %llu %llu %llu %llu %llu %llu %llu %llu", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5],
			   &v[6], &v[7]) < 4) {
		}
		fclose(f);
	}
	unsigned long long all = 0;
	for (int i = 0; i < 8; i++)
		all += v[i];
	*total = all;
	*busy = all - v[3] - v[4]; /* minus idle and iowait */
}

static int proc_named(const char *prefix)
{
	DIR *d = opendir("/proc");
	struct dirent *e;
	int n = 0;
	if (!d)
		return 0;
	while ((e = readdir(d))) {
		char p[300], b[64];
		if (!isdigit((unsigned char)e->d_name[0]))
			continue;
		snprintf(p, sizeof p, "/proc/%s/comm", e->d_name);
		if (!slurp(p, b, sizeof b) && !strncmp(b, prefix, strlen(prefix)))
			n++;
	}
	closedir(d);
	return n;
}

static void cmd_state(double window)
{
	static struct pidsnap a[2048], b[2048];
	unsigned long long b0, t0, b1, t1;
	int na = snap_pids(a, 2048);
	cpu_stat(&b0, &t0);
	struct timespec ts = {(time_t)window, (long)((window - (long)window) * 1e9)};
	nanosleep(&ts, NULL);
	int nb = snap_pids(b, 2048);
	cpu_stat(&b1, &t1);
	double busy = t1 > t0 ? 100.0 * (b1 - b0) / (t1 - t0) : 0;
	long hz = sysconf(_SC_CLK_TCK);
	struct hog hogs[2048];
	int nh = 0;
	for (int i = 0; i < nb; i++) {
		unsigned long prev = 0;
		int found = 0;
		for (int k = 0; k < na; k++)
			if (a[k].pid == b[i].pid && !strcmp(a[k].comm, b[i].comm)) {
				prev = a[k].ticks;
				found = 1;
				break;
			}
		if (!found || b[i].ticks <= prev)
			continue;
		snprintf(hogs[nh].comm, sizeof hogs[nh].comm, "%s", b[i].comm);
		hogs[nh].pct = 100.0 * (b[i].ticks - prev) / hz / window;
		nh++;
	}
	qsort(hogs, nh, sizeof hogs[0], cmp_hog);

	JOBJ(NULL);
	{
		char l[128];
		double la[3] = {0};
		FILE *f = fopen("/proc/loadavg", "r");
		if (f) {
			if (fscanf(f, "%lf %lf %lf", &la[0], &la[1], &la[2]) < 3) {
			}
			fclose(f);
		}
		JARR("loadavg");
		for (int i = 0; i < 3; i++)
			jnum(NULL, la[i]);
		JAEND();
		f = fopen("/proc/uptime", "r");
		double up = 0;
		if (f) {
			if (fscanf(f, "%lf", &up) < 1) {
			}
			fclose(f);
		}
		jnum("uptime_s", up);
		f = fopen("/proc/meminfo", "r");
		long avail = 0;
		if (f) {
			while (fgets(l, sizeof l, f))
				if (!strncmp(l, "MemAvailable:", 13))
					avail = atol(l + 13);
			fclose(f);
		}
		jint("mem_available_kb", avail);
	}
	jnum("cpu_busy_pct", busy);
	jnum("window_s", window);
	JARR("busiest");
	for (int i = 0; i < nh && i < 5; i++) {
		JOBJ(NULL);
		jstr("comm", hogs[i].comm);
		jnum("cpu_pct", hogs[i].pct);
		JEND();
	}
	JAEND();
	JARR("clusters");
	for (int j = 0; j < ncl; j++) {
		char p[128];
		JOBJ(NULL);
		jint("index", j);
		snprintf(p, sizeof p, "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_governor", cl[j].cpu[0]);
		jfile("governor", p);
		long f = cur_khz(j);
		if (f < 0)
			jnull("cur_khz");
		else
			jint("cur_khz", f);
		snprintf(p, sizeof p, "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_max_freq", cl[j].cpu[0]);
		jfile("scaling_max_khz", p);
		JEND();
	}
	JAEND();
	jzones("temp_zones");
	jtemps("temp_mC");
	jint("kiosk_browser_procs", proc_named("chrom"));
	jint("compositor_procs", proc_named("sway") + proc_named("cage"));
	jbool("kiosk_ready", access("/run/tsx/kiosk.ready", F_OK) == 0);
	{
		/* DPMS and backlight: a dark screen can throttle the browser test */
		DIR *d = opendir("/sys/class/drm");
		struct dirent *e;
		char p[320], v[64];
		int on = -1;
		if (d) {
			while ((e = readdir(d))) {
				if (strncmp(e->d_name, "card", 4) || !strchr(e->d_name, '-'))
					continue;
				snprintf(p, sizeof p, "/sys/class/drm/%s/status", e->d_name);
				if (slurp(p, v, sizeof v) || strcmp(v, "connected"))
					continue;
				snprintf(p, sizeof p, "/sys/class/drm/%s/dpms", e->d_name);
				if (!slurp(p, v, sizeof v))
					on = !strcmp(v, "On");
			}
			closedir(d);
		}
		if (on < 0)
			jnull("display_on");
		else
			jbool("display_on", on);
		d = opendir("/sys/class/backlight");
		if (d) {
			while ((e = readdir(d))) {
				if (e->d_name[0] == '.')
					continue;
				snprintf(p, sizeof p, "/sys/class/backlight/%s/brightness", e->d_name);
				jfile("backlight", p);
				break;
			}
			closedir(d);
		}
	}
	JEND();
	putchar('\n');
	say("state: cpu busy %.0f %% over %.0f s, %d browser processes", busy, window, proc_named("chrom"));
}

/* ------------------------------------------------------------------ */
/* CPU kernels                                                        */
/* ------------------------------------------------------------------ */

static const uint32_t K256[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_block(uint32_t st[8], const uint8_t *p)
{
	uint32_t w[64], a, b, c, d, e, f, g, h;
	for (int i = 0; i < 16; i++)
		w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 | (uint32_t)p[4 * i + 2] << 8 | p[4 * i + 3];
	for (int i = 16; i < 64; i++) {
		uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
		uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
		w[i] = w[i - 16] + s0 + w[i - 7] + s1;
	}
	a = st[0]; b = st[1]; c = st[2]; d = st[3]; e = st[4]; f = st[5]; g = st[6]; h = st[7];
	for (int i = 0; i < 64; i++) {
		uint32_t S1 = ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25);
		uint32_t ch = (e & f) ^ (~e & g);
		uint32_t t1 = h + S1 + ch + K256[i] + w[i];
		uint32_t S0 = ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22);
		uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
		uint32_t t2 = S0 + mj;
		h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
	}
	st[0] += a; st[1] += b; st[2] += c; st[3] += d; st[4] += e; st[5] += f; st[6] += g; st[7] += h;
}

static uint32_t crc_tab[256];

static void crc_init(void)
{
	for (uint32_t i = 0; i < 256; i++) {
		uint32_t c = i;
		for (int k = 0; k < 8; k++)
			c = c & 1 ? 0xedb88320u ^ (c >> 1) : c >> 1;
		crc_tab[i] = c;
	}
}

static uint32_t crc32_buf(uint32_t c, const uint8_t *p, size_t n)
{
	c = ~c;
	while (n--)
		c = crc_tab[(c ^ *p++) & 0xff] ^ (c >> 8);
	return ~c;
}

struct body {
	double x, y, z, vx, vy, vz, m;
};

static double nbody_steps(int steps)
{
	/* five bodies, the classic setup of the n-body game */
	static const struct body init[5] = {
		{0, 0, 0, 0, 0, 0, 39.47841760435743},
		{4.84143144246472090, -1.16032004402742839, -0.103622044471123109, 0.606326392995832, 2.81198684491626, -0.02521836165988763, 0.03769367487038949},
		{8.34336671824457987, 4.12479856412430479, -0.403523417114321381, -1.0107743461787924, 1.8256623712304119, 0.008415761376584154, 0.011286326131968767},
		{12.894369562139131, -15.111151401698631, -0.22330757889265573, 1.0827910064415354, 0.8687130181696082, -0.010832637401363636, 0.0017237240570597112},
		{15.379697114850917, -25.919314609987964, 0.17925877295037118, 0.979090732243898, 0.5946989986476762, -0.034755955504078104, 0.0020336868699246304}};
	struct body b[5];
	memcpy(b, init, sizeof b);
	const double dt = 0.01;
	for (int s = 0; s < steps; s++) {
		for (int i = 0; i < 5; i++)
			for (int j = i + 1; j < 5; j++) {
				double dx = b[i].x - b[j].x, dy = b[i].y - b[j].y, dz = b[i].z - b[j].z;
				double d2 = dx * dx + dy * dy + dz * dz;
				double mag = dt / (d2 * sqrt(d2));
				b[i].vx -= dx * b[j].m * mag;
				b[i].vy -= dy * b[j].m * mag;
				b[i].vz -= dz * b[j].m * mag;
				b[j].vx += dx * b[i].m * mag;
				b[j].vy += dy * b[i].m * mag;
				b[j].vz += dz * b[i].m * mag;
			}
		for (int i = 0; i < 5; i++) {
			b[i].x += dt * b[i].vx;
			b[i].y += dt * b[i].vy;
			b[i].z += dt * b[i].vz;
		}
	}
	return b[0].x + b[1].y + b[2].z;
}

#define MM 128

struct kctx {
	uint8_t *buf; /* 64 KiB of data */
	float *A, *B, *C;
	uint32_t sink;
	double dsink;
};

static void kctx_init(struct kctx *k)
{
	k->buf = malloc(65536);
	k->A = malloc(sizeof(float) * MM * MM);
	k->B = malloc(sizeof(float) * MM * MM);
	k->C = malloc(sizeof(float) * MM * MM);
	if (!k->buf || !k->A || !k->B || !k->C)
		die("out of memory");
	uint64_t s = 88172645463325252ull;
	for (int i = 0; i < 65536; i++)
		k->buf[i] = (uint8_t)rng_next(&s);
	for (int i = 0; i < MM * MM; i++) {
		k->A[i] = (float)(rng_next(&s) & 1023) / 1024.0f;
		k->B[i] = (float)(rng_next(&s) & 1023) / 1024.0f;
	}
	k->sink = 0;
	k->dsink = 0;
}

static void kctx_free(struct kctx *k)
{
	free(k->buf);
	free(k->A);
	free(k->B);
	free(k->C);
}

/* Each chunk below is the same amount of work on every machine. */
static void chunk_sha256(struct kctx *k)
{
	uint32_t st[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
	for (int pass = 0; pass < 8; pass++) /* 8 x 64 KiB = 0.5 MiB */
		for (int o = 0; o < 65536; o += 64)
			sha256_block(st, k->buf + o);
	k->sink += st[0] ^ st[7];
}

static void chunk_crc32(struct kctx *k)
{
	uint32_t c = 0;
	for (int pass = 0; pass < 64; pass++) /* 64 x 64 KiB = 4 MiB */
		c = crc32_buf(c, k->buf, 65536);
	k->sink += c;
}

static void chunk_nbody(struct kctx *k)
{
	k->dsink += nbody_steps(50000);
}

static void chunk_matmul(struct kctx *k)
{
	memset(k->C, 0, sizeof(float) * MM * MM);
	for (int i = 0; i < MM; i++)
		for (int kk = 0; kk < MM; kk++) {
			float a = k->A[i * MM + kk];
			for (int j = 0; j < MM; j++)
				k->C[i * MM + j] += a * k->B[kk * MM + j];
		}
	k->dsink += k->C[MM * MM / 2];
}

struct kernel {
	const char *name;
	const char *unit;
	const char *kind; /* int or float */
	void (*chunk)(struct kctx *);
	double units; /* work units per chunk */
	int chunks;   /* chunks of one single-thread run at scale 1 */
};

static const struct kernel kernels[] = {
	{"sha256", "MiB/s", "int", chunk_sha256, 0.5, 120},
	{"crc32", "MiB/s", "int", chunk_crc32, 4.0, 60},
	{"nbody", "Ksteps/s", "float", chunk_nbody, 50.0, 50},
	{"matmul", "MFLOPS", "float", chunk_matmul, 2.0 * MM * MM * MM / 1e6, 120},
};

struct kjob {
	const struct kernel *k;
	atomic_int next;
	int total;
};

static void *kthread(void *arg)
{
	struct kjob *j = arg;
	struct kctx c;
	kctx_init(&c);
	j->k->chunk(&c); /* warm up: pages, caches, first frequency step */
	for (;;) {
		int i = atomic_fetch_add(&j->next, 1);
		if (i >= j->total)
			break;
		j->k->chunk(&c);
	}
	kctx_free(&c);
	return NULL;
}

/* Run TOTAL chunks on NT threads. The time includes the start of the threads
 * and one warm-up chunk per thread, so the work stays large against that. */
static double run_kernel(const struct kernel *k, int nt, int total)
{
	pthread_t th[MAXCPU];
	struct kjob job = {.k = k, .total = total};
	atomic_init(&job.next, 0);
	double t0 = now_s();
	for (int i = 0; i < nt; i++)
		pthread_create(&th[i], NULL, kthread, &job);
	for (int i = 0; i < nt; i++)
		pthread_join(th[i], NULL);
	return now_s() - t0;
}

/* ------------------------------------------------------------------ */
/* cpu                                                                */
/* ------------------------------------------------------------------ */

static void cmd_cpu(double scale, int quick)
{
	int reps = quick ? 1 : 2;
	crc_init();
	JOBJ(NULL);
	jnum("scale", scale);
	jint("repeats", reps);
	jint("threads", ncpu_online);
	JOBJ("tests");
	for (size_t ki = 0; ki < sizeof kernels / sizeof kernels[0]; ki++) {
		const struct kernel *k = &kernels[ki];
		int n = (int)(k->chunks * scale + 0.5);
		if (n < 1)
			n = 1;
		JOBJ(k->name);
		jstr("unit", k->unit);
		jstr("kind", k->kind);
		jint("chunks", n);
		JARR("single");
		double best_single = 0;
		for (int j = 0; j < ncl; j++) {
			double best = 1e30;
			pin_to(cl[j].cpu[0]);
			for (int r = 0; r < reps; r++) {
				double t = run_kernel(k, 1, n);
				if (t < best)
					best = t;
			}
			double rate = n * k->units / best;
			if (rate > best_single)
				best_single = rate;
			JOBJ(NULL);
			jint("cluster", j);
			jnum("seconds", best);
			jnum("rate", rate);
			JEND();
			say("cpu %-7s single c%d (cpu%d): %9.1f %s (%.2f s)", k->name, j, cl[j].cpu[0], rate, k->unit, best);
		}
		JAEND();
		unpin();
		double best = 1e30;
		for (int r = 0; r < reps; r++) {
			double t = run_kernel(k, ncpu_online, n * ncpu_online);
			if (t < best)
				best = t;
		}
		double mrate = n * ncpu_online * k->units / best;
		jnum("best_single", best_single);
		JOBJ("multi");
		jint("threads", ncpu_online);
		jnum("seconds", best);
		jnum("rate", mrate);
		JEND();
		jnum("scaling", mrate / best_single);
		JEND();
		say("cpu %-7s all %d threads:        %9.1f %s (%.2f s, x%.2f)", k->name, ncpu_online, mrate, k->unit, best,
		    mrate / best_single);
	}
	JEND();
	JEND();
	putchar('\n');
}

/* ------------------------------------------------------------------ */
/* memory                                                             */
/* ------------------------------------------------------------------ */

#define MEMLEN (32u << 20) /* bytes per array */

struct mjob {
	int nt;
	pthread_barrier_t bar;
	uint64_t *a, *b, *c;
	int reps;
	int test;
	double best;
	uint64_t sink;
};

static uint64_t m_read(const uint64_t *p, size_t n)
{
	uint64_t s0 = 0, s1 = 0, s2 = 0, s3 = 0;
	for (size_t i = 0; i + 4 <= n; i += 4) {
		s0 += p[i];
		s1 += p[i + 1];
		s2 += p[i + 2];
		s3 += p[i + 3];
	}
	return s0 + s1 + s2 + s3;
}

static void m_write(uint64_t *p, size_t n)
{
	for (size_t i = 0; i + 4 <= n; i += 4) {
		p[i] = i;
		p[i + 1] = i;
		p[i + 2] = i;
		p[i + 3] = i;
	}
}

static void m_copy(uint64_t *d, const uint64_t *s, size_t n)
{
	for (size_t i = 0; i + 4 <= n; i += 4) {
		d[i] = s[i];
		d[i + 1] = s[i + 1];
		d[i + 2] = s[i + 2];
		d[i + 3] = s[i + 3];
	}
}

static void m_triad(uint64_t *a, const uint64_t *b, const uint64_t *c, size_t n)
{
	double *da = (double *)a;
	const double *db = (const double *)b, *dc = (const double *)c;
	for (size_t i = 0; i < n; i++)
		da[i] = db[i] + 3.0 * dc[i];
}

struct marg {
	struct mjob *j;
	int id;
	double t0, t1; /* start and end of the work of this thread in the last pass */
};

static struct marg *mem_args;

static void *mthread2(void *p)
{
	struct marg *ma = p;
	struct mjob *j = ma->j;
	size_t n = MEMLEN / 8 / j->nt;
	size_t off = n * ma->id;
	uint64_t *a = j->a + off, *b = j->b + off, *c = j->c + off;
	for (int r = 0; r < j->reps; r++) {
		pthread_barrier_wait(&j->bar);
		ma->t0 = now_s();
		switch (j->test) {
		case 0: j->sink += m_read(b, n); break;
		case 1: m_write(a, n); break;
		case 2: m_copy(a, b, n); break;
		case 3: m_triad(a, b, c, n); break;
		}
		ma->t1 = now_s();
		pthread_barrier_wait(&j->bar);
		if (ma->id == 0) {
			/* the pass lasts from the first start to the last end: the threads
			 * leave the barrier one after the other */
			double lo = mem_args[0].t0, hi = mem_args[0].t1;
			for (int i = 1; i < j->nt; i++) {
				if (mem_args[i].t0 < lo)
					lo = mem_args[i].t0;
				if (mem_args[i].t1 > hi)
					hi = mem_args[i].t1;
			}
			if (r == 0 || hi - lo < j->best)
				j->best = hi - lo;
		}
	}
	return NULL;
}

/* Best time of REPS passes. NT threads work on separate slices. */
static double mem_pass(struct mjob *j, int nt, int test, int reps)
{
	pthread_t th[MAXCPU];
	struct marg ma[MAXCPU];
	j->nt = nt;
	j->test = test;
	j->reps = reps;
	j->best = 0;
	mem_args = ma;
	pthread_barrier_init(&j->bar, NULL, nt);
	for (int i = 0; i < nt; i++) {
		ma[i].j = j;
		ma[i].id = i;
		pthread_create(&th[i], NULL, mthread2, &ma[i]);
	}
	for (int i = 0; i < nt; i++)
		pthread_join(th[i], NULL);
	pthread_barrier_destroy(&j->bar);
	return j->best;
}

static const char *mem_names[] = {"read", "write", "copy", "triad"};
static const double mem_bytes[] = {1, 1, 2, 3}; /* times the array size */

static void *chase_buf;

/* Nanoseconds per dependent load in a random cycle through BYTES. The loop
 * runs for at least MIN_S seconds, so a CPU that raises its clock slowly
 * (schedutil) is at full speed for most of the time. */
static double chase(size_t bytes, long loads, double min_s)
{
	size_t n = bytes / 64;
	struct node {
		struct node *next;
		char pad[64 - sizeof(void *)];
	} *nodes = chase_buf;
	size_t *perm = malloc(n * sizeof *perm);
	if (!perm)
		die("out of memory");
	for (size_t i = 0; i < n; i++)
		perm[i] = i;
	uint64_t s = 0x9e3779b97f4a7c15ull ^ bytes;
	for (size_t i = n - 1; i > 0; i--) { /* Sattolo: one cycle through all nodes */
		size_t k = rng_next(&s) % i;
		size_t t = perm[i];
		perm[i] = perm[k];
		perm[k] = t;
	}
	for (size_t i = 0; i < n; i++)
		nodes[perm[i]].next = &nodes[perm[(i + 1) % n]];
	struct node *p = &nodes[perm[0]];
	free(perm);
	for (long i = 0; i < (long)n * 2 && i < loads; i++) /* warm up */
		p = p->next;
	double best = 1e30;
	for (int round = 0; round < 3; round++) {
		long total = 0;
		double t0 = now_s(), t;
		do {
			for (long i = 0; i < loads; i++)
				p = p->next;
			total += loads;
			t = now_s() - t0;
		} while (t < min_s);
		if (t / total * 1e9 < best)
			best = t / total * 1e9;
	}
	if (p == NULL)
		puts("x");
	return best;
}

/* Keep the CPU busy for S seconds so that the clock is up. */
static void spin_up(double s)
{
	double t0 = now_s();
	volatile uint64_t x = 1;
	while (now_s() - t0 < s)
		for (int i = 0; i < 20000; i++)
			x = x * 6364136223846793005ull + 1442695040888963407ull;
}

static void cmd_mem(int quick)
{
	size_t total = (size_t)MEMLEN * 3;
	uint64_t *base = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (base == MAP_FAILED)
		die("mmap failed");
	memset(base, 1, total);
	struct mjob j;
	memset(&j, 0, sizeof j);
	j.a = base;
	j.b = base + MEMLEN / 8;
	j.c = base + 2 * (MEMLEN / 8);
	int reps = quick ? 3 : 6;
	JOBJ(NULL);
	jint("array_mib", MEMLEN >> 20);
	JARR("single");
	double best_single[4] = {0};
	for (int c = 0; c < ncl; c++) {
		pin_to(cl[c].cpu[0]);
		spin_up(0.3);
		JOBJ(NULL);
		jint("cluster", c);
		for (int t = 0; t < 4; t++) {
			double sec = mem_pass(&j, 1, t, reps);
			double mbs = mem_bytes[t] * MEMLEN / sec / 1e6;
			jnum(mem_names[t], mbs);
			if (mbs > best_single[t])
				best_single[t] = mbs;
			say("mem %-5s single c%d: %8.0f MB/s", mem_names[t], c, mbs);
		}
		JEND();
	}
	JAEND();
	unpin();
	JOBJ("best_single");
	for (int t = 0; t < 4; t++)
		jnum(mem_names[t], best_single[t]);
	JEND();
	JOBJ("multi");
	jint("threads", ncpu_online);
	for (int t = 0; t < 4; t++) {
		double sec = mem_pass(&j, ncpu_online, t, reps);
		double mbs = mem_bytes[t] * MEMLEN / sec / 1e6;
		jnum(mem_names[t], mbs);
		say("mem %-5s all %d threads: %8.0f MB/s", mem_names[t], ncpu_online, mbs);
	}
	JEND();
	/* latency: pointer chase, one cache line per node, biggest cluster */
	chase_buf = base;
	pin_to(cl[0].cpu[0]);
	spin_up(0.3);
	static const unsigned kib[] = {16, 64, 256, 1024, 4096, 16384, 65536};
	size_t nk = sizeof kib / sizeof kib[0];
	if (65536u * 1024 > total)
		nk--;
	long loads = quick ? 500000 : 1000000;
	JARR("latency");
	double dram = 0;
	for (size_t i = 0; i < nk; i++) {
		double ns = chase((size_t)kib[i] * 1024, loads, quick ? 0.02 : 0.06);
		JOBJ(NULL);
		jint("kib", kib[i]);
		jnum("ns", ns);
		JEND();
		dram = ns;
		say("mem latency %6u KiB: %7.1f ns", kib[i], ns);
	}
	JAEND();
	unpin();
	jnum("dram_ns", dram);
	JEND();
	putchar('\n');
	munmap(base, total);
}

/* ------------------------------------------------------------------ */
/* sustained                                                          */
/* ------------------------------------------------------------------ */

static atomic_ullong *s_count;
static volatile int s_run;

struct sarg {
	int id;
};

static void *sthread(void *p)
{
	struct sarg *sa = p;
	struct kctx c;
	kctx_init(&c);
	while (s_run) {
		chunk_crc32(&c);
		c.dsink += nbody_steps(2000);
		atomic_fetch_add_explicit(&s_count[sa->id], 1, memory_order_relaxed);
	}
	kctx_free(&c);
	return NULL;
}

#define MAXSAMP 1800

static void cmd_sustained(int seconds, long trip_mC)
{
	crc_init();
	if (seconds > MAXSAMP)
		seconds = MAXSAMP;
	s_count = calloc(ncpu_online, sizeof *s_count);
	pthread_t th[MAXCPU];
	struct sarg sa[MAXCPU];
	static double rate[MAXSAMP];
	static long khz[MAXSAMP][MAXCL];
	static long temp[MAXSAMP][MAXZONE];
	static long tmax[MAXSAMP];
	int ns = 0, aborted = 0;
	long temp_start = max_temp();
	/* A zone that is already above the trip point before the load starts is
	 * a broken sensor. It does not stop the run. */
	int zone_ignored[MAXZONE] = {0};
	for (int k = 0; k < nzone; k++)
		if (zone_temp(k) >= trip_mC - 5000)
			zone_ignored[k] = 1;
	say("sustained: %d s on %d threads, start temp %.1f C", seconds, ncpu_online, temp_start / 1000.0);
	s_run = 1;
	for (int i = 0; i < ncpu_online; i++) {
		sa[i].id = i;
		pthread_create(&th[i], NULL, sthread, &sa[i]);
	}
	unsigned long long last = 0;
	double t0 = now_s(), tlast = t0;
	for (int s = 1; s <= seconds && !g_stop; s++) {
		double due = t0 + s;
		while (now_s() < due && !g_stop) {
			struct timespec ts = {0, 20000000};
			nanosleep(&ts, NULL);
		}
		double tn = now_s();
		unsigned long long sum = 0;
		for (int i = 0; i < ncpu_online; i++)
			sum += atomic_load_explicit(&s_count[i], memory_order_relaxed);
		rate[ns] = (double)(sum - last) / (tn - tlast);
		last = sum;
		tlast = tn;
		for (int j = 0; j < ncl; j++)
			khz[ns][j] = cur_khz(j);
		tmax[ns] = -1000000;
		long tguard = -1000000;
		for (int k = 0; k < nzone; k++) {
			temp[ns][k] = zone_temp(k);
			if (temp[ns][k] > tmax[ns])
				tmax[ns] = temp[ns][k];
			if (!zone_ignored[k] && temp[ns][k] > tguard)
				tguard = temp[ns][k];
		}
		if (s % 10 == 0 || s == 1)
			say("  t=%3d s  %7.0f chunks/s  %.1f C  %ld MHz", s, rate[ns], tmax[ns] / 1000.0, khz[ns][0] / 1000);
		ns++;
		if (tguard >= trip_mC) {
			aborted = 1;
			say("  thermal trip at %.1f C: load stopped", tguard / 1000.0);
			break;
		}
	}
	s_run = 0;
	for (int i = 0; i < ncpu_online; i++)
		pthread_join(th[i], NULL);
	free((void *)s_count);

	/* summary: first and last 10 samples */
	int w = ns < 10 ? ns : 10;
	double f10 = 0, l10 = 0;
	for (int i = 0; i < w; i++) {
		f10 += rate[i];
		l10 += rate[ns - 1 - i];
	}
	if (w) {
		f10 /= w;
		l10 /= w;
	}
	long tm = temp_start;
	for (int i = 0; i < ns; i++)
		if (tmax[i] > tm)
			tm = tmax[i];
	JOBJ(NULL);
	jint("seconds", ns);
	jint("threads", ncpu_online);
	jint("interval_s", 1);
	jbool("aborted_thermal", aborted);
	jint("trip_mC", trip_mC);
	jzones("temp_zones");
	JOBJ("summary");
	jnum("rate_first10", f10);
	jnum("rate_last10", l10);
	jnum("ratio_last_first", f10 > 0 ? l10 / f10 : 0);
	jint("temp_start_mC", temp_start);
	jint("temp_max_mC", tm);
	jint("temp_end_mC", ns ? tmax[ns - 1] : temp_start);
	JARR("khz_first");
	for (int j = 0; j < ncl; j++)
		jint(NULL, ns ? khz[0][j] : -1);
	JAEND();
	JARR("khz_min");
	for (int j = 0; j < ncl; j++) {
		long m = LONG_MAX;
		for (int i = 0; i < ns; i++)
			if (khz[i][j] >= 0 && khz[i][j] < m)
				m = khz[i][j];
		jint(NULL, m == LONG_MAX ? -1 : m);
	}
	JAEND();
	JARR("khz_max");
	for (int j = 0; j < ncl; j++) {
		long m = -1;
		for (int i = 0; i < ns; i++)
			if (khz[i][j] > m)
				m = khz[i][j];
		jint(NULL, m);
	}
	JAEND();
	JARR("khz_last");
	for (int j = 0; j < ncl; j++)
		jint(NULL, ns ? khz[ns - 1][j] : -1);
	JAEND();
	JEND();
	JARR("samples");
	for (int i = 0; i < ns; i++) {
		JOBJ(NULL);
		jint("t", i + 1);
		jnum("rate", rate[i]);
		JARR("khz");
		for (int j = 0; j < ncl; j++)
			jint(NULL, khz[i][j]);
		JAEND();
		JARR("temp_mC");
		for (int k = 0; k < nzone; k++) {
			if (temp[i][k] == -1000000)
				jnull(NULL);
			else
				jint(NULL, temp[i][k]);
		}
		JAEND();
		JEND();
	}
	JAEND();
	JEND();
	putchar('\n');
	say("sustained: first10 %.0f, last10 %.0f chunks/s (x%.2f), max %.1f C", f10, l10, f10 > 0 ? l10 / f10 : 0,
	    tm / 1000.0);
}

/* ------------------------------------------------------------------ */
/* storage (read only)                                                */
/* ------------------------------------------------------------------ */

/* The source of the root file system from mountinfo, or "" */
static void find_root_source(char *out, size_t n)
{
	FILE *f = fopen("/proc/self/mountinfo", "r");
	char line[1024];
	out[0] = 0;
	if (!f)
		return;
	while (fgets(line, sizeof line, f)) {
		char *dash = strstr(line, " - ");
		if (!dash)
			continue;
		char mnt[256];
		if (sscanf(line, "%*s %*s %*s %*s %255s", mnt) != 1 || strcmp(mnt, "/"))
			continue;
		char fst[64], src[256];
		if (sscanf(dash + 3, "%63s %255s", fst, src) == 2)
			snprintf(out, n, "%s", src);
	}
	fclose(f);
}

static int is_blk(const char *p)
{
	struct stat st;
	return stat(p, &st) == 0 && S_ISBLK(st.st_mode);
}

/* "root=" of the kernel command line when the mount source is /dev/root */
static void cmdline_root(char *out, size_t n)
{
	char b[2048];
	out[0] = 0;
	if (slurp("/proc/cmdline", b, sizeof b))
		return;
	char *p = strstr(b, "root=");
	if (!p)
		return;
	p += 5;
	size_t l = strcspn(p, " ");
	if (l >= n)
		l = n - 1;
	memcpy(out, p, l);
	out[l] = 0;
}

static void storage_meta(const char *dev)
{
	/* the disk of a partition and the card facts, with no serial number */
	char link[256], p[300], b[256];
	const char *name = strrchr(dev, '/');
	name = name ? name + 1 : dev;
	char disk[256];
	snprintf(disk, sizeof disk, "%s", name);
	snprintf(p, sizeof p, "/sys/class/block/%s", name);
	ssize_t r = readlink(p, link, sizeof link - 1);
	if (r > 0) {
		link[r] = 0;
		snprintf(p, sizeof p, "/sys/class/block/%s/partition", name);
		if (access(p, F_OK) == 0) {
			char *last = strrchr(link, '/');
			if (last) {
				*last = 0;
				char *prev = strrchr(link, '/');
				snprintf(disk, sizeof disk, "%s", prev ? prev + 1 : link);
			}
		}
	}
	jstr("disk", disk);
	const char *attrs[] = {"type", "name", "manfid", "oemid", "fwrev", "hwrev", "date", "rev", "preferred_erase_size"};
	for (size_t i = 0; i < sizeof attrs / sizeof attrs[0]; i++) {
		snprintf(p, sizeof p, "/sys/block/%s/device/%s", disk, attrs[i]);
		jfile(attrs[i], p);
	}
	snprintf(p, sizeof p, "/sys/block/%s/queue/rotational", disk);
	jfile("rotational", p);
	if (!strncmp(disk, "mmcblk", 6)) {
		snprintf(p, sizeof p, "/sys/kernel/debug/mmc%s/ios", disk + 6);
		char ios[512];
		if (!slurp(p, ios, sizeof ios)) {
			jstr("ios", ios);
		}
	}
	(void)b;
}

static int drop_caches(void)
{
	int fd = open("/proc/sys/vm/drop_caches", O_WRONLY);
	if (fd < 0)
		return 0;
	int ok = write(fd, "3\n", 2) == 2;
	close(fd);
	return ok;
}

static void cmd_storage(const char *dev, const char *file, int quick)
{
	char src[256] = "", path[256] = "";
	const char *target = dev ? dev : file;
	int is_dev = dev != NULL;
	if (!target) {
		find_root_source(src, sizeof src);
		if (!is_blk(src)) {
			char r[128];
			cmdline_root(r, sizeof r);
			if (r[0] == '/')
				snprintf(src, sizeof src, "%s", r);
		}
		if (is_blk(src)) {
			target = src;
			is_dev = 1;
		} else {
			static const char *cand[] = {"/usr/lib/chromium/chromium", "/usr/lib/chromium/chrome", "/usr/bin/busybox",
						     "/bin/busybox"};
			for (size_t i = 0; i < sizeof cand / sizeof cand[0]; i++) {
				struct stat st;
				if (stat(cand[i], &st) == 0 && st.st_size >= (8 << 20)) {
					target = cand[i];
					break;
				}
			}
		}
	}
	if (!target)
		die("no block device and no big file to read");
	snprintf(path, sizeof path, "%s", target);

	int dropped = drop_caches();
	int fd = open(path, O_RDONLY);
	if (fd < 0)
		die("cannot open %s: %s", path, strerror(errno));
	int dfd = open(path, O_RDONLY | O_DIRECT); /* no page cache; -1 when the file system refuses */
	uint64_t size = 0;
	struct stat st;
	fstat(fd, &st);
	if (S_ISBLK(st.st_mode)) {
		if (ioctl(fd, BLKGETSIZE64, &size) != 0)
			size = lseek(fd, 0, SEEK_END);
	} else {
		size = st.st_size;
	}
	if (size < (8u << 20))
		die("%s is too small (%llu bytes)", path, (unsigned long long)size);
	posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);

	const size_t blk = 1 << 20;
	void *buf;
	if (posix_memalign(&buf, 4096, blk))
		die("out of memory");

	/* 1. sequential, through the page cache (readahead works, the cache was dropped).
	 *    This is the speed that programs see. */
	uint64_t seq_total = (uint64_t)(quick ? 64 : 192) << 20;
	if (seq_total > size / 4)
		seq_total = (size / 4) & ~(uint64_t)(blk - 1);
	uint64_t off = (size / 2) & ~(uint64_t)(blk - 1);
	if (off + seq_total > size)
		off = (size - seq_total) & ~(uint64_t)(blk - 1);
	double t0 = now_s();
	uint64_t done = 0;
	while (done < seq_total && now_s() - t0 < 15) {
		ssize_t r = pread(fd, buf, blk, off + done);
		if (r <= 0)
			break;
		done += r;
	}
	double tseq = now_s() - t0;
	say("storage seq read (cached path) %s: %.1f MB/s (%llu MiB in %.2f s)", path, done / tseq / 1e6,
	    (unsigned long long)(done >> 20), tseq);
	posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);

	/* 2. sequential with O_DIRECT: one request of 1 MiB at a time, no readahead */
	uint64_t ddone = 0;
	double tdir = 0;
	if (dfd >= 0) {
		uint64_t dtotal = (uint64_t)(quick ? 16 : 48) << 20;
		if (dtotal > size / 8)
			dtotal = (size / 8) & ~(uint64_t)(blk - 1);
		uint64_t doff = (size / 4) & ~(uint64_t)(blk - 1);
		t0 = now_s();
		while (ddone < dtotal && now_s() - t0 < 10) {
			ssize_t r = pread(dfd, buf, blk, doff + ddone);
			if (r <= 0)
				break;
			ddone += r;
		}
		tdir = now_s() - t0;
		say("storage seq read (O_DIRECT, 1 MiB requests): %.1f MB/s (%llu MiB in %.2f s)", ddone / tdir / 1e6,
		    (unsigned long long)(ddone >> 20), tdir);
	}

	/* 3. random 4 KiB, queue depth 1, over the whole size, through O_DIRECT */
	int rfd = dfd >= 0 ? dfd : fd;
	int maxops = quick ? 4000 : 20000;
	double maxt = quick ? 2.5 : 6.0;
	double *lat = malloc(sizeof(double) * maxops);
	uint64_t s = 0x1234567887654321ull;
	int ops = 0;
	if (dfd < 0)
		posix_fadvise(fd, 0, 0, POSIX_FADV_RANDOM);
	t0 = now_s();
	while (ops < maxops && now_s() - t0 < maxt) {
		uint64_t o = (rng_next(&s) % (size / 4096)) * 4096;
		double a = now_s();
		ssize_t r = pread(rfd, buf, 4096, o);
		double b = now_s();
		if (r <= 0)
			break;
		lat[ops++] = (b - a) * 1000.0;
	}
	double trand = now_s() - t0;
	qsort(lat, ops, sizeof *lat, cmp_dbl);
	double avg = 0;
	for (int i = 0; i < ops; i++)
		avg += lat[i];
	if (ops)
		avg /= ops;
	say("storage rand 4K read: %.0f IOPS, avg %.3f ms, p99 %.3f ms", ops / trand, avg,
	    ops ? lat[(int)(ops * 0.99)] : 0.0);

	JOBJ(NULL);
	jstr("target", path);
	jbool("block_device", is_dev && is_blk(path));
	jbool("o_direct_ok", dfd >= 0);
	jbool("caches_dropped", dropped);
	jint("size_bytes", (long long)size);
	if (is_blk(path))
		storage_meta(path);
	JOBJ("seq_read");
	jint("block_kib", blk >> 10);
	jint("mib", done >> 20);
	jnum("seconds", tseq);
	jnum("mbps", done / tseq / 1e6);
	JEND();
	if (dfd >= 0) {
		JOBJ("seq_read_direct");
		jint("block_kib", blk >> 10);
		jint("mib", ddone >> 20);
		jnum("seconds", tdir);
		jnum("mbps", ddone / tdir / 1e6);
		JEND();
	}
	JOBJ("rand_read_4k");
	jint("ops", ops);
	jnum("seconds", trand);
	jnum("iops", ops / trand);
	jnum("avg_ms", avg);
	jnum("p50_ms", ops ? lat[ops / 2] : 0);
	jnum("p99_ms", ops ? lat[(int)(ops * 0.99)] : 0);
	JEND();
	JEND();
	putchar('\n');
	free(lat);
	free(buf);
	close(fd);
	if (dfd >= 0)
		close(dfd);
}

/* ------------------------------------------------------------------ */
/* net                                                                */
/* ------------------------------------------------------------------ */

/* HOST is an IPv4 address (a name needs the resolver, which a static program
 * does not have). */
static int tcp_connect(const char *host, int port)
{
	struct sockaddr_in sa;
	memset(&sa, 0, sizeof sa);
	sa.sin_family = AF_INET;
	sa.sin_port = htons(port);
	if (inet_pton(AF_INET, host, &sa.sin_addr) != 1)
		return -1;
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	struct timeval tv = {5, 0};
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
	if (connect(fd, (struct sockaddr *)&sa, sizeof sa) != 0) {
		close(fd);
		return -1;
	}
	return fd;
}

static void cmd_net(const char *host, int port, int secs)
{
	static char buf[65536];
	memset(buf, 'x', sizeof buf);
	JOBJ(NULL);
	jstr("peer_kind", "tsx-bench-core netserver");
	jint("seconds", secs);
	/* upload */
	int fd = tcp_connect(host, port);
	if (fd < 0) {
		jstr("error", "cannot connect");
		JEND();
		putchar('\n');
		return;
	}
	char cmd[2] = {'U', (char)secs};
	if (write(fd, cmd, 2) != 2) {
	}
	double t0 = now_s();
	unsigned long long sent = 0;
	while (now_s() - t0 < secs) {
		ssize_t r = write(fd, buf, sizeof buf);
		if (r <= 0)
			break;
		sent += r;
	}
	shutdown(fd, SHUT_WR);
	char ack[32];
	while (read(fd, ack, sizeof ack) > 0) {
	}
	double tu = now_s() - t0;
	close(fd);
	jnum("upload_mbit", sent * 8.0 / tu / 1e6);
	say("net upload:   %.1f Mbit/s", sent * 8.0 / tu / 1e6);
	/* download */
	fd = tcp_connect(host, port);
	if (fd < 0) {
		jstr("error", "cannot connect for download");
		JEND();
		putchar('\n');
		return;
	}
	cmd[0] = 'D';
	if (write(fd, cmd, 2) != 2) {
	}
	unsigned long long got = 0;
	t0 = 0;
	for (;;) {
		ssize_t r = read(fd, buf, sizeof buf);
		if (r <= 0)
			break;
		if (!t0)
			t0 = now_s();
		got += r;
	}
	double td = t0 ? now_s() - t0 : 1;
	close(fd);
	jnum("download_mbit", got * 8.0 / td / 1e6);
	say("net download: %.1f Mbit/s", got * 8.0 / td / 1e6);
	JEND();
	putchar('\n');
}

static void cmd_netserver(int port, int idle)
{
	int ls = socket(AF_INET, SOCK_STREAM, 0), one = 1;
	struct sockaddr_in sa;
	memset(&sa, 0, sizeof sa);
	setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	sa.sin_family = AF_INET;
	sa.sin_port = htons(port);
	sa.sin_addr.s_addr = htonl(INADDR_ANY);
	if (bind(ls, (struct sockaddr *)&sa, sizeof sa) || listen(ls, 8))
		die("cannot listen on port %d: %s", port, strerror(errno));
	signal(SIGCHLD, SIG_IGN);
	for (;;) {
		struct pollfd pf = {ls, POLLIN, 0};
		if (poll(&pf, 1, idle > 0 ? idle * 1000 : -1) <= 0)
			return;
		int c = accept(ls, NULL, NULL);
		if (c < 0)
			continue;
		if (fork() == 0) {
			static char buf[65536];
			char cmd[2];
			memset(buf, 'y', sizeof buf);
			if (read(c, cmd, 2) == 2) {
				if (cmd[0] == 'U') {
					while (read(c, buf, sizeof buf) > 0) {
					}
					if (write(c, "ok\n", 3) < 0) {
					}
				} else if (cmd[0] == 'D') {
					double t0 = now_s();
					while (now_s() - t0 < cmd[1] && write(c, buf, sizeof buf) > 0) {
					}
				}
			}
			close(c);
			_exit(0);
		}
		close(c);
	}
}

/* ------------------------------------------------------------------ */
/* timeit, gen                                                        */
/* ------------------------------------------------------------------ */

static void cmd_timeit(const char *label, const char *command, int reps)
{
	double best = 1e30;
	int status = 0;
	if (reps < 1)
		reps = 1;
	for (int r = 0; r < reps; r++) {
		double t0 = now_s();
		pid_t pid = fork();
		if (pid == 0) {
			int nul = open("/dev/null", O_WRONLY);
			dup2(nul, 1);
			dup2(nul, 2);
			execl("/bin/sh", "sh", "-c", command, (char *)NULL);
			_exit(127);
		}
		waitpid(pid, &status, 0);
		double t = now_s() - t0;
		if (t < best)
			best = t;
	}
	JOBJ(NULL);
	jstr("label", label);
	jnum("seconds", best);
	jint("repeats", reps);
	jint("status", WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
	JEND();
	putchar('\n');
	say("timeit %s: %.2f s (best of %d)", label, best, reps);
}

static void cmd_gen(const char *file, int mib)
{
	static const char *words[] = {"panel", "kernel", "display", "value", "service", "config", "network", "light",
				      "sensor", "system", "driver", "buffer", "status", "update", "device", "memory",
				      "frame", "touch", "audio", "power", "clock", "cache", "queue", "event",
				      "thread", "socket", "stream", "token", "image", "layout", "render", "kiosk"};
	char dir[256];
	snprintf(dir, sizeof dir, "%s", file);
	char *sl = strrchr(dir, '/');
	if (sl && sl != dir)
		*sl = 0;
	else
		snprintf(dir, sizeof dir, ".");
	struct statfs sf;
	if (statfs(dir, &sf) != 0 || (sf.f_type != 0x01021994 && sf.f_type != 0x858458f6)) {
		if (!getenv("TSX_BENCH_ALLOW_ANY_FS"))
			die("refuse to write %s: the folder is not on tmpfs or ramfs", file);
	}
	FILE *f = fopen(file, "w");
	if (!f)
		die("cannot write %s: %s", file, strerror(errno));
	uint64_t s = 42;
	char *buf = malloc(1 << 20);
	for (int m = 0; m < mib; m++) {
		size_t n = 0;
		while (n < (1 << 20) - 16) {
			uint64_t r = rng_next(&s);
			const char *w = words[r & 31];
			size_t l = strlen(w);
			memcpy(buf + n, w, l);
			n += l;
			buf[n++] = (r >> 8) % 11 == 0 ? '\n' : ' ';
		}
		memset(buf + n, ' ', (1 << 20) - n);
		fwrite(buf, 1, 1 << 20, f);
	}
	free(buf);
	fclose(f);
}

/* ------------------------------------------------------------------ */
/* browser: a small DevTools (CDP) client over a WebSocket            */
/* ------------------------------------------------------------------ */

static int ws_fd = -1;

static ssize_t read_timeout(int fd, void *buf, size_t n, double timeout)
{
	double end = now_s() + timeout;
	for (;;) {
		double left = end - now_s();
		if (left <= 0)
			return 0;
		if (g_stop && timeout > 5)
			return -2;
		struct pollfd pf = {fd, POLLIN, 0};
		int pr = poll(&pf, 1, left > 0.2 ? 200 : (int)(left * 1000) + 1);
		if (pr < 0 && errno != EINTR)
			return -1;
		if (pr > 0) {
			ssize_t r = read(fd, buf, n);
			return r == 0 ? -1 : r;
		}
	}
}

static int read_full(int fd, void *buf, size_t n, double timeout)
{
	size_t got = 0;
	double end = now_s() + timeout;
	while (got < n) {
		double left = end - now_s();
		if (left <= 0)
			return 0;
		ssize_t r = read_timeout(fd, (char *)buf + got, n - got, left);
		if (r == -2)
			return -2;
		if (r < 0)
			return -1;
		got += r;
	}
	return 1;
}

static int http_get(int port, const char *path, char *out, size_t cap)
{
	int fd = tcp_connect("127.0.0.1", port);
	if (fd < 0)
		return -1;
	char req[256];
	int l = snprintf(req, sizeof req, "GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nConnection: close\r\n\r\n", path, port);
	if (write(fd, req, l) != l) {
		close(fd);
		return -1;
	}
	size_t n = 0;
	for (;;) {
		ssize_t r = read_timeout(fd, out + n, cap - 1 - n, 5);
		if (r <= 0)
			break;
		n += r;
		if (n >= cap - 1)
			break;
	}
	out[n] = 0;
	close(fd);
	char *body = strstr(out, "\r\n\r\n");
	if (!body)
		return -1;
	memmove(out, body + 4, strlen(body + 4) + 1);
	return 0;
}

static int ws_send(const char *msg, size_t n)
{
	uint8_t hdr[14];
	size_t h = 0;
	hdr[h++] = 0x81;
	if (n < 126) {
		hdr[h++] = 0x80 | n;
	} else if (n < 65536) {
		hdr[h++] = 0x80 | 126;
		hdr[h++] = n >> 8;
		hdr[h++] = n & 255;
	} else {
		hdr[h++] = 0x80 | 127;
		for (int i = 7; i >= 0; i--)
			hdr[h++] = (uint64_t)n >> (8 * i);
	}
	uint8_t mask[4] = {0x12, 0x34, 0x56, 0x78};
	memcpy(hdr + h, mask, 4);
	h += 4;
	uint8_t *buf = malloc(h + n);
	memcpy(buf, hdr, h);
	for (size_t i = 0; i < n; i++)
		buf[h + i] = msg[i] ^ mask[i & 3];
	size_t off = 0;
	while (off < h + n) {
		ssize_t r = write(ws_fd, buf + off, h + n - off);
		if (r <= 0) {
			free(buf);
			return -1;
		}
		off += r;
	}
	free(buf);
	return 0;
}

/* Returns a malloc'd text message, or NULL on timeout or error. */
static char *ws_recv(double timeout)
{
	char *msg = NULL;
	size_t mlen = 0;
	double end = now_s() + timeout;
	for (;;) {
		uint8_t h[2];
		double left = end - now_s();
		if (left <= 0)
			goto fail;
		int r = read_full(ws_fd, h, 2, left);
		if (r <= 0)
			goto fail;
		int fin = h[0] & 0x80, op = h[0] & 15;
		uint64_t len = h[1] & 127;
		if (len == 126) {
			uint8_t e[2];
			if (read_full(ws_fd, e, 2, 5) <= 0)
				goto fail;
			len = e[0] << 8 | e[1];
		} else if (len == 127) {
			uint8_t e[8];
			if (read_full(ws_fd, e, 8, 5) <= 0)
				goto fail;
			len = 0;
			for (int i = 0; i < 8; i++)
				len = len << 8 | e[i];
		}
		if (len > (64u << 20))
			goto fail;
		char *pl = malloc(len + 1);
		if (len && read_full(ws_fd, pl, len, 30) <= 0) {
			free(pl);
			goto fail;
		}
		pl[len] = 0;
		if (op == 9) { /* ping */
			uint8_t pong[6] = {0x8a, 0x80, 0, 0, 0, 0};
			if (write(ws_fd, pong, 6) < 0) {
			}
			free(pl);
			continue;
		}
		if (op == 8) {
			free(pl);
			goto fail;
		}
		if (op == 1 || op == 0) {
			msg = realloc(msg, mlen + len + 1);
			memcpy(msg + mlen, pl, len + 1);
			mlen += len;
		}
		free(pl);
		if (fin && (op == 1 || op == 0))
			return msg;
	}
fail:
	free(msg);
	return NULL;
}

static void b64(const uint8_t *in, size_t n, char *out)
{
	static const char T[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	size_t o = 0;
	for (size_t i = 0; i < n; i += 3) {
		uint32_t v = in[i] << 16 | (i + 1 < n ? in[i + 1] << 8 : 0) | (i + 2 < n ? in[i + 2] : 0);
		out[o++] = T[v >> 18];
		out[o++] = T[(v >> 12) & 63];
		out[o++] = i + 1 < n ? T[(v >> 6) & 63] : '=';
		out[o++] = i + 2 < n ? T[v & 63] : '=';
	}
	out[o] = 0;
}

static int ws_connect(int port, const char *path)
{
	ws_fd = tcp_connect("127.0.0.1", port);
	if (ws_fd < 0)
		return -1;
	uint8_t keyb[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
	char key[40], req[512], resp[1024];
	b64(keyb, 16, key);
	int l = snprintf(req, sizeof req,
			 "GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
			 "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
			 path, port, key);
	if (write(ws_fd, req, l) != l)
		return -1;
	size_t n = 0;
	while (n < sizeof resp - 1) {
		ssize_t r = read_timeout(ws_fd, resp + n, 1, 5);
		if (r <= 0)
			return -1;
		n++;
		resp[n] = 0;
		if (n >= 4 && !memcmp(resp + n - 4, "\r\n\r\n", 4))
			break;
	}
	return strstr(resp, " 101 ") ? 0 : -1;
}

static int cdp_id;
static int cdp_load_seen;

/* Send one command. Return the malloc'd answer (the line with the id). */
static char *cdp_call(const char *method, const char *params, double timeout)
{
	char *req = malloc(strlen(params) + 128);
	int id = ++cdp_id;
	int l = sprintf(req, "{\"id\":%d,\"method\":\"%s\",\"params\":%s}", id, method, params);
	if (ws_send(req, l)) {
		free(req);
		return NULL;
	}
	free(req);
	double end = now_s() + timeout;
	for (;;) {
		double left = end - now_s();
		if (left <= 0)
			return NULL;
		char *m = ws_recv(left);
		if (!m)
			return NULL;
		if (strstr(m, "Page.loadEventFired"))
			cdp_load_seen = 1;
		/* the answer starts with {"id":N, (a space after the colon is fine) */
		if (!strncmp(m, "{\"id\":", 6)) {
			const char *q = m + 6;
			while (*q == ' ')
				q++;
			if (atoi(q) == id)
				return m;
		}
		free(m);
	}
}

/* Wait for Page.loadEventFired. */
static int cdp_wait_load(double timeout)
{
	double end = now_s() + timeout;
	while (!cdp_load_seen) {
		double left = end - now_s();
		if (left <= 0)
			return 0;
		char *m = ws_recv(left > 1 ? 1 : left);
		if (m) {
			if (strstr(m, "Page.loadEventFired"))
				cdp_load_seen = 1;
			free(m);
		} else if (now_s() >= end) {
			return 0;
		}
	}
	return 1;
}

/* JSON string escape into dst (no quotes). */
static void json_esc(const char *s, char *dst)
{
	for (; *s; s++) {
		if (*s == '"' || *s == '\\') {
			*dst++ = '\\';
			*dst++ = *s;
		} else if ((unsigned char)*s < 0x20) {
			dst += sprintf(dst, "\\u%04x", *s);
		} else {
			*dst++ = *s;
		}
	}
	*dst = 0;
}

/* Value of a JSON string field "key":"..." (first one), unescaped. */
static char *json_str_field(const char *json, const char *key)
{
	char pat[64];
	snprintf(pat, sizeof pat, "\"%s\":", key);
	const char *p = strstr(json, pat);
	if (!p)
		return NULL;
	p += strlen(pat);
	while (*p == ' ')
		p++;
	if (*p != '"')
		return NULL;
	p++;
	char *out = malloc(strlen(p) + 1), *o = out;
	while (*p && *p != '"') {
		if (*p == '\\' && p[1]) {
			p++;
			switch (*p) {
			case 'n': *o++ = '\n'; break;
			case 't': *o++ = '\t'; break;
			case 'r': *o++ = '\r'; break;
			case 'u': {
				unsigned v = 0;
				sscanf(p + 1, "%4x", &v);
				p += 4;
				if (v < 0x80) {
					*o++ = v;
				} else if (v < 0x800) {
					*o++ = 0xc0 | v >> 6;
					*o++ = 0x80 | (v & 63);
				} else {
					*o++ = 0xe0 | v >> 12;
					*o++ = 0x80 | ((v >> 6) & 63);
					*o++ = 0x80 | (v & 63);
				}
				break;
			}
			default: *o++ = *p;
			}
			p++;
		} else {
			*o++ = *p++;
		}
	}
	*o = 0;
	return out;
}

/* The page target in the /json list: sets ws path and url. */
static int find_page_target(const char *json, char *wspath, size_t wn, char *url, size_t un)
{
	/* the objects of the array are flat enough to split on "{" at depth 1 */
	const char *p = json;
	int depth = 0;
	const char *start = NULL;
	for (; *p; p++) {
		if (*p == '"') { /* skip strings */
			for (p++; *p && *p != '"'; p++)
				if (*p == '\\' && p[1])
					p++;
			continue;
		}
		if (*p == '{') {
			if (depth++ == 0)
				start = p;
		} else if (*p == '}') {
			if (--depth == 0 && start) {
				size_t l = p - start + 1;
				char *obj = malloc(l + 1);
				memcpy(obj, start, l);
				obj[l] = 0;
				char *type = json_str_field(obj, "type");
				char *ws = json_str_field(obj, "webSocketDebuggerUrl");
				char *u = json_str_field(obj, "url");
				int ok = type && !strcmp(type, "page") && ws && u;
				if (ok) {
					const char *sl = strstr(ws, "/devtools/");
					snprintf(wspath, wn, "%s", sl ? sl : ws);
					snprintf(url, un, "%s", u);
				}
				free(type);
				free(ws);
				free(u);
				free(obj);
				if (ok)
					return 0;
			}
		}
	}
	return -1;
}

static void browser_fail(const char *why)
{
	JOBJ(NULL);
	jbool("available", 0);
	jstr("reason", why);
	JEND();
	putchar('\n');
	say("browser: skipped (%s)", why);
}

static void cmd_browser(const char *html_path, int port, const char *restore_file)
{
	char *json = malloc(1 << 20);
	if (http_get(port, "/json", json, 1 << 20)) {
		browser_fail("no DevTools on the kiosk browser (KIOSK_DEVTOOLS is not 1)");
		return;
	}
	char wspath[256], orig[2048];
	if (find_page_target(json, wspath, sizeof wspath, orig, sizeof orig)) {
		browser_fail("the kiosk browser has no page target");
		return;
	}
	free(json);
	/* A page left behind by a crashed run: take the saved address. */
	if (!strncmp(orig, "data:", 5) && restore_file) {
		char saved[2048];
		if (!slurp(restore_file, saved, sizeof saved) && saved[0])
			snprintf(orig, sizeof orig, "%s", saved);
	}
	FILE *hf = fopen(html_path, "r");
	if (!hf) {
		browser_fail("cannot read the benchmark page");
		return;
	}
	char *html = malloc(1 << 20);
	size_t hl = fread(html, 1, (1 << 20) - 1, hf);
	fclose(hf);
	char *url = malloc(hl * 2 + 64);
	strcpy(url, "data:text/html;base64,");
	b64((uint8_t *)html, hl, url + strlen(url));
	free(html);

	if (restore_file) {
		FILE *rf = fopen(restore_file, "w");
		if (rf) {
			fputs(orig, rf);
			fclose(rf);
		}
	}
	if (ws_connect(port, wspath)) {
		browser_fail("cannot open the DevTools WebSocket");
		return;
	}
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	char *r = cdp_call("Page.enable", "{}", 10);
	free(r);
	say("browser: kiosk page is loaded. Switch to the benchmark page ...");
	char *params = malloc(strlen(url) + 64);
	sprintf(params, "{\"url\":\"%s\"}", url);
	cdp_load_seen = 0;
	r = cdp_call("Page.navigate", params, 30);
	free(params);
	char *value = NULL, *err = NULL;
	if (!r) {
		err = strdup("navigation to the benchmark page failed");
	} else {
		free(r);
		if (!cdp_wait_load(30)) {
			err = strdup("the benchmark page did not load");
		} else {
			say("browser: running the page (about 45 s) ...");
			r = cdp_call("Runtime.evaluate",
				     "{\"expression\":\"tsxBench.run()\",\"awaitPromise\":true,\"returnByValue\":true}", 180);
			if (!r) {
				err = strdup("no answer from the page");
			} else {
				if (strstr(r, "exceptionDetails"))
					err = strdup("the page raised an exception");
				else
					value = json_str_field(r, "value");
				if (!value && !err)
					err = strdup("the page gave no result");
				free(r);
			}
		}
	}
	/* Always go back to the page of the user. */
	say("browser: back to the kiosk page ...");
	int saved_stop = g_stop;
	g_stop = 0;
	char *esc = malloc(strlen(orig) * 6 + 1);
	json_esc(orig, esc);
	params = malloc(strlen(esc) + 64);
	sprintf(params, "{\"url\":\"%s\"}", esc);
	cdp_load_seen = 0;
	double tb = now_s();
	r = cdp_call("Page.navigate", params, 30);
	free(params);
	int restored = 0;
	double load_s = -1;
	char *after = NULL;
	if (r) {
		free(r);
		int loaded = cdp_wait_load(60);
		load_s = now_s() - tb;
		(void)loaded;
		r = cdp_call("Runtime.evaluate", "{\"expression\":\"location.href\",\"returnByValue\":true}", 15);
		if (r) {
			after = json_str_field(r, "value");
			free(r);
		}
		restored = after && !strcmp(after, orig);
	}
	g_stop = saved_stop;
	free(esc);
	JOBJ(NULL);
	jbool("available", 1);
	if (err)
		jstr("error", err);
	if (value)
		jraw("page", value);
	JOBJ("restore");
	jbool("same_url", restored);
	jnum("load_seconds", load_s);
	JEND();
	JEND();
	putchar('\n');
	say("browser: kiosk page %s", restored ? "restored" : "NOT confirmed after the restore");
	if (restored && restore_file)
		unlink(restore_file);
	free(value);
	free(err);
	free(after);
	free(url);
	close(ws_fd);
}

/* Load the saved kiosk address again (after a run that stopped early). */
static void cmd_restore(int port, const char *restore_file)
{
	char saved[2048], *json = malloc(1 << 20), wspath[256], cur[2048];
	if (slurp(restore_file, saved, sizeof saved) || !saved[0])
		die("no saved address in %s", restore_file);
	if (http_get(port, "/json", json, 1 << 20) || find_page_target(json, wspath, sizeof wspath, cur, sizeof cur))
		die("no DevTools page on port %d", port);
	free(json);
	if (ws_connect(port, wspath))
		die("cannot open the DevTools WebSocket");
	free(cdp_call("Page.enable", "{}", 10));
	char *esc = malloc(strlen(saved) * 6 + 1), *params;
	json_esc(saved, esc);
	params = malloc(strlen(esc) + 64);
	sprintf(params, "{\"url\":\"%s\"}", esc);
	cdp_load_seen = 0;
	char *r = cdp_call("Page.navigate", params, 30);
	if (!r)
		die("the navigation failed");
	free(r);
	cdp_wait_load(60);
	r = cdp_call("Runtime.evaluate", "{\"expression\":\"location.href\",\"returnByValue\":true}", 15);
	char *after = r ? json_str_field(r, "value") : NULL;
	int same = after && !strcmp(after, saved);
	JOBJ(NULL);
	jbool("same_url", same);
	JEND();
	putchar('\n');
	say("restore: kiosk page %s", same ? "restored" : "NOT confirmed");
	if (same)
		unlink(restore_file);
	close(ws_fd);
}

/* ------------------------------------------------------------------ */
/* score: the absolute score of a result file (score version 1)       */
/* ------------------------------------------------------------------ */

/*
 * Score version 2. No panel is the reference and no score is scaled.
 *
 * The score of a test row is a rate in the unit of the row. A rate (MiB/s,
 * MB/s, MFLOPS, Ksteps/s, IOPS, fps, chunks/s) is the score as it is (kind R).
 * A time in seconds becomes runs per second, 1 / value (kind 1). A time in
 * milliseconds becomes events per second, 1000 / value (kind K). A latency in
 * ns becomes accesses per microsecond, 1000 / value (kind K). A group score is
 * the geometric mean of its rows. The overall score is the geometric mean of
 * the six groups, and only a panel with every group gets one. The core score
 * uses CPU, Memory, Sustained load and Storage. The ratio of two scores does not depend on the unit of a
 * row, because the geometric mean takes a unit change out of the ratio.
 *
 * NEVER change a row or a unit of this table. A change makes a new
 * SCORE_VERSION, and the numbers of the old version stop comparing. Keep the
 * table equal to SCORE_TABLE in host/tsx-bench-compare. The test
 * tests/test-bench.sh checks that both are equal.
 */
#define SCORE_VERSION 2

struct score_row {
	const char *group, *name, *unit;
	char kind;
	const char *path;
	const char *score_unit;
};

static const struct score_row score_table[] = {
	{"CPU", "1 thread, best core: SHA-256", "MiB/s", 'R', "cpu.tests.sha256.best_single", "MiB/s"},
	{"CPU", "1 thread, best core: CRC-32", "MiB/s", 'R', "cpu.tests.crc32.best_single", "MiB/s"},
	{"CPU", "1 thread, best core: n-body (float)", "Ksteps/s", 'R', "cpu.tests.nbody.best_single", "Ksteps/s"},
	{"CPU", "1 thread, best core: matrix multiply (float)", "MFLOPS", 'R', "cpu.tests.matmul.best_single", "MFLOPS"},
	{"CPU", "all cores: SHA-256", "MiB/s", 'R', "cpu.tests.sha256.multi.rate", "MiB/s"},
	{"CPU", "all cores: CRC-32", "MiB/s", 'R', "cpu.tests.crc32.multi.rate", "MiB/s"},
	{"CPU", "all cores: n-body (float)", "Ksteps/s", 'R', "cpu.tests.nbody.multi.rate", "Ksteps/s"},
	{"CPU", "all cores: matrix multiply (float)", "MFLOPS", 'R', "cpu.tests.matmul.multi.rate", "MFLOPS"},
	{"CPU", "busybox sha256sum, 24 MiB", "s", '1', "crosscheck.sha256sum.seconds", "runs/s"},
	{"CPU", "busybox gzip -3", "s", '1', "crosscheck.gzip3.seconds", "runs/s"},
	{"CPU", "busybox gunzip", "s", '1', "crosscheck.gunzip.seconds", "runs/s"},
	{"Memory", "1 thread read", "MB/s", 'R', "mem.best_single.read", "MB/s"},
	{"Memory", "1 thread write", "MB/s", 'R', "mem.best_single.write", "MB/s"},
	{"Memory", "1 thread copy", "MB/s", 'R', "mem.best_single.copy", "MB/s"},
	{"Memory", "1 thread triad", "MB/s", 'R', "mem.best_single.triad", "MB/s"},
	{"Memory", "all cores read", "MB/s", 'R', "mem.multi.read", "MB/s"},
	{"Memory", "all cores write", "MB/s", 'R', "mem.multi.write", "MB/s"},
	{"Memory", "all cores copy", "MB/s", 'R', "mem.multi.copy", "MB/s"},
	{"Memory", "all cores triad", "MB/s", 'R', "mem.multi.triad", "MB/s"},
	{"Memory", "latency 1 MiB (cache)", "ns", 'K', "mem.latency[kib=1024].ns", "accesses/us"},
	{"Memory", "latency 64 MiB (RAM)", "ns", 'K', "mem.latency[kib=65536].ns", "accesses/us"},
	{"Sustained load", "rate, first 10 s", "chunks/s", 'R', "sustained.summary.rate_first10", "chunks/s"},
	{"Sustained load", "rate, last 10 s", "chunks/s", 'R', "sustained.summary.rate_last10", "chunks/s"},
	{"Storage", "sequential read (page cache path)", "MB/s", 'R', "storage.seq_read.mbps", "MB/s"},
	{"Storage", "sequential read (O_DIRECT, 1 MiB)", "MB/s", 'R', "storage.seq_read_direct.mbps", "MB/s"},
	{"Storage", "random 4 KiB read", "IOPS", 'R', "storage.rand_read_4k.iops", "IOPS"},
	{"Storage", "random 4 KiB read, p99", "ms", 'K', "storage.rand_read_4k.p99_ms", "1/s"},
	{"Browser JS", "JS int", "ms", 'K', "browser.page.js.int_ms", "runs/s"},
	{"Browser JS", "JS float", "ms", 'K', "browser.page.js.float_ms", "runs/s"},
	{"Browser JS", "JS array", "ms", 'K', "browser.page.js.array_ms", "runs/s"},
	{"Browser JS", "JS json", "ms", 'K', "browser.page.js.json_ms", "runs/s"},
	{"Browser JS", "JS typed", "ms", 'K', "browser.page.js.typed_ms", "runs/s"},
	{"Browser rendering", "canvas 2D, 300 shapes", "fps", 'R', "browser.page.canvas2d.n300.fps", "fps"},
	{"Browser rendering", "canvas 2D, 1500 shapes", "fps", 'R', "browser.page.canvas2d.n1500.fps", "fps"},
	{"Browser rendering", "canvas 2D, 6000 shapes", "fps", 'R', "browser.page.canvas2d.n6000.fps", "fps"},
	{"Browser rendering", "CSS transform, 200 boxes", "fps", 'R', "browser.page.css_transform.n200.fps", "fps"},
	{"Browser rendering", "CSS transform, 800 boxes", "fps", 'R', "browser.page.css_transform.n800.fps", "fps"},
	{"Browser rendering", "CSS layout, 150 boxes", "fps", 'R', "browser.page.css_layout.fps", "fps"},
	{"Browser rendering", "list scroll, 1500 rows", "fps", 'R', "browser.page.scroll.fps", "fps"},
	{"Browser rendering", "WebGL shader, 8 loops", "fps", 'R', "browser.page.webgl.fill.loops8.fps", "fps"},
	{"Browser rendering", "WebGL shader, 32 loops", "fps", 'R', "browser.page.webgl.fill.loops32.fps", "fps"},
	{"Browser rendering", "WebGL shader, 128 loops", "fps", 'R', "browser.page.webgl.fill.loops128.fps", "fps"},
	{"Browser rendering", "WebGL, 1500 draw calls", "fps", 'R', "browser.page.webgl.draw_calls.fps", "fps"},
};

static const char *const score_groups[] = {
	"CPU", "Memory", "Sustained load", "Storage", "Browser JS", "Browser rendering"
};
#define N_SCORE_GROUPS ((int)(sizeof score_groups / sizeof score_groups[0]))
#define N_CORE_GROUPS 4 /* the first four groups */

/* A small JSON tree. It holds only what the score needs. */
struct jn {
	char type; /* o object, a array, s string, n number, t true, f false, z null */
	double num;
	char *key;
	struct jn *kid, *next;
};

struct jp {
	const char *p, *end;
	int depth;
};

static void jp_ws(struct jp *j)
{
	while (j->p < j->end && (*j->p == ' ' || *j->p == '\t' || *j->p == '\n' || *j->p == '\r'))
		j->p++;
}

/* Parse a string into a new buffer. Escapes: only the plain ones matter here. */
static char *jp_string(struct jp *j)
{
	if (j->p >= j->end || *j->p != '"')
		return NULL;
	j->p++;
	char *s = malloc((size_t)(j->end - j->p) + 1);
	size_t n = 0;
	if (!s)
		return NULL;
	while (j->p < j->end && *j->p != '"') {
		if (*j->p == '\\' && j->p + 1 < j->end) {
			j->p++;
			if (*j->p == 'u' && j->p + 4 < j->end) {
				s[n++] = '?';
				j->p += 4;
			} else if (*j->p == 'n') {
				s[n++] = '\n';
			} else if (*j->p == 't') {
				s[n++] = '\t';
			} else {
				s[n++] = *j->p;
			}
		} else {
			s[n++] = *j->p;
		}
		j->p++;
	}
	if (j->p >= j->end) {
		free(s);
		return NULL;
	}
	j->p++;
	s[n] = 0;
	return s;
}

static struct jn *jp_value(struct jp *j)
{
	jp_ws(j);
	if (j->p >= j->end || j->depth > 64)
		return NULL;
	struct jn *n = calloc(1, sizeof *n);
	if (!n)
		return NULL;
	char c = *j->p;
	if (c == '{' || c == '[') {
		struct jn **tail = &n->kid;
		n->type = c == '{' ? 'o' : 'a';
		j->p++;
		j->depth++;
		jp_ws(j);
		if (j->p < j->end && *j->p == (c == '{' ? '}' : ']')) {
			j->p++;
			j->depth--;
			return n;
		}
		for (;;) {
			char *key = NULL;
			jp_ws(j);
			if (c == '{') {
				key = jp_string(j);
				jp_ws(j);
				if (!key || j->p >= j->end || *j->p != ':')
					return NULL;
				j->p++;
			}
			struct jn *k = jp_value(j);
			if (!k)
				return NULL;
			k->key = key;
			*tail = k;
			tail = &k->next;
			jp_ws(j);
			if (j->p < j->end && *j->p == ',') {
				j->p++;
				continue;
			}
			if (j->p < j->end && *j->p == (c == '{' ? '}' : ']')) {
				j->p++;
				j->depth--;
				return n;
			}
			return NULL;
		}
	}
	if (c == '"') {
		char *s = jp_string(j);
		if (!s)
			return NULL;
		free(s);
		n->type = 's';
		return n;
	}
	if (!strncmp(j->p, "true", 4) && j->p + 4 <= j->end) {
		n->type = 't';
		j->p += 4;
		return n;
	}
	if (!strncmp(j->p, "false", 5) && j->p + 5 <= j->end) {
		n->type = 'f';
		j->p += 5;
		return n;
	}
	if (!strncmp(j->p, "null", 4) && j->p + 4 <= j->end) {
		n->type = 'z';
		j->p += 4;
		return n;
	}
	char *e;
	n->num = strtod(j->p, &e);
	if (e == j->p || e > j->end)
		return NULL;
	n->type = 'n';
	j->p = e;
	return n;
}

static struct jn *jn_member(const struct jn *o, const char *key, size_t len)
{
	if (!o || o->type != 'o')
		return NULL;
	for (struct jn *k = o->kid; k; k = k->next)
		if (k->key && strlen(k->key) == len && !strncmp(k->key, key, len))
			return k;
	return NULL;
}

/* Walk a path like "mem.latency[kib=1024].ns" (see get_path in tsx-bench-compare). */
static const struct jn *jn_path(const struct jn *d, const char *path)
{
	while (d && *path) {
		const char *dot = strchr(path, '.');
		size_t len = dot ? (size_t)(dot - path) : strlen(path);
		const char *br = memchr(path, '[', len);
		size_t nlen = br ? (size_t)(br - path) : len;
		d = jn_member(d, path, nlen);
		if (d && br) {
			char key[32];
			long val;
			const char *eq = memchr(br, '=', len - nlen);
			if (!eq || d->type != 'a' || (size_t)(eq - br - 1) >= sizeof key)
				return NULL;
			memcpy(key, br + 1, (size_t)(eq - br - 1));
			key[eq - br - 1] = 0;
			val = strtol(eq + 1, NULL, 10);
			const struct jn *hit = NULL;
			for (const struct jn *e = d->kid; e && !hit; e = e->next) {
				const struct jn *m = jn_member(e, key, strlen(key));
				if (m && m->type == 'n' && m->num == (double)val)
					hit = e;
			}
			d = hit;
		}
		path += len;
		if (*path == '.')
			path++;
	}
	return d;
}

static double score_row_value(const struct score_row *r, double v)
{
	if (!(v > 0))
		return NAN;
	return r->kind == 'R' ? v : r->kind == '1' ? 1.0 / v : 1000.0 / v;
}

static void cmd_score(int argc, char **argv)
{
	if (argc >= 3 && !strcmp(argv[2], "-T")) {
		/* the table, for the test that compares it with the host tool */
		for (size_t i = 0; i < sizeof score_table / sizeof score_table[0]; i++) {
			const struct score_row *r = &score_table[i];
			printf("%s|%s|%s|%s|%s\n", r->group, r->name, r->kind == 'R' ? "R" : r->kind == '1' ? "I1" : "I1000", r->path, r->score_unit);
		}
		return;
	}
	if (argc < 3)
		die("usage: tsx-bench-core score RESULT.json | score -T");
	FILE *f = fopen(argv[2], "r");
	if (!f)
		die("cannot read %s: %s", argv[2], strerror(errno));
	size_t cap = 1 << 16, len = 0;
	char *buf = malloc(cap);
	size_t got;
	while (buf && (got = fread(buf + len, 1, cap - len, f)) > 0) {
		len += got;
		if (len == cap) {
			if (cap > (64u << 20))
				die("%s is too big", argv[2]);
			cap *= 2;
			buf = realloc(buf, cap);
		}
	}
	fclose(f);
	if (!buf)
		die("out of memory");
	struct jp jp = {buf, buf + len, 0};
	const struct jn *root = jp_value(&jp);
	if (!root || root->type != 'o')
		die("%s is not a JSON object", argv[2]);

	double lsum[N_SCORE_GROUPS] = {0};
	int lcnt[N_SCORE_GROUPS] = {0};
	for (size_t i = 0; i < sizeof score_table / sizeof score_table[0]; i++) {
		const struct score_row *r = &score_table[i];
		const struct jn *v = jn_path(root, r->path);
		if (!v || v->type != 'n')
			continue;
		double s = score_row_value(r, v->num);
		if (!isfinite(s))
			continue;
		for (int g = 0; g < N_SCORE_GROUPS; g++) {
			if (!strcmp(r->group, score_groups[g])) {
				lsum[g] += log(s);
				lcnt[g]++;
			}
		}
	}
	double gs[N_SCORE_GROUPS];
	double osum = 0, csum = 0;
	int ocnt = 0, ccnt = 0;
	for (int g = 0; g < N_SCORE_GROUPS; g++) {
		gs[g] = lcnt[g] ? exp(lsum[g] / lcnt[g]) : NAN;
		if (lcnt[g]) {
			osum += log(gs[g]);
			ocnt++;
			if (g < N_CORE_GROUPS) {
				csum += log(gs[g]);
				ccnt++;
			}
		}
	}
	double overall = ocnt == N_SCORE_GROUPS ? exp(osum / ocnt) : NAN; /* every group, or no overall */
	double core = ccnt ? exp(csum / ccnt) : NAN;

	/* the JSON object on stdout */
	jdepth = 0;
	jfirst[0] = 1;
	putchar('{');
	jdepth = 1;
	jfirst[1] = 1;
	jint("score_version", SCORE_VERSION);
	jsep("overall");
	if (isfinite(overall))
		printf("%.4g", overall);
	else
		fputs("null", stdout);
	jsep("core");
	if (isfinite(core))
		printf("%.4g", core);
	else
		fputs("null", stdout);
	JOBJ("groups");
	for (int g = 0; g < N_SCORE_GROUPS; g++) {
		if (!lcnt[g])
			continue;
		jsep(score_groups[g]);
		printf("%.4g", gs[g]);
	}
	JEND();
	JARR("missing_groups");
	for (int g = 0; g < N_SCORE_GROUPS; g++)
		if (!lcnt[g]) {
			jsep(NULL);
			jputs(score_groups[g]);
		}
	JAEND();
	jdepth = 0;
	putchar('}');
	putchar('\n');

	/* the text for the terminal and the log, on stderr */
	say("== score (version %d, geometric mean of rates, more is better)", SCORE_VERSION);
	for (int g = 0; g < N_SCORE_GROUPS; g++) {
		if (lcnt[g])
			say("score %-18s %8.4g", score_groups[g], gs[g]);
		else
			say("score %-18s %8s", score_groups[g], "-");
	}
	if (ocnt < N_SCORE_GROUPS)
		say("score %-18s %8s  (no value in %d of %d groups, see CORE)", "OVERALL", "-", N_SCORE_GROUPS - ocnt, N_SCORE_GROUPS);
	else
		say("score %-18s %8.4g", "OVERALL", overall);
	say("score %-18s %8.4g  (CPU, Memory, Sustained load, Storage)", "CORE", core);
}

/* ------------------------------------------------------------------ */
/* main                                                               */
/* ------------------------------------------------------------------ */

static void usage(void)
{
	fputs("usage: tsx-bench-core COMMAND [ARGS]\n"
	      "  info | state [SECONDS] | cpu [-s SCALE] [-q] | mem [-q]\n"
	      "  sustained SECONDS [-t MILLIDEGREES] | storage [-d DEV | -f FILE] [-q]\n"
	      "  browser HTML [-p PORT] [-r RESTORE_FILE] | restore [-p PORT] [-r RESTORE_FILE]\n"
	      "  net IPV4 PORT [-s SECONDS]\n"
	      "  netserver PORT [IDLE_SECONDS] | timeit LABEL COMMAND [N] | gen FILE MIB\n"
	      "  score RESULT.json | score -T\n"
	      "  version\n",
	      stderr);
	exit(2);
}

int main(int argc, char **argv)
{
	if (argc < 2)
		usage();
	const char *c = argv[1];
	int quick = 0;
	double scale = 1.0;
	const char *dev = NULL, *file = NULL, *rfile = NULL;
	int port = 9222, secs = 4;
	long trip = 95000;
	/* options after the positional arguments */
	for (int i = 2; i < argc; i++) {
		if (!strcmp(argv[i], "-q"))
			quick = 1;
		else if (!strcmp(argv[i], "-s") && i + 1 < argc) {
			scale = atof(argv[i + 1]);
			secs = atoi(argv[i + 1]);
		} else if (!strcmp(argv[i], "-d") && i + 1 < argc)
			dev = argv[i + 1];
		else if (!strcmp(argv[i], "-f") && i + 1 < argc)
			file = argv[i + 1];
		else if (!strcmp(argv[i], "-p") && i + 1 < argc)
			port = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "-r") && i + 1 < argc)
			rfile = argv[i + 1];
		else if (!strcmp(argv[i], "-t") && i + 1 < argc)
			trip = atol(argv[i + 1]);
		else
			continue;
		if (strcmp(argv[i], "-q"))
			i++;
	}
	if (scale <= 0)
		scale = 1.0;
	if (secs < 1)
		secs = 4;
	if (secs > 60)
		secs = 60;
	setvbuf(stdout, NULL, _IOFBF, 1 << 16);
	if (!strcmp(c, "version")) {
		puts(TOOL_VERSION);
	} else if (!strcmp(c, "gen") && argc >= 4) {
		cmd_gen(argv[2], atoi(argv[3]));
	} else if (!strcmp(c, "netserver") && argc >= 3) {
		cmd_netserver(atoi(argv[2]), argc >= 4 ? atoi(argv[3]) : 0);
	} else if (!strcmp(c, "timeit") && argc >= 4) {
		cmd_timeit(argv[2], argv[3], argc >= 5 ? atoi(argv[4]) : 1);
	} else if (!strcmp(c, "net") && argc >= 4) {
		cmd_net(argv[2], atoi(argv[3]), secs);
	} else if (!strcmp(c, "browser") && argc >= 3) {
		cmd_browser(argv[2], port, rfile);
	} else if (!strcmp(c, "score")) {
		cmd_score(argc, argv);
	} else if (!strcmp(c, "restore")) {
		cmd_restore(port, rfile ? rfile : "/tmp/tsx-bench-restore-url");
	} else {
		topo_init();
		zones_init();
		if (!strcmp(c, "info"))
			cmd_info();
		else if (!strcmp(c, "state"))
			cmd_state(argc >= 3 && isdigit((unsigned char)argv[2][0]) ? atof(argv[2]) : 2.0);
		else if (!strcmp(c, "cpu"))
			cmd_cpu(scale, quick);
		else if (!strcmp(c, "mem"))
			cmd_mem(quick);
		else if (!strcmp(c, "sustained") && argc >= 3)
			cmd_sustained(atoi(argv[2]), trip);
		else if (!strcmp(c, "storage"))
			cmd_storage(dev, file, quick);
		else
			usage();
	}
	fflush(stdout);
	return 0;
}
