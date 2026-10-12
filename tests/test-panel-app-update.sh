#!/bin/bash
# Host test for panel-app/esphome/components/tsx_cards/update_logic.h: the
# update entities of the panel app (docs/panel-app.md, "Updates").
#  - update.state: the fields, the raw summary, bad and missing lines, a
#    missing file
#  - the state of the update entity: unknown, no update, available,
#    installing, restart required, and the hold after an install
#  - the mode and the automatic restart: the values and the lines for the
#    FIFO of tsx-panelctl (also written to a real FIFO)
#  - the hold after a set: the panel shows the set value until the file
#    shows it, at most 10 s
# It compiles C++, so run it only on a build host or in CI.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
SRC=$HERE/panel-app/esphome/components/tsx_cards
CXX=${CXX:-c++}
command -v "$CXX" >/dev/null 2>&1 || { echo "SKIPPED test-panel-app-update: no $CXX"; exit 0; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

cat > "$T/main.cpp" <<'C'
#include <cstdio>
#include <string>
#include <sys/stat.h>
#include "update_logic.h"
#include "control.h"
using namespace esphome::tsx_cards;
static int n = 0, f = 0;
static void check(bool c, const char *what) {
  if (c) { n++; printf("  ok: %s\n", what); } else { f++; printf("  FAIL: %s\n", what); }
}
static const char *const FULL =
    "installed 0.3.5\nlatest 0.3.6\ntitle TSX HOST packages\nsummary tsx-base, tsx-setup; restart needed after install\n"
    "in-progress no\nrestart-required no\nmode auto\nauto-restart on\n";
int main(int argc, char **argv) {
  if (argc != 2)
    return 2;
  UpdateStatus s;
  puts("== update.state ==");
  check(parse_update_state(FULL, s), "a full file is known");
  check(s.installed == "0.3.5" && s.latest == "0.3.6" && s.title == "TSX HOST packages", "versions and title");
  check(s.summary == "tsx-base, tsx-setup; restart needed after install", "the summary is raw to the end of the line");
  check(s.in_progress == 0 && s.restart_required == 0, "in-progress no, restart-required no");
  check(s.mode == "auto" && s.auto_restart == 1, "mode auto, auto-restart on");
  check(s.state() == UPD_AVAILABLE && s.latest_version() == "0.3.6", "0.3.5 -> 0.3.6 is available");
  check(parse_update_state("installed 0.3.6\r\nlatest 0.3.6\r\nmode manual\r\nauto-restart off\r\n", s) &&
            s.installed == "0.3.6" && s.mode == "manual" && s.auto_restart == 0,
        "CR LF lines");
  check(parse_update_state("# comment\nbogus\nunknown-key value\ninstalled 1.0\nlatest 1.0\nlatest 1.1", s) &&
            s.latest == "1.1",
        "comments and unknown keys are skipped, the last latest wins, no last newline");
  check(parse_update_state("installed   1.0   \n", s) && s.installed == "1.0", "extra spaces are cut");
  check(parse_update_state("installed 1.0\nsummary   a  b  \n", s) && s.summary == "a  b",
        "the summary keeps inner spaces, loses the edges");
  check(parse_update_state("installed 1.0\nmode sometimes\nauto-restart maybe\nin-progress perhaps\nrestart-required 1\n", s) &&
            s.mode.empty() && s.auto_restart == -1 && s.in_progress == -1 && s.restart_required == -1,
        "bad mode, auto-restart, yes/no values are unknown");

  puts("== the state ==");
  check(!parse_update_state("", s) && s.state() == UPD_UNKNOWN, "an empty file is unknown");
  check(!parse_update_state("latest 0.3.6\nmode auto\n", s) && s.state() == UPD_UNKNOWN, "no installed line is unknown");
  check(!parse_update_state("installed unknown\nlatest 0.3.6\n", s) && s.state() == UPD_UNKNOWN,
        "installed unknown is unknown");
  std::string path = std::string(argv[1]) + "/update.state";
  check(!read_update_state(path, s) && !s.present && s.state() == UPD_UNKNOWN, "a missing file is unknown");
  FILE *fp = fopen(path.c_str(), "w");
  fputs(FULL, fp);
  fclose(fp);
  check(read_update_state(path, s) && s.present && s.state() == UPD_AVAILABLE, "read the file: available");
  parse_update_state("installed 0.3.5\nlatest 0.3.5\n", s);
  check(s.state() == UPD_NO_UPDATE && s.latest_version() == "0.3.5", "latest = installed: no update");
  parse_update_state("installed 0.3.5\n", s);
  check(s.state() == UPD_NO_UPDATE && s.latest_version() == "0.3.5", "no latest line: no update, latest = installed");
  parse_update_state("installed 0.3.5\nlatest 0.3.5 + 2 packages\nin-progress no\n", s);
  check(s.state() == UPD_AVAILABLE && s.latest_version() == "0.3.5 + 2 packages", "other packages pending: available");
  parse_update_state("installed 0.3.5\nlatest 0.3.6\nin-progress yes\n", s);
  check(s.state() == UPD_INSTALLING, "in-progress yes: installing");
  parse_update_state("installed 0.3.5\nlatest 0.3.5\nin-progress yes\n", s);
  check(s.state() == UPD_INSTALLING, "installing wins over no update");
  parse_update_state("installed unknown\nin-progress yes\n", s);
  check(s.state() == UPD_UNKNOWN, "unknown wins over installing");
  check(UPD_UNKNOWN == 0 && UPD_NO_UPDATE == 1 && UPD_AVAILABLE == 2 && UPD_INSTALLING == 3,
        "the values are those of UpdateState of ESPHome");

  puts("== restart required ==");
  parse_update_state("installed 0.3.5\nlatest 0.3.6\nsummary installed, restart required\nin-progress no\nrestart-required yes\n", s);
  check(s.restart_required == 1 && s.state() == UPD_AVAILABLE, "restart required: yes, the entity stays available");
  parse_update_state("installed 0.3.5\nlatest 0.3.5\nrestart-required no\n", s);
  check(s.restart_required == 0, "restart required: no");
  parse_update_state("installed 0.3.5\n", s);
  check(s.restart_required == -1, "no line: not known");

  puts("== mode and automatic restart ==");
  check(valid_update_mode("auto") && valid_update_mode("manual"), "auto and manual are valid");
  check(!valid_update_mode("") && !valid_update_mode("Auto") && !valid_update_mode("auto ") && !valid_update_mode("on") &&
            !valid_update_mode("manual\n"),
        "other text is refused (lower case only)");
  check(update_mode_line("auto") == "update-mode auto" && update_mode_line("manual") == "update-mode manual", "the update-mode lines");
  check(update_mode_line("x").empty() && update_mode_line("auto\nreboot").empty(), "a bad mode gives no line");
  check(auto_restart_line(true) == "auto-restart on" && auto_restart_line(false) == "auto-restart off", "the auto-restart lines");
  check(std::string(update_install_line()) == "update-install" && std::string(update_restart_line()) == "reboot",
        "the install and restart lines");
  check(update_mode_code("auto") == 0 && update_mode_code("manual") == 1 && update_mode_code("x") == -1 &&
            update_mode_name(0) == "auto" && update_mode_name(1) == "manual" && update_mode_name(-1).empty(),
        "the mode codes");

  puts("== the lines on the FIFO of tsx-panelctl ==");
  std::string fifo = std::string(argv[1]) + "/panelctl", err;
  check(!fifo_send_line(fifo, update_install_line(), err) && !err.empty(), "no FIFO: the send fails with a reason");
  mkfifo(fifo.c_str(), 0600);
  check(!fifo_send_line(fifo, update_install_line(), err), "no reader: the send fails and does not wait");
  int rd = open(fifo.c_str(), O_RDONLY | O_NONBLOCK);
  const std::string lines[] = {update_install_line(), update_mode_line("manual"), auto_restart_line(false),
                               update_restart_line()};
  bool all = true;
  for (const auto &l : lines)
    all = fifo_send_line(fifo, l, err) && all;
  char buf[256];
  ssize_t got = read(rd, buf, sizeof buf - 1);
  close(rd);
  buf[got < 0 ? 0 : got] = '\0';
  check(all && std::string(buf) == "update-install\nupdate-mode manual\nauto-restart off\nreboot\n",
        "the four lines arrive in order");

  puts("== the hold after a set ==");
  HeldValue h;
  check(h.shown(1, 0) == 1 && h.shown(-1, 0) == -1 && !h.active(0), "no set: the file value shows");
  h.set(0, 1000);
  check(h.active(1000) && h.shown(1, 1010) == 0, "after a set to 0 the panel shows 0 while the file says 1");
  check(h.shown(-1, 1500) == 0, "also while the file is not known");
  check(h.shown(0, 2000) == 0 && h.held == -1 && !h.active(2000), "the file shows 0: the hold ends");
  check(h.shown(1, 2100) == 1, "then a later change of the file shows at once");
  h.set(1, 5000);
  check(h.shown(0, 14999) == 1 && h.active(14999), "the hold lasts up to 10 s");
  check(h.shown(0, 15000) == 0 && !h.active(15000), "after 10 s with no change the file value shows again");
  HeldValue w;
  w.set(1, 0xFFFFFF00u);
  check(w.active(0xFFFFFF10u) && w.shown(0, 0xFFFFFF10u) == 1 && w.shown(0, 0x00002C00u) == 0,
        "the hold works across the wrap of millis()");

  puts("== the install hold ==");
  UpdateStatus a;
  parse_update_state("installed 0.3.5\nlatest 0.3.6\nin-progress no\n", a);
  check(update_shown_state(a, false) == UPD_AVAILABLE, "available, no install sent");
  check(update_shown_state(a, true) == UPD_INSTALLING, "available, install sent: installing at once");
  UpdateStatus nu;
  parse_update_state("installed 0.3.5\nlatest 0.3.5\n", nu);
  check(update_shown_state(nu, true) == UPD_NO_UPDATE, "no update: the hold changes nothing");
  UpdateStatus un;
  parse_update_state("", un);
  check(update_shown_state(un, true) == UPD_UNKNOWN, "unknown: the hold changes nothing");
  HeldValue inst;
  inst.set(1, 100);
  int shown = inst.shown(a.in_progress, 200);
  check(shown == 1 && a.in_progress != 1, "install hold: the file says no, the hold says yes");
  parse_update_state("installed 0.3.5\nlatest 0.3.6\nin-progress yes\n", a);
  shown = inst.shown(a.in_progress, 300);
  check(shown == 1 && a.in_progress == 1 && inst.held == -1 && a.state() == UPD_INSTALLING,
        "the file says in-progress yes: the hold ends, the file state is installing");
  printf("== test-panel-app-update: %d ok, %d failed ==\n", n, f);
  return f ? 1 : 0;
}
C
"$CXX" -std=gnu++17 -Wall -Wextra -Werror -O1 -I"$SRC" -o "$T/upd" "$T/main.cpp" || { echo "FAIL: compile"; exit 1; }
"$T/upd" "$T"
