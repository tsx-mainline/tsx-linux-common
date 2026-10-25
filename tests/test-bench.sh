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
#  - tsx-bench-compare: the scores with made-up panels (a half-speed panel gets
#    50), the Markdown and HTML output, and the errors
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

echo "== compare =="
python3 -I -m py_compile "$COMPARE" 2>/dev/null; check "compare compiles" '[ $? = 0 ]'
rm -rf "$HERE/../bench/host/__pycache__"
python3 -I - "$W" <<'PY'
import json, sys
w = sys.argv[1]
def panel(name, speed, cores=4, hot=60000, variant="normal"):
    """A made-up result. speed 2 = twice the rate of speed 1 and half the time."""
    def r(x): return x * speed
    def t(x): return x / speed
    tests = {k: {"unit": "x", "kind": "int", "chunks": 1,
                 "single": [{"cluster": 0, "seconds": 1, "rate": r(10)}],
                 "best_single": r(10), "multi": {"threads": cores, "seconds": 1, "rate": r(10 * cores)}, "scaling": cores}
             for k in ("sha256", "crc32", "nbody", "matmul")}
    return {
        "schema": "tsx-bench/1", "tool_version": "0.1.0", "label": name, "variant": variant,
        "started_utc": "20260101T000000Z", "duration_s": 100, "quick": 0, "pause_kiosk": 0, "sustained_s": 60,
        "info": {"model": "Test Board", "kernel": "6.18.0", "cpu_count": cores,
                 "clusters": [{"index": 0, "cpus": list(range(cores)), "cpu_part": "0xd03", "max_khz": 1800000, "governor": "schedutil"}],
                 "mem_total_kb": 2000000, "drm_drivers": [{"card": 0, "driver": "gpu"}], "displays": [{"output": "c-1", "mode": "1280x800"}]},
        "state_before": {"loadavg": [0.1, 0.1, 0.1], "cpu_busy_pct": 5, "kiosk_browser_procs": 3, "temp_mC": [40000]},
        "crosscheck": {"data_mib": 24, "sha256sum": {"seconds": t(1.0)}, "gzip3": {"seconds": t(2.0)}, "gunzip": {"seconds": t(0.5)}},
        "cpu": {"tests": tests},
        "mem": {"best_single": {k: r(1000) for k in ("read", "write", "copy", "triad")},
                "multi": {k: r(2000) for k in ("read", "write", "copy", "triad")},
                "latency": [{"kib": 1024, "ns": t(10)}, {"kib": 65536, "ns": t(100)}]},
        "sustained": {"summary": {"rate_first10": r(100), "rate_last10": r(100) * (0.8 if name == "hot" else 1), "ratio_last_first": 0.8 if name == "hot" else 1,
                                  "temp_max_mC": hot},
                      "samples": [{"t": i + 1, "rate": r(100), "khz": [1800000], "temp_mC": [hot - 5000 + i * 100]} for i in range(5)]},
        "storage": {"type": "MMC", "name": "card", "seq_read": {"mbps": r(20)}, "seq_read_direct": {"mbps": r(10)},
                    "rand_read_4k": {"iops": r(1000), "p99_ms": t(2)}},
        "browser": {"available": True, "page": {"env": {"device_pixel_ratio": 1}, "refresh_hz": 60,
                    "js": {k + "_ms": t(100) for k in ("int", "float", "array", "json", "typed")},
                    "canvas2d": {"n300": {"fps": min(60, r(30))}, "n1500": {"fps": min(60, r(20))}, "n6000": {"fps": min(60, r(5))}},
                    "css_transform": {"n200": {"fps": min(60, r(30))}, "n800": {"fps": min(60, r(10))}},
                    "css_layout": {"fps": min(60, r(30))}, "scroll": {"fps": min(60, r(30))},
                    "webgl": {"renderer": "Test GPU", "fill": {"loops8": {"fps": 60}, "loops32": {"fps": min(60, r(20))}, "loops128": {"fps": min(60, r(5))}},
                              "draw_calls": {"fps": min(60, r(20))}}}},
        "net": {"upload_mbit": r(90), "download_mbit": r(90)},
    }
for name, spd, kw in (("fast", 2, {}), ("slow", 1, {}), ("hot", 2, {"hot": 90000})):
    json.dump(panel(name, spd, **kw), open("%s/%s.json" % (w, name), "w"))
d = panel("slow", 1, variant="paused"); json.dump(d, open(w + "/slow-paused.json", "w"))
d = panel("noweb", 1); d["browser"] = {"available": False, "reason": "no DevTools"}; d["storage"] = {"error": "storage failed (status 1)"}
json.dump(d, open(w + "/noweb.json", "w"))
json.dump({"schema": "other/1"}, open(w + "/wrong.json", "w"))
open(w + "/broken.json", "w").write("{not json")
PY
python3 -I "$COMPARE" "$W/fast.json" "$W/slow.json" --md "$W/cmp.md" --html "$W/cmp.html" > "$W/cmp.out" 2>&1
check "compare: exit status 0, stdout equals the --md file" '[ $? = 0 ] && [ "$(cat "$W/cmp.out")" = "$(cat "$W/cmp.md")" ]'
check "compare: the fast panel has 100 in every group, the slow panel 50 in CPU" 'grep -q "^| CPU | \*\*100\*\* | 50 |$" "$W/cmp.md" && grep -q "^| Memory | \*\*100\*\* | 50 |$" "$W/cmp.md"'
check "compare: the overall score of the slow panel is between 50 and 64 (frame rate caps and a steady ratio lift it)" 'grep -Eq "^\| \*\*Overall\*\* \| \*\*100\*\* \| (5[0-9]|6[0-4]) \|$" "$W/cmp.md"'
check "compare: a time row uses best/value (gzip: fast 100, slow 50)" 'grep -q "^| busybox gzip -3 (less is better) | s | \*\*1.00 (100)\*\* | 2.00 (50) |$" "$W/cmp.md"'
check "compare: a rate row (single SHA-256)" 'grep -q "1 thread, best core: SHA-256 | MiB/s | \*\*20.0 (100)\*\* | 10.0 (50) |" "$W/cmp.md"'
check "compare: the group scores are listed" 'for g in CPU Memory "Sustained load" Storage "Browser JS" "Browser rendering"; do grep -q "^| $g | " "$W/cmp.md" || exit 1; done'
check "compare: the panel table shows model, kernel and cores" 'grep -q "^| Model | Test Board | Test Board |$" "$W/cmp.md" && grep -q "^| Cores | 4 x 0xd03 @ 1.80 GHz" "$W/cmp.md"'
check "compare: network is shown and not scored" 'grep -q "^## Network" "$W/cmp.md" && grep -q "upload to the build host | Mbit/s | 180.0 | 90.0 |$" "$W/cmp.md"'
check "compare: HTML is one page with bars and charts, no script, no link" \
	'grep -q "<table" "$W/cmp.html" && grep -q "<svg" "$W/cmp.html" && ! grep -qi "<script\|<link\|src=\|http://\|https://" "$W/cmp.html"'
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
python3 -I "$COMPARE" "$W/fast.json" "$W/hot.json" "$W/slow-paused.json" "$W/noweb.json" > "$W/cmp2.md" 2>&1
check "compare: the variant is part of the column name" 'grep -q "slow (paused)" "$W/cmp2.md"'
check "compare: a panel without a browser or storage result shows - and a note" 'grep -q "noweb, browser: no DevTools" "$W/cmp2.md" && grep -q "noweb, storage: storage failed" "$W/cmp2.md"'
check "compare: a thermal loss lowers the sustained score of the hot panel" 'grep -Eq "^\| Sustained load \| \*\*100\*\* \| 8[0-9] \|" "$W/cmp2.md"'
check "compare: an overall score with a missing group has a star and a second score for the common groups" \
	'grep -q "^| \*\*Overall, groups of every panel\*\* |" "$W/cmp2.md" && grep -Eq "^\| \*\*Overall\*\* \|.* [0-9]+\* \|" "$W/cmp2.md" && grep -q "noweb has no Storage, Browser JS, Browser rendering" "$W/cmp2.md"'
check "compare: no star and no second score when every panel has every group" '! grep -q "groups of every panel" "$W/cmp.md" && ! grep -q "[0-9]\* |" "$W/cmp.md"'
check "compare: the same label twice gets a number" 'python3 -I "$COMPARE" "$W/slow.json" "$W/slow.json" | grep -q "slow #2"'
python3 -I "$COMPARE" "$W/wrong.json" >/dev/null 2>&1; check "compare: a file with another schema is refused" '[ $? != 0 ]'
python3 -I "$COMPARE" "$W/broken.json" >/dev/null 2>&1; check "compare: a broken file is refused" '[ $? != 0 ]'
python3 -I "$COMPARE" "$W/missing.json" >/dev/null 2>&1; check "compare: a missing file is refused" '[ $? != 0 ]'
python3 -I "$COMPARE" "$RES" "$W/fast.json" > "$W/cmp3.md" 2>&1
check "compare: it reads a real result of the driver" '[ $? = 0 ] && grep -q "Test-Board" "$W/cmp3.md"'

echo "== $N ok, $F failed =="
[ $F = 0 ] && echo PASS test-bench || echo FAIL test-bench
exit $F
