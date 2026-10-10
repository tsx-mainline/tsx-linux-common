// parity.cpp: run the layout parser of the app (tsx_cards/layout.cpp) on a
// file and print the result in the form of parity.py. For
// tests/test-layout-parity.sh only.
#include <cstdio>
#include <string>
#include <vector>

#include "layout.h"

using namespace esphome::tsx_cards;

int main(int argc, char **argv) {
  if (argc != 2)
    return 2;
  FILE *f = fopen(argv[1], "rb");
  if (f == nullptr)
    return 2;
  std::string text;
  char buf[4096];
  size_t n;
  while ((n = fread(buf, 1, sizeof buf, f)) > 0)
    text.append(buf, n);
  fclose(f);
  Layout l;
  std::string error;
  std::vector<std::string> warnings;
  bool ok = parse_layout(text, l, error, warnings);
  for (const auto &w : warnings)
    printf("warning: %s\n", w.c_str());
  if (!ok) {
    printf("error: %s\n", error.c_str());
    return 0;
  }
  for (size_t p = 0; p < l.pages.size(); p++)
    for (const auto &c : l.pages[p].cards)
      printf("card %d %s %d %d %d %d\n", (int) p + 1, card_type_name(c.type), c.x, c.y, c.w, c.h);
  return 0;
}
