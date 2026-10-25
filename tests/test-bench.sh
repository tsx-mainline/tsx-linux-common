#!/bin/bash
# Host test for tsx-bench: the measuring program (bench/src/tsx-bench-core.c),
# the driver script (tsx-bench) and the host tool (tsx-bench-compare).
#
# The test builds the program with the host compiler (CC, default gcc) and runs
# every command with a tiny amount of work. It checks:
#  - each command prints valid JSON with the keys that the compare tool reads
#  - "gen" writes only to tmpfs, "storage" changes nothing in the file that it reads
#  - "net" and "netserver" work over the loopback
#  - "browser" works against a fake DevTools endpoint (tests/fake-devtools.py):
#    WebSocket fragments and pings, the page result, and the restore of the
#    kiosk page, also when a crashed run left the benchmark page in the browser
#  - the driver script: the result file, a failing part, --skip, the wake of the
#    screen, and --pause-kiosk with a fake rc-service (the service starts again,
#    also after a signal)
#  - "score": the scores of the core program, and that the core program and the
#    compare tool give the same numbers and the same table of rows
#  - tsx-bench-compare: the scores with made-up panels (hand-computed rates and
#    geometric means, twice the rate in every row gives twice the score, the
#    ratio of two panels does not depend on the unit of a row), the Comparison
#    section, the Markdown and HTML output, and the errors
# It needs python3. Usage: tests/test-bench.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/paths.sh"
SRC=$(P src/tsx-bench-core.c)
DRIVER=$(P usr/local/bin/tsx-bench)
PAGE=$(P usr/local/share/tsx/bench/bench.html)
COMPARE=$(P host/tsx-bench-compare)
W=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
N=0 F=0
ok() { N=$((N + 1)); echo "  ok: $*"; }
bad() { F=$((F + 1)); echo "  FAIL: $*"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# jq-like helper: py FILE 'expression on d'
py() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if (eval(sys.argv[2])) else 1)' "$1" "$2" 2>/dev/null; }

echo "== build =="
CORE=$W/tsx-bench-core
if ${CC:-gcc} -std=gnu11 -O2 -Wall -Wextra -Werror -o "$CORE" "$SRC" -lm -lpthread; then ok "compiles with -Wall -Wextra -Werror"
else bad "compile"; echo "== $N ok, $F failed =="; echo "FAIL test-bench"; exit 1; fi
export TSX_BENCH_ALLOW_ANY_FS=
unset TSX_BENCH_ALLOW_ANY_FS
check "version" '[ "$("$CORE" version)" = "$(grep -o "^VERSION=.*" "$DRIVER" | cut -d= -f2)" ]'
"$CORE" 2>/dev/null; check "no command gives status 2" '[ $? = 2 ]'
"$CORE" frobnicate 2>/dev/null; check "unknown command gives status 2" '[ $? = 2 ]'

echo "== info, state =="
"$CORE" info > "$W/info.json" 2>/dev/null
check "info is JSON with kernel, cores, clusters" "py $W/info.json \"d['kernel'] and d['cpu_count'] >= 1 and len(d['clusters']) >= 1 and d['mem_total_kb'] > 0\""
check "info holds no host name" '! grep -q "$(hostname)" "$W/info.json" || [ "$(hostname)" = localhost ] || [ -z "$(hostname)" ]'
"$CORE" state 0.3 > "$W/state.json" 2>/dev/null
check "state is JSON with load and cpu busy" "py $W/state.json \"len(d['loadavg']) == 3 and 'cpu_busy_pct' in d and 'kiosk_browser_procs' in d and 'display_on' in d\""

echo "== cpu, mem =="
"$CORE" cpu -s 0.03 -q > "$W/cpu.json" 2>/dev/null
check "cpu has four tests with positive rates" "py $W/cpu.json \"sorted(d['tests']) == ['crc32','matmul','nbody','sha256'] and all(t['best_single'] > 0 and t['multi']['rate'] > 0 and t['scaling'] > 0 for t in d['tests'].values())\""
check "cpu has a rate for each cluster" "py $W/cpu.json \"all(len(t['single']) >= 1 and t['single'][0]['cluster'] == 0 for t in d['tests'].values())\""
"$CORE" mem -q > "$W/mem.json" 2>/dev/null
check "mem has bandwidth and latency" "py $W/mem.json \"all(d['best_single'][k] > 0 and d['multi'][k] > 0 for k in ['read','write','copy','triad']) and d['dram_ns'] > 0 and len(d['latency']) >= 5\""
check "mem latency grows from 16 KiB to the biggest size" "py $W/mem.json \"d['latency'][-1]['ns'] > d['latency'][0]['ns']\""

echo "== sustained =="
"$CORE" sustained 3 -t 200000 > "$W/sus.json" 2>/dev/null
check "sustained has one sample per second" "py $W/sus.json \"d['seconds'] == 3 and len(d['samples']) == 3 and d['samples'][0]['rate'] > 0 and d['summary']['rate_first10'] > 0\""
check "sustained samples carry a frequency per cluster" "py $W/sus.json \"len(d['samples'][0]['khz']) == len(d['summary']['khz_min'])\""

echo "== gen, storage, timeit =="
# a folder that is not tmpfs must be refused
NOTMP=
for d in "$PWD" /var/tmp "$HOME" /; do
	t=$(stat -f -c %T "$d" 2>/dev/null) || continue
	case "$t" in tmpfs|ramfs) ;; *) [ -w "$d" ] && { NOTMP=$d; break; };; esac
done
if [ -n "$NOTMP" ]; then
	"$CORE" gen "$NOTMP/tsx-bench-refused.bin" 1 2>/dev/null
	check "gen refuses a folder that is not tmpfs" '[ $? != 0 ] && [ ! -e "$NOTMP/tsx-bench-refused.bin" ]'
else
	echo "  skip: every writable folder is tmpfs"
fi
export TSX_BENCH_ALLOW_ANY_FS=1
"$CORE" gen "$W/data.bin" 16 2>/dev/null
check "gen writes the requested size" '[ "$(wc -c < "$W/data.bin")" = 16777216 ]'
check "gen data is text-like (gzip makes it smaller than 60 %)" '[ "$(gzip -3 -c "$W/data.bin" | wc -c)" -lt 10000000 ]'
before=$(sha256sum < "$W/data.bin"); mt=$(stat -c %Y "$W/data.bin")
"$CORE" storage -f "$W/data.bin" -q > "$W/stor.json" 2>/dev/null
check "storage reads a file: valid JSON, speed, IOPS" "py $W/stor.json \"d['seq_read']['mbps'] > 0 and d['rand_read_4k']['iops'] > 0 and d['rand_read_4k']['p99_ms'] >= d['rand_read_4k']['p50_ms']\""
check "storage leaves the file unchanged" '[ "$(sha256sum < "$W/data.bin")" = "$before" ] && [ "$(stat -c %Y "$W/data.bin")" = "$mt" ]'
"$CORE" storage -f /nonexistent/file -q >/dev/null 2>&1
check "storage fails on a missing file" '[ $? != 0 ]'
"$CORE" timeit one "true" 2 > "$W/t.json" 2>/dev/null
check "timeit gives label, seconds, status" "py $W/t.json \"d['label'] == 'one' and d['seconds'] >= 0 and d['status'] == 0 and d['repeats'] == 2\""
"$CORE" timeit bad "exit 3" > "$W/t.json" 2>/dev/null
check "timeit gives the status of the command" "py $W/t.json \"d['status'] == 3\""
# the source holds no write call for a block device
check "the source opens files read-only (no O_WRONLY or O_RDWR except drop_caches)" \
	'[ "$(grep -c "O_WRONLY\|O_RDWR" "$SRC")" = 2 ]'
check "the source writes to /proc/sys/vm/drop_caches only" \
	'[ "$(grep -c "\"/proc/sys/vm/drop_caches\", O_WRONLY" "$SRC")" = 1 ]'

echo "== net =="
PORT=$((20000 + $$ % 20000))
"$CORE" netserver "$PORT" 20 >/dev/null 2>&1 &
sleep 0.5
"$CORE" net 127.0.0.1 "$PORT" -s 1 > "$W/net.json" 2>/dev/null
check "net gives upload and download" "py $W/net.json \"d['upload_mbit'] > 0 and d['download_mbit'] > 0\""
"$CORE" net 127.0.0.1 1 -s 1 > "$W/net2.json" 2>/dev/null
check "net reports a refused connection" "py $W/net2.json \"'error' in d\""

echo "== browser =="
BPORT=$((PORT + 1))
python3 -I "$HERE/fake-devtools.py" "$BPORT" "$W/dt.log" &
sleep 0.7
"$CORE" browser "$PAGE" -p "$BPORT" -r "$W/restore" > "$W/br.json" 2>/dev/null
check "browser: available, the page result passes through unchanged" "py $W/br.json \"d['available'] and d['page']['js']['total_ms'] == 123.5 and d['page']['note'] == 'a \\\"quoted\\\" \\u00e9 text'\""
check "browser: the kiosk page is confirmed after the restore" "py $W/br.json \"d['restore']['same_url'] is True\""
check "browser: the order of the commands" \
	'[ "$(cut -c1-31 "$W/dt.log" | tr "\n" "|")" = "Page.enable|navigate data:text/html;base64,|evaluate tsxBench.run()|navigate https://kiosk.example/|evaluate location.href|" ]'
check "browser: the restore file is gone after a good restore" '[ ! -e "$W/restore" ]'
check "browser: the page sent is the file bench.html" \
	'[ "$(grep "^navigate data" "$W/dt.log" | head -1 | cut -c10- | sed "s/^data:text\/html;base64,//" | head -c 40 | base64 -d 2>/dev/null | head -c 15)" = "<!doctype html>" ]'
# a crashed run left the benchmark page in the browser: the saved address wins
: > "$W/dt2.log"
python3 -I "$HERE/fake-devtools.py" $((BPORT + 1)) "$W/dt2.log" "data:text/html;base64,AAAA" &
sleep 0.7
printf 'https://kiosk.example/saved' > "$W/restore2"
"$CORE" browser "$PAGE" -p $((BPORT + 1)) -r "$W/restore2" > "$W/br2.json" 2>/dev/null
check "browser: restores the saved address after a crashed run" "py $W/br2.json \"d['restore']['same_url'] is True\" && grep -q 'navigate https://kiosk.example/saved' $W/dt2.log"
printf 'https://kiosk.example/by-hand' > "$W/restore3"
"$CORE" restore -p $((BPORT + 1)) -r "$W/restore3" > "$W/rs.json" 2>/dev/null
check "restore: loads the saved address and removes the file" "py $W/rs.json \"d['same_url'] is True\" && grep -q 'navigate https://kiosk.example/by-hand' $W/dt2.log && [ ! -e $W/restore3 ]"
"$CORE" restore -p $((BPORT + 1)) -r "$W/nothing" >/dev/null 2>&1
check "restore: without a saved address it fails" '[ $? != 0 ]'
"$CORE" browser "$PAGE" -p 1 > "$W/br3.json" 2>/dev/null
check "browser: no DevTools gives available=false with a reason" "py $W/br3.json \"d['available'] is False and d['reason']\""
check "page: bench.html has no external link and defines tsxBench.run" '! grep -q "https\?://" "$PAGE" && grep -q "window.tsxBench = { run: run }" "$PAGE"'

echo "== driver =="
export TSX_BENCH_CORE=$CORE TSX_BENCH_PAGE=$PAGE
mkdir -p "$W/out" "$W/bin"
D="$W/out"
sh "$DRIVER" -q -t 2 -l "Test Board" --skip browser,net -d "$W/data.bin" -o "$D" > "$W/drv.out" 2>&1
check "driver: exit status 0" '[ $? = 0 ]'
RES=$(ls "$D"/tsx-bench-Test-Board-normal-*.json 2>/dev/null | head -1)
check "driver: result file name has label, variant and time" '[ -n "$RES" ]'
check "driver: result JSON has schema, label and every section" "py $RES \"d['schema'] == 'tsx-bench/1' and d['label'] == 'Test-Board' and all(k in d for k in ['info','state_before','crosscheck','cpu','mem','sustained','storage','state_after'])\""
check "driver: crosscheck has three timings" "py $RES \"all(d['crosscheck'][k]['seconds'] > 0 for k in ['sha256sum','gzip3','gunzip'])\""
check "driver: skipped sections say why" "py $RES \"d['browser']['skipped'] and d['net']['skipped']\""
check "driver: a log file with the progress lines" 'grep -q "== cpu" "$D"/tsx-bench-Test-Board-normal-*.txt && grep -q "tsx-bench: done" "$D"/tsx-bench-Test-Board-normal-*.txt'
check "driver: the log ends with a summary of the headline lines" 'grep -q "^== Summary: Test-Board" "$D"/tsx-bench-Test-Board-normal-*.txt && sed -n "/^== Summary/,\$p" "$D"/tsx-bench-Test-Board-normal-*.txt | grep -q "cpu sha256  single c0"'
check "driver: the result holds the scores with the score version" "py $RES \"d['scores']['score_version'] == 2 and d['scores']['core'] > 0 and 'CPU' in d['scores']['groups'] and d['scores']['overall'] is None and sorted(d['scores']['missing_groups']) == ['Browser JS', 'Browser rendering']\""
check "driver: the log and the terminal end with the scores" 'grep -q "^score OVERALL" "$D"/tsx-bench-Test-Board-normal-*.txt && grep -q "^score CORE" "$D"/tsx-bench-Test-Board-normal-*.txt && grep -q "^score OVERALL" "$W/drv.out"'
check "driver: the result is one JSON object (the scores are inside the file)" "py $RES \"isinstance(d, dict) and d['schema'] == 'tsx-bench/1'\" && [ \"\$(wc -l < $RES)\" = 1 ]"
check "driver: no work folder is left in /tmp" '[ -z "$(ls -d /tmp/tsx-bench.* 2>/dev/null)" ]'
check "driver: the result holds no host name" '! grep -q "$(hostname)" "$RES" || [ -z "$(hostname)" ]'
# a failing part gives an error object and the run goes on
sh "$DRIVER" -q -t 0 -l fail --skip browser,net,crosscheck,cpu,mem -d /nonexistent/dev -o "$D" > "$W/drv2.out" 2>&1
RES2=$(ls "$D"/tsx-bench-fail-normal-*.json | head -1)
check "driver: a failing storage test gives an error entry" "py $RES2 \"'error' in d['storage'] and d['sustained']['skipped']\""
sh "$DRIVER" --bogus >/dev/null 2>&1; check "driver: unknown option gives status 1" '[ $? = 1 ]'
sh "$DRIVER" --skip bogus >/dev/null 2>&1; check "driver: unknown test in --skip gives status 1" '[ $? = 1 ]'
sh "$DRIVER" -t abc >/dev/null 2>&1; check "driver: --sustained needs a number" '[ $? = 1 ]'

echo "== driver: browser with a fake screen wake =="
cat > "$W/bin/tsx-blank" <<EOF
#!/bin/sh
echo "\$*" >> $W/blank.log
EOF
chmod +x "$W/bin/tsx-blank"
: > "$W/dt3.log"
python3 -I "$HERE/fake-devtools.py" $((BPORT + 2)) "$W/dt3.log" &
sleep 0.7
PATH="$W/bin:$PATH" sh "$DRIVER" -q -l br --skip crosscheck,cpu,mem,sustained,storage,net --devtools-port $((BPORT + 2)) -o "$D" > "$W/drv3.out" 2>&1
RES3=$(ls "$D"/tsx-bench-br-normal-*.json | head -1)
check "driver: the browser result is part of the JSON" "py $RES3 \"d['browser']['available'] and d['browser']['restore']['same_url']\""
check "driver: the screen was woken (and not blanked, it was not blank)" 'grep -q "^off$" "$W/blank.log" && ! grep -q "^on$" "$W/blank.log"'
check "driver: the wake loop ends with the script" 'sleep 1; ! pgrep -f "tsx-blank off" >/dev/null 2>&1 || true'

echo "== driver: --pause-kiosk =="
cat > "$W/bin/rc-service" <<EOF
#!/bin/sh
echo "\$*" >> $W/rc.log
exit 0
EOF
chmod +x "$W/bin/rc-service"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/pgrep"; chmod +x "$W/bin/pgrep"   # a browser process exists
: > "$W/rc.log"
PATH="$W/bin:$PATH" sh "$DRIVER" -q -t 1 -l pz --pause-kiosk --skip crosscheck,cpu,mem,storage -o "$D" > "$W/drv4.out" 2>&1
RES4=$(ls "$D"/tsx-bench-pz-paused-*.json | head -1)
check "driver: the kiosk service is stopped and started again, then checked" '[ "$(tr "\n" "|" < "$W/rc.log")" = "kiosk status|kiosk stop|kiosk start|kiosk status|" ]'
check "driver: the log says that the kiosk is back" 'grep -q "the kiosk is back after" "$D"/tsx-bench-pz-paused-*.txt'
check "driver: the paused run has variant paused and a paused state" "py $RES4 \"d['variant'] == 'paused' and d['pause_kiosk'] == 1 and 'state_paused' in d and d['browser']['skipped']\""
: > "$W/rc.log"
( PATH="$W/bin:$PATH" exec sh "$DRIVER" -q -t 8 -l intr --pause-kiosk --skip crosscheck,cpu,mem,storage -o "$D" > "$W/drv5.out" 2>&1 ) &
DPID=$!
sleep 9
pkill -TERM -f "tsx-bench -q -t 8 -l intr" 2>/dev/null
kill -TERM $DPID 2>/dev/null
wait $DPID 2>/dev/null
check "driver: after a signal the kiosk service starts again" 'grep -q "^kiosk start" "$W/rc.log"'

echo "== scores of the core program =="
check "the table of rows of the core program equals the table of the compare tool" \
	'[ "$("$CORE" score -T)" = "$(python3 -I "$COMPARE" --rows)" ]'
"$CORE" score "$W/nothing.json" >/dev/null 2>&1; check "score: a missing file fails" '[ $? != 0 ]'
echo '{"cpu": [1, 2' > "$W/badjson.json"
"$CORE" score "$W/badjson.json" >/dev/null 2>&1; check "score: a broken JSON file fails" '[ $? != 0 ]'
echo '{"label": "empty"}' > "$W/emptyres.json"
"$CORE" score "$W/emptyres.json" > "$W/empty.out" 2>/dev/null
check "score: a file without test values gives null scores and every group as missing" \
	"py $W/empty.out \"d['overall'] is None and d['core'] is None and d['groups'] == {} and len(d['missing_groups']) == 6\""

echo "== compare =="
python3 -I -m py_compile "$COMPARE" 2>/dev/null; check "compare compiles" '[ $? = 0 ]'
rm -rf "$HERE/../bench/host/__pycache__"
python3 -I - "$W" "$COMPARE" <<'PY'
import json, math, re, subprocess, sys
w, compare = sys.argv[1], sys.argv[2]
# the table of rows: group|test|kind|path|score unit
table = [l.split("|") for l in subprocess.check_output(["python3", "-I", compare, "--rows"], text=True).splitlines()]

def setp(d, path, val):
    """Set the value at a path like mem.latency[kib=1024].ns."""
    segs = path.split(".")
    for i, s in enumerate(segs):
        m = re.match(r"^(\w+)\[(\w+)=(\d+)\]$", s)
        last = i == len(segs) - 1
        if m:
            d = [e for e in d[m.group(1)] if e[m.group(2)] == int(m.group(3))][0]
        elif last:
            d[s] = val
        else:
            d = d[s]

BASE = 5.0   # the score of every row of a panel with speed 1

def panel(name, speed=1.0, cores=4, hot=60000, variant="normal", per_group=None, per_row=None):
    """A made-up result. Every row scores BASE * speed: a rate has that value, a
    time in seconds is 1 / score and a time in ms or ns is 1000 / score."""
    tests = {k: {"unit": "x", "kind": "int", "chunks": 1,
                 "single": [{"cluster": 0, "seconds": 1, "rate": 10}],
                 "best_single": 10, "multi": {"threads": cores, "seconds": 1, "rate": 10 * cores}, "scaling": cores}
             for k in ("sha256", "crc32", "nbody", "matmul")}
    d = {
        "schema": "tsx-bench/1", "tool_version": "0.2.0", "label": name, "variant": variant,
        "started_utc": "20260101T000000Z", "duration_s": 100, "quick": 0, "pause_kiosk": 0, "sustained_s": 60,
        "info": {"model": "Test Board", "kernel": "6.18.0", "cpu_count": cores,
                 "clusters": [{"index": 0, "cpus": list(range(cores)), "cpu_part": "0xd03", "max_khz": 1800000, "governor": "schedutil"}],
                 "mem_total_kb": 2000000, "drm_drivers": [{"card": 0, "driver": "gpu"}], "displays": [{"output": "c-1", "mode": "1280x800"}]},
        "state_before": {"loadavg": [0.1, 0.1, 0.1], "cpu_busy_pct": 5, "kiosk_browser_procs": 3, "temp_mC": [40000]},
        "crosscheck": {"data_mib": 24, "sha256sum": {"seconds": 1}, "gzip3": {"seconds": 1}, "gunzip": {"seconds": 1}},
        "cpu": {"tests": tests},
        "mem": {"best_single": {}, "multi": {}, "latency": [{"kib": 1024, "ns": 1}, {"kib": 65536, "ns": 1}]},
        "sustained": {"summary": {"temp_max_mC": hot, "ratio_last_first": 1.0},
                      "samples": [{"t": i + 1, "rate": 100, "khz": [1800000], "temp_mC": [hot - 5000 + i * 100]} for i in range(5)]},
        "storage": {"type": "MMC", "name": "card", "seq_read": {}, "seq_read_direct": {}, "rand_read_4k": {}},
        "browser": {"available": True, "page": {"env": {"device_pixel_ratio": 1}, "refresh_hz": 60,
                    "js": {}, "canvas2d": {"n300": {}, "n1500": {}, "n6000": {}},
                    "css_transform": {"n200": {}, "n800": {}}, "css_layout": {}, "scroll": {},
                    "webgl": {"renderer": "Test GPU", "fill": {"loops8": {}, "loops32": {}, "loops128": {}}, "draw_calls": {}}}},
        "net": {"upload_mbit": 90 * speed, "download_mbit": 90 * speed},
    }
    for g, n, kind, path, unit in table:
        s = speed
        if per_group and g in per_group:
            s = per_group[g]
        if per_row and n in per_row:
            s = per_row[n]
        score = BASE * s
        setp(d, path, {"R": score, "I1": 1.0 / score, "I1000": 1000.0 / score}[kind])
    return d

def save(name, d):
    json.dump(d, open("%s/%s.json" % (w, name), "w"))

save("base", panel("base"))
save("fast", panel("fast", 2))
save("slow", panel("slow", 0.5))
# a panel that loses speed in the sustained load: the last 10 s drop to 80 %. The ratio
# (shown and not scored) is 0.01, so a scored ratio would change the group a lot.
hot = panel("hot", 2, hot=90000)
hot["sustained"]["summary"]["rate_last10"] *= 0.8
hot["sustained"]["summary"]["ratio_last_first"] = 0.01
save("hot", hot)
save("slow-paused", panel("slow", 0.5, variant="paused"))
# the geometric means: the first CPU row 4 times faster, Memory 4 times slower
save("mix", panel("mix", per_group={"Memory": 0.25}, per_row={"1 thread, best core: SHA-256": 4}))
noweb = panel("noweb")
noweb["browser"] = {"available": False, "reason": "no DevTools"}
noweb["storage"] = {"error": "storage failed (status 1)"}
save("noweb", noweb)
# a file with scores of another version
v3 = panel("v3")
v3["scores"] = {"score_version": 3, "overall": 1, "core": 1, "groups": {}}
save("v3", v3)
json.dump({"schema": "other/1"}, open(w + "/wrong.json", "w"))
open(w + "/broken.json", "w").write("{not json")

def gm(xs): return math.exp(sum(math.log(x) for x in xs) / len(xs))
def sc(v):
    return "%.0f" % v if abs(v) >= 100 else ("%.1f" % v if abs(v) >= 10 else "%.2f" % v)
cpu = gm([BASE * 4] + [BASE] * 10)   # 11 CPU rows
mem = BASE * 0.25
exp = {
    "MIX_CPU": cpu, "MIX_MEM": mem,
    "MIX_OVERALL": gm([cpu, mem] + [BASE] * 4),
    "MIX_CORE": gm([cpu, mem, BASE, BASE]),
    "HOT_SUST": gm([BASE * 2, BASE * 1.6]),
}
with open(w + "/expect.sh", "w") as f:
    for k, v in exp.items():
        f.write("E_%s=%s\n" % (k, sc(v)))
PY
. "$W/expect.sh"

python3 -I "$COMPARE" "$W/fast.json" "$W/slow.json" --md "$W/cmp.md" --html "$W/cmp.html" > "$W/cmp.out" 2>&1
check "compare: exit status 0, stdout equals the --md file" '[ $? = 0 ] && [ "$(cat "$W/cmp.out")" = "$(cat "$W/cmp.md")" ]'
check "compare: a panel with rates of 10 in every row scores 10 in every group, a panel with 2.5 scores 2.50" \
	'for g in CPU Memory "Sustained load" Storage "Browser JS" "Browser rendering"; do grep -q "^| $g | \*\*10.0\*\* | 2.50 |$" "$W/cmp.md" || exit 1; done'
check "compare: the overall score and the core score are 10.0 and 2.50" \
	'grep -q "^| \*\*Overall\*\* | \*\*10.0\*\* | 2.50 |$" "$W/cmp.md" && grep -q "^| \*\*Core (CPU, Memory, Sustained load, Storage)\*\* | \*\*10.0\*\* | 2.50 |$" "$W/cmp.md"'
check "compare: the text says that no panel is the reference and the report has no reference panel" \
	'grep -q "No panel is the reference" "$W/cmp.md" && grep -q "Score version 2" "$W/cmp.md" && ! grep -qi "reference panel" "$W/cmp.md"'
check "compare: a rate row is its own score (single SHA-256 in MiB/s)" \
	'grep -q "^| 1 thread, best core: SHA-256 | MiB/s | \*\*10.0\*\* | 2.50 |$" "$W/cmp.md" && sed -n "/^## Comparison/,\$p" "$W/cmp.md" | grep -q "^| 1 thread, best core: SHA-256 | MiB/s | \*\*10.0 (100 %, 1.00x)\*\* | 2.50 (25 %, 4.00x) |$"'
check "compare: a time in seconds is a score in runs per second (gzip 0.10 s is 10.0 runs/s)" \
	'grep -q "^| busybox gzip -3 (less is better) | s | \*\*0.10\*\* | 0.40 |$" "$W/cmp.md" && sed -n "/^## Comparison/,\$p" "$W/cmp.md" | grep -q "^| busybox gzip -3 | runs/s | \*\*10.0 (100 %, 1.00x)\*\* | 2.50 (25 %, 4.00x) |$"'
check "compare: a time in ms is 1000 / ms (JS int 100 ms is 10.0 per second)" \
	'grep -q "^| JS int (less is better) | ms | \*\*100.0\*\* | 400.0 |$" "$W/cmp.md" && sed -n "/^## Comparison/,\$p" "$W/cmp.md" | grep -q "^| JS int | runs/s | \*\*10.0 (100 %, 1.00x)\*\*"'
check "compare: a latency in ns is 1000 / ns (accesses per microsecond)" \
	'grep -q "^| latency 64 MiB (RAM) (less is better) | ns | \*\*100.0\*\* | 400.0 |$" "$W/cmp.md" && sed -n "/^## Comparison/,\$p" "$W/cmp.md" | grep -q "^| latency 64 MiB (RAM) | accesses/us | \*\*10.0 (100 %, 1.00x)\*\*"'
check "compare: the Comparison section has a table for each scored group, with the unit of every row" \
	'for g in CPU Memory "Sustained load" Storage "Browser JS" "Browser rendering"; do sed -n "/^## Comparison/,\$p" "$W/cmp.md" | grep -q "^### $g$" || exit 1; done; sed -n "/^## Comparison/,\$p" "$W/cmp.md" | grep "^| " | grep -v "^|---" | grep -v "^| \(Group\|Test\) " | grep -v "^| \*\*" | awk -F"|" "{ if (\$3 ~ /^ *\$/) exit 1 }"'
check "compare: the Comparison section has a row for the last test" \
	'sed -n "/^## Comparison/,\$p" "$W/cmp.md" | grep -q "^| WebGL, 1500 draw calls | fps | \*\*10.0 (100 %, 1.00x)\*\* | 2.50 (25 %, 4.00x) |$"'
check "compare: the Comparison section has no network or temperature row" \
	'! sed -n "/^## Comparison/,\$p" "$W/cmp.md" | grep -q "Network\|upload\|hottest"'
check "compare: the panel table shows model, kernel and cores" 'grep -q "^| Model | Test Board | Test Board |$" "$W/cmp.md" && grep -q "^| Cores | 4 x 0xd03 @ 1.80 GHz" "$W/cmp.md"'
check "compare: network is shown and not scored" 'grep -q "^## Network" "$W/cmp.md" && grep -q "upload to the build host | Mbit/s | 180.0 | 45.0 |$" "$W/cmp.md"'
check "compare: HTML is one page with bars and charts, no script, no link" \
	'grep -q "<table" "$W/cmp.html" && grep -q "<svg" "$W/cmp.html" && grep -q "<h2>Comparison</h2>" "$W/cmp.html" && grep -q "10.0 (100 %, 1.00x)" "$W/cmp.html" && ! grep -qi "<script\|<link\|src=\|http://\|https://" "$W/cmp.html"'
check "compare: HTML parses and the tags balance" 'python3 -I - "$W/cmp.html" <<PY
import sys
from html.parser import HTMLParser
void = {"meta","br","hr","img","input","link"}
class P(HTMLParser):
    def __init__(s): super().__init__(); s.st=[]; s.bad=0
    def handle_starttag(s,t,a):
        if t not in void: s.st.append(t)
    def handle_endtag(s,t):
        if t in void: return
        if not s.st or s.st.pop()!=t: s.bad=1
p=P(); p.feed(open(sys.argv[1]).read()); sys.exit(1 if p.bad or p.st else 0)
PY'

echo "== compare: geometric means and unit independence =="
python3 -I "$COMPARE" "$W/base.json" > "$W/cmpbase.md" 2>&1
check "compare: one panel alone: 5.00 in every group and overall, 100 % and 1.00x everywhere in the Comparison" \
	'grep -q "^| Overall | 5.00 |$" <(sed "s/\*\*//g" "$W/cmpbase.md") && [ "$(sed -n "/^## Comparison/,\$p" "$W/cmpbase.md" | grep "^| " | grep -v "^|---" | grep -v "^| \(Group\|Test\) " | grep -vc "(100 %, 1.00x)")" = 0 ]'
python3 -I "$COMPARE" "$W/base.json" "$W/mix.json" 2>&1 | sed 's/\*\*//g' > "$W/cmpmix.md"   # no bold marks
check "compare: the group score is the geometric mean of the rows (CPU: one row 4x, ten rows 1x)" \
	'grep -q "^| CPU | 5.00 | $E_MIX_CPU |$" "$W/cmpmix.md"'
check "compare: no rescaling of a group (Memory: every row 0.25x gives 1.25)" 'grep -q "^| Memory | 5.00 | $E_MIX_MEM |$" "$W/cmpmix.md"'
check "compare: the overall score is the geometric mean of the group scores" \
	'grep -q "^| Overall | 5.00 | $E_MIX_OVERALL |$" "$W/cmpmix.md"'
check "compare: the core score uses CPU, Memory, Sustained load and Storage only" \
	'grep -q "^| Core (CPU, Memory, Sustained load, Storage) | 5.00 | $E_MIX_CORE |$" "$W/cmpmix.md"'
check "compare: twice the rate in every row gives exactly twice the score, and a unit change in a row does not change the ratio of two panels" \
	'python3 -I - "$COMPARE" "$W" <<PY
import importlib.machinery, importlib.util, random, sys
loader = importlib.machinery.SourceFileLoader("cmp", sys.argv[1])
spec = importlib.util.spec_from_loader("cmp", loader)
c = importlib.util.module_from_spec(spec); loader.exec_module(c)
w = sys.argv[2]
def scores(names):
    rows, groups, ov = c.analyze(c.load(["%s/%s.json" % (w, n) for n in names]))
    return ov["overall"], ov["core"], groups
o, k, g = scores(["base", "fast", "mix"])
assert abs(o[1] / o[0] - 2) < 1e-9 and abs(k[1] / k[0] - 2) < 1e-9, (o, k)
assert all(abs(v[1] / v[0] - 2) < 1e-9 for v in g.values())
ratio = (o[2] / o[0], k[2] / k[0], g["CPU"][2] / g["CPU"][0])
# a change of unit in every row (for example MB/s to kB/s) is a constant factor for the row
random.seed(7)
factor = {}
orig = c.Metric.score
def scaled(self, v):
    s = orig(self, v)
    return None if s is None else s * factor.setdefault(self.name, random.choice([0.001, 1000, 60, 1 / 3600.0, 1e6]))
c.Metric.score = scaled
o, k, g = scores(["base", "fast", "mix"])
assert abs(o[1] / o[0] - 2) < 1e-9
got = (o[2] / o[0], k[2] / k[0], g["CPU"][2] / g["CPU"][0])
assert all(abs(a - b) < 1e-9 * a for a, b in zip(ratio, got)), (ratio, got)
assert abs(o[0] - 5.0) > 1e-3   # the scores themselves changed
PY'
python3 -I "$COMPARE" "$W/fast.json" "$W/hot.json" "$W/slow-paused.json" "$W/noweb.json" "$W/v3.json" > "$W/cmp2.md" 2>&1
check "compare: the variant is part of the column name" 'grep -q "slow (paused)" "$W/cmp2.md"'
check "compare: a panel without a browser or storage result shows - and a note" 'grep -q "noweb, browser: no DevTools" "$W/cmp2.md" && grep -q "noweb, storage: storage failed" "$W/cmp2.md"'
check "compare: a thermal loss lowers the sustained score of the hot panel" 'sed "s/\*\*//g" "$W/cmp2.md" | grep -q "^| Sustained load | 10.0 | $E_HOT_SUST |"'
check "compare: a panel with a missing group has no overall score (-) and a note that names the groups" \
	'grep -Eq "^\| \*\*Overall\*\* \| .* \| - \| 5.00 \|$" "$W/cmp2.md" && grep -q "No overall score for: noweb (no Storage, Browser JS, Browser rendering)" "$W/cmp2.md"'
check "compare: the sustained ratio is shown in the results and is not in the Comparison or in the group score" \
	'grep -q "^| last 10 s / first 10 s (not scored) | ratio | " "$W/cmp2.md" && ! sed -n "/^## Comparison/,\$p" "$W/cmp2.md" | grep -q "not scored"'
check "compare: a panel without a browser test still has a core score; a missing core group gets a star and a note" \
	'grep -Eq "^\| \*\*Core \(CPU, Memory, Sustained load, Storage\)\*\* \|.* 5.00\* \|" "$W/cmp2.md" && grep -q "A star (\*) on a core score marks a panel that lacks core groups: noweb has no Storage" "$W/cmp2.md"'
check "compare: no star and no missing overall when every panel has every group" '! grep -q "[0-9]\* |" "$W/cmp.md" && ! grep -q "A star\|No overall" "$W/cmp.md"'
check "compare: a file with scores of another version gets a note and the tool computes version 2" \
	'grep -q "v3 holds scores of version 3" "$W/cmp2.md" && grep -Eq "^\| CPU \|.* 5.00 \|$" "$W/cmp2.md"'
check "compare: the same label twice gets a number" 'python3 -I "$COMPARE" "$W/slow.json" "$W/slow.json" | grep -q "slow #2"'
python3 -I "$COMPARE" "$W/wrong.json" >/dev/null 2>&1; check "compare: a file with another schema is refused" '[ $? != 0 ]'
python3 -I "$COMPARE" "$W/broken.json" >/dev/null 2>&1; check "compare: a broken file is refused" '[ $? != 0 ]'
python3 -I "$COMPARE" "$W/missing.json" >/dev/null 2>&1; check "compare: a missing file is refused" '[ $? != 0 ]'
python3 -I "$COMPARE" >/dev/null 2>&1; check "compare: no file is refused" '[ $? != 0 ]'
python3 -I "$COMPARE" "$RES" "$W/fast.json" > "$W/cmp3.md" 2>&1
check "compare: it reads a real result of the driver (with scores), next to a file without scores" '[ $? = 0 ] && grep -q "Test-Board" "$W/cmp3.md"'

echo "== scores: core program and compare tool agree =="
for n in base fast hot mix noweb; do
	"$CORE" score "$W/$n.json" > "$W/score-$n.json" 2>/dev/null
done
"$CORE" score "$RES" > "$W/score-res.json" 2>/dev/null
check "score: the core program and the compare tool give the same scores (every group, overall, core)" \
	'python3 -I - "$COMPARE" "$W" "$RES" <<PY
import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader("cmp", sys.argv[1])
spec = importlib.util.spec_from_loader("cmp", loader)
c = importlib.util.module_from_spec(spec); loader.exec_module(c)
w, res = sys.argv[2], sys.argv[3]
bad = 0
for name, path in [(n, "%s/%s.json" % (w, n)) for n in ("base", "fast", "hot", "mix", "noweb")] + [("res", res)]:
    runs = c.load([path])
    rows, groups, ov = c.analyze(runs)
    s = json.load(open("%s/score-%s.json" % (w, name)))
    def same(a, b):
        return (a is None and b is None) or (a is not None and b is not None and abs(a - b) <= 1e-3 * abs(b))
    ok = same(s["overall"], ov["overall"][0]) and same(s["core"], ov["core"][0])
    ok = ok and sorted(s["groups"]) == sorted(g for g in groups if groups[g][0] is not None)
    ok = ok and all(same(v, groups[g][0]) for g, v in s["groups"].items())
    if not ok:
        print("different scores for", name, s, ov["overall"], ov["core"]); bad = 1
sys.exit(bad)
PY'
check "score: the core program gives 5 for the base panel, 10 for twice the rate and has no reference key" \
	"py $W/score-base.json \"d['overall'] == 5.0 and d['core'] == 5.0 and d['score_version'] == 2 and all(v == 5.0 for v in d['groups'].values()) and d['missing_groups'] == [] and 'reference' not in d\" && py $W/score-fast.json \"d['overall'] == 10.0\""
check "score: the core program gives no overall score (null) to a panel with a missing group, and the core score" \
	"py $W/score-noweb.json \"d['missing_groups'] == ['Storage', 'Browser JS', 'Browser rendering'] and d['overall'] is None and d['core'] == 5.0\""

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-bench || echo FAIL test-bench
exit $F
