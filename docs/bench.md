# Benchmark

`tsx-bench` measures the speed of a panel in a way that compares across panels. It runs the same fixed work on every panel. It writes one JSON file and a text log. At the end of the run it prints a score and writes it into the JSON file. The host tool `tsx-bench-compare` reads several JSON files and compares the panels.

One full run takes 3 to 10 minutes, depending on the panel. A quick run (`-q`) takes about 2 minutes.

## Parts

| File | Where | Contents |
|---|---|---|
| `bench/usr/local/bin/tsx-bench` | panel | The driver. A `/bin/sh` script (busybox ash) that runs the tests in order and writes the result files. |
| `bench/src/tsx-bench-core.c` | panel | The measuring program. One static C program with no library except libc, libm and pthreads. Every test is a command of this program. The command `score` computes the scores. |
| `bench/usr/local/share/tsx/bench/bench.html` | panel | The page for the browser test. One file with no network access. |
| `bench/host/tsx-bench-compare` | host | The comparison tool. Python 3, standard library only. |

## Build

Build `tsx-bench-core` as a static program for the CPU of the panel. Use the compiler and the C library that you use for the other programs of the repo. Build on the build host, not on the workstation.

```
gcc -std=gnu11 -O2 -static -o tsx-bench-core bench/src/tsx-bench-core.c -lm -lpthread
```

For a 32-bit ARM CPU with NEON add `-march=armv7-a -mfpu=neon -mfloat-abi=hard`. Use the same flags and the same C library for the panels that you compare. The CPU tests are loops in C. The compiler decides how well a loop runs, so a different compiler version changes the scores.

## Run

1. Copy `tsx-bench`, `tsx-bench-core` and `bench.html` into one folder on the panel. A folder in tmpfs (`/tmp`) is the best place.
2. Run `./tsx-bench -l NAME` in that folder as root. `NAME` is the name of the panel in the result.
3. Copy the files `tsx-bench-NAME-normal-TIME.json` and `.txt` from `/tmp` (or from the folder of `-o`) to the host.
4. Run `tsx-bench-compare *.json` on the host.

The last lines of the run show the score of the panel. See "Scores".

The driver finds `tsx-bench-core` and `bench.html` next to itself, or in `/usr/local/lib/tsx/bench` and `/usr/local/share/tsx/bench`. The variables `TSX_BENCH_CORE` and `TSX_BENCH_PAGE` set other paths.

| Option | Meaning |
|---|---|
| `-l`, `--label NAME` | The name of the panel in the result. Default: the model of the device tree. Use a name that names no host, address or serial number. |
| `-o`, `--out DIR` | The folder for the result files. Default `/tmp`. |
| `-q`, `--quick` | A short run. The result does not compare with a full run. |
| `-t`, `--sustained SEC` | The length of the all-core load. Default 60. 0 skips the test. |
| `-d`, `--storage-dev DEV` | The block device or file that the storage test reads. Default: the root device. |
| `-n`, `--net HOST[:PORT]` | Run the network test against a server (see below). HOST is an IPv4 address. |
| `--pause-kiosk` | Stop the kiosk service for the run and start it again at the end. The browser test is skipped. The variant of the result is `paused`. |
| `--variant NAME` | The kind of the run in the file name and in the column name. |
| `--skip LIST` | Skip tests. A comma list of `crosscheck`, `cpu`, `mem`, `sustained`, `storage`, `net`, `browser`. |
| `--devtools-port N` | The DevTools port of the kiosk browser. Default 9222. |

## What the run does not change

- The tests write no byte to an eMMC, an SD card or any block device. The storage test opens the device with `O_RDONLY`.
- The only files that the run writes are in tmpfs (`/tmp`) and the result files in the folder of `-o`. `tsx-bench-core gen` refuses a folder that is not on tmpfs.
- The run writes `3` to `/proc/sys/vm/drop_caches` before the storage test. This only drops clean cache pages.
- The run does not reboot the panel, install a package or change a setting.
- The browser test changes what the kiosk shows for about one minute and loads the kiosk page again. See "Browser test".
- With `--pause-kiosk` the script stops the service `kiosk` and starts it again. It starts the service again also after a signal, when the running test has ended. The script waits until the kiosk is back: the file `/run/tsx/kiosk.ready` returns, or on a panel without that file, the browser process returns.

## Tests

| Test | What it measures | Unit |
|---|---|---|
| `state` | Before and after the run: the load average, the CPU use over 3 s and the five busiest processes, the governor and frequency of each cluster, all thermal zones, the number of browser processes, the kiosk ready file, the state of the display and the backlight. | |
| `info` | The model and compatible string of the device tree, the kernel, the CPU clusters with core type and maximum frequency, the RAM, the DRM drivers, the devfreq devices and the connected display modes. | |
| `crosscheck` | The busybox tools on a 24 MiB text file in tmpfs: `sha256sum`, `gzip -3` and `gzip -dc`. Best of two runs. The file name holds no host name. | seconds |
| `cpu` | Four loops with a fixed amount of work: SHA-256 (integer), CRC-32 with a table (integer), n-body with 5 bodies in double precision and a 128 by 128 matrix multiply in single precision. Each loop runs on one thread of each core cluster and on all cores. | MiB/s, Ksteps/s, MFLOPS |
| `mem` | Bandwidth of read, write, copy and triad on three 32 MiB arrays, with one thread and with all cores. Latency of a pointer chase through 16 KiB to 64 MiB, one node for each cache line. | MB/s, ns |
| `sustained` | All cores busy for 60 s. Once a second the test logs the work rate, the frequency of each cluster and all temperatures. It stops at 95 degrees C, but it ignores a sensor that is already at that value at the start. | chunks/s |
| `storage` | The root device, read only: 192 MiB sequential through the page cache (after the cache drop), 48 MiB sequential with `O_DIRECT` (one request of 1 MiB at a time) and random 4 KiB reads with `O_DIRECT` at queue depth 1. | MB/s, IOPS, ms |
| `net` | TCP throughput to a `tsx-bench-core netserver`, upload and download, 4 s each. | Mbit/s |
| `browser` | The page `bench.html` in the kiosk browser: JavaScript speed, canvas 2D, CSS transforms, CSS layout, list scrolling and WebGL, with the frame rate and the frame times. | ms, fps |

### CPU tests

Each test has a fixed number of work chunks. One thread runs all chunks in turn, or many threads take chunks from a shared counter. The rate is the work divided by the wall time. A cluster with slow cores takes fewer chunks, so the all-core rate is right on a panel with different cores.

Cluster 0 is the biggest cluster, by capacity and then by maximum frequency. The result holds the rate of every cluster. The score "1 thread, best core" uses the best one.

A single run of each test lasts 1 to 3 s on the panels so far. The program takes the best time of two runs.

### Memory tests

The arrays are much bigger than the caches. The copy is a loop in C, not `memcpy`, so the result does not depend on the C library. The latency test walks a random cycle through a buffer. The numbers for 16 KiB to 1 MiB show the caches. The number for 64 MiB shows the RAM and the cost of TLB misses.

### Sustained load

The load is a mix of CRC-32 and n-body chunks on every core. The test logs the rate in chunks per second. The summary holds the mean of the first 10 s and the last 10 s, and their ratio. A ratio below 1 means that the panel slowed down, for example by a thermal limit. The frequency log shows if the cause is a lower clock.

### Storage test

The sequential test through the page cache shows the speed that programs see. The `O_DIRECT` test shows the speed of single requests with no read-ahead. The random test uses `O_DIRECT`, so the cache does not change it. If the file system refuses `O_DIRECT`, the program reads through the cache with `POSIX_FADV_RANDOM` and the result has no `seq_read_direct` entry.

The result holds the card type, the name, the manufacturer ID, the revision and the date. It holds no serial number. If debugfs is mounted, the result holds the MMC bus settings (`ios`).

### Browser test

The test needs DevTools in the kiosk browser (`KIOSK_DEVTOOLS=1`, the default). Without DevTools the test is skipped and the result says why.

1. `tsx-bench` wakes the screen with `tsx-blank off` if the screen is off. A screen that is off gives no frame callbacks. A loop wakes the screen again every 10 s during the test, so the idle timer cannot blank it.
2. `tsx-bench-core browser` reads the address of the kiosk page from DevTools and saves it in `/tmp/tsx-bench-restore-url`.
3. It opens the DevTools WebSocket of the page and loads `bench.html` as a `data:` URL. The page needs no web server.
4. It calls `tsxBench.run()` in the page. The page runs about 40 s and returns its result as a JSON text.
5. It loads the saved address again and reads `location.href` to confirm it. The result holds `restore.same_url`.
6. `tsx-bench` blanks the screen again with `tsx-blank on` if the screen was off before the test.

The kiosk page reloads, so a dashboard shows its first state again. If a crash leaves the benchmark page in the browser, the next run finds the address in `/tmp/tsx-bench-restore-url` and loads it. To restore it by hand, run `tsx-bench-core restore`. It loads the saved address and removes the file when the kiosk page is back.

The frame tests draw into a canvas of 1024 by 640 pixels, so the number of pixels is the same on every panel. The CSS tests use CSS pixels, so a panel with a higher device pixel ratio has more pixels to draw. The result holds the device pixel ratio and the refresh rate. A frame rate of 60 is the limit of the display. Compare the frame rates only in tests where at least one panel is below 60.

The JavaScript tests are fixed loops: integer, float, array sort and map, JSON and string, and typed arrays. The time is the best of two runs, in milliseconds.

### Network test

Run `tsx-bench-core netserver 5599` on a host in the same network. It listens on all addresses and exits after a long idle time (the second argument gives it in seconds). Give the address of that host to `tsx-bench -n HOST`. The panel needs no other tool. The result depends on the link and the host, so the compare tool shows it and does not score it.

## State of the panel

Two runs compare only if the panels were in the same state. The result records the state, so a reader can see a difference:

- the kiosk before the run (the number of browser processes) and the display state
- the load average, the CPU use and the busiest processes in the 3 s before the run
- the governor and the frequency of each cluster, the temperature of all sensors
- the kernel, the model and the build date of the kernel

Run the panels as they normally run, with the kiosk on, and do not touch them during the run. A run with `--pause-kiosk` shows how much the kiosk takes from the CPU tests.

## Result file

The file is a JSON object with the key `schema` set to `tsx-bench/1`. The other keys are `tool_version`, `label`, `variant`, `started_utc`, `duration_s`, `quick`, `pause_kiosk`, `sustained_s` and one object for each test: `info`, `state_before`, `state_paused` (only with `--pause-kiosk`), `crosscheck`, `cpu`, `mem`, `sustained`, `storage`, `net`, `browser`, `state_after` and `scores` (see "Scores"). A test that did not run holds `{"skipped": "reason"}`. A test that failed holds `{"error": "text"}`. The result holds no host name, address or serial number. The `started_utc` value comes from the clock of the panel, which can be wrong.

A new version of the format gets a new `schema` value. `tsx-bench-compare` refuses a file with another value.

## Scores

The score is one number for a panel. A higher number is a faster panel. No panel is the reference, and no number is scaled to a panel.

### How the number is made

1. Every scored test row has a score that is a rate in a fixed unit. A rate stays as it is: MiB/s, MB/s, MFLOPS, Ksteps/s, IOPS, fps and chunks/s. A time in seconds becomes runs per second (1 divided by the seconds). A time in milliseconds becomes events per second (1000 divided by the milliseconds). A latency in ns becomes accesses per microsecond (1000 divided by the ns).
2. The score of a group is the geometric mean of the row scores of the group. The groups are CPU, Memory, Sustained load, Storage, Browser JS and Browser rendering.
3. The overall score is the geometric mean of the six group scores. Only a panel that has every group gets an overall score. A panel with a missing group shows no overall score ("-") and the report names the missing groups.
4. The core score is the geometric mean of the four groups CPU, Memory, Sustained load and Storage. Every panel has a core score. Compare a panel with a missing group by its core score.

The unit of a group score and of the overall score is the geometric-mean unit of its rows. It has no other name. The tool does not scale the number.

The table of rows and units is in `bench/src/tsx-bench-core.c` and in `bench/host/tsx-bench-compare`. The two tables must be equal, and the test checks it. The compare report names the unit of every row.

| Row kind | Measured value | Score |
|---|---|---|
| Rate | MiB/s, MB/s, MFLOPS, Ksteps/s, IOPS, fps, chunks/s | the value |
| Time of a busybox command | seconds | runs per second |
| Time of a JavaScript test or a p99 latency | ms | events per second (1000 / ms) |
| Memory latency | ns | accesses per microsecond (1000 / ns) |
| Sustained load, last 10 s / first 10 s | ratio | not scored |

### What the number means

Only the ratio of two scores has a meaning. A panel with a score of 200 is twice as fast as a panel with a score of 100, in the geometric mean of the rows. The ratio does not depend on the unit of a row. If a row changed from MB/s to kB/s, every panel would get the same factor in that row, and the geometric mean would move by the same factor for every panel. So the ratio between two panels stays. This is a property of the geometric mean. A panel that is twice as fast in every row has twice the score in every group and overall.

A single score on its own is not a measure against a standard. It is a number in the geometric-mean unit, and a score from another set of rows or other units does not compare with it. A new unit or a new set of rows is a new score version. The result file holds `score_version`, and the compare tool tells you when a file has another version. Never change a row or a unit in the table of version 2.

A test that was skipped or failed has no score. The group score uses the rows that exist. A panel with a missing group has no overall score, so an overall score always covers all six groups. The core score has a star (`*`) when a core group is missing.

A frame rate has the limit of the display, usually 60. A panel at the limit gets the same score in every row where it reaches the limit. A panel with a lower refresh rate scores lower in those rows. The slowdown ratio of the sustained load (the rate of the last 10 s divided by the rate of the first 10 s) is not scored. It is a number near 1 and has no unit of rate. The report shows it as information next to the temperature, and the group score uses only the two rate rows.

### On the panel

`tsx-bench` runs `tsx-bench-core score` on the result at the end. It prints the lines that start with `score` on the terminal and in the log. It writes the key `scores` into the JSON file:

```
"scores": {"score_version": 2, "overall": 101.2, "core": 265.1,
           "groups": {"CPU": 125.3, ...}, "missing_groups": []}
```

The key `overall` is `null` when the panel lacks a group. The text at the end of the run then shows `-` for the overall score.

`tsx-bench-core score FILE` works on any result file. `tsx-bench-core score -T` prints the table of rows.

## Compare

```
tsx-bench-compare [--md FILE] [--html FILE] [--title TEXT] [--no-text] RESULT.json...
tsx-bench-compare --rows
```

The tool prints a Markdown report. `--md` writes the report to a file, and `--html` writes one HTML page. The page has no script and no link to another site. It has bars and line charts of the sustained load. `--rows` prints the table of scored rows.

The tool always computes the scores from the values with its own table of rows. A file that an older `tsx-bench` wrote has no scores and works in the same way. The tool tells you when a file holds scores of another version.

The report has these parts:

- Panels: the model, the kernel, the cores and the state of each panel.
- Scores: the group scores, the overall score and the core score of each panel.
- One table for each group with the measured value and unit of every test.
- Comparison: the same tables, side by side, with the unit of each row. A cell shows the score, the percentage of the best panel in the row and the factor of the best panel (the best score divided by the score of the panel). For example `1510 (72 %, 1.39x)`. The best panel of a row is in bold.
- Notes: the failed and skipped tests, quick runs and files with another score version.

The bars of the HTML page are as long as the percentage of the best panel in the row. The number in the cell is the absolute score. The column name is the label. A variant other than `normal` is added in brackets. The same name twice gets a number.

## Tests of the tool

`tests/test-bench.sh` builds `tsx-bench-core` with the host compiler and runs every command with a small amount of work. It runs the browser test against a fake DevTools server (`tests/fake-devtools.py`). It runs the driver with fake `rc-service` and `tsx-blank` commands. It checks the scores of the core program and the compare tool with made-up panels, and that both give the same numbers. It is in the list of C tests of `tests/run-all.sh`.
