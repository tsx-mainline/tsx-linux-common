// layout.h: the panel layout model and its JSON parser.
// The format is in docs/panel-app.md. The rules here must agree with
// panel-app/usr/local/bin/tsx-layout-check (the reference checker).
#pragma once
#include <cstdint>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace esphome {
namespace tsx_cards {

enum class CardType { LIGHT, SWITCH, SCENE, SCRIPT, SENSOR, WEATHER, CLOCK };

const char *card_type_name(CardType t);

// What a tap on a card or a key press does.
struct ActionSpec {
  enum Kind { DEFAULT, NONE, CALL, PAGE, NEXT_PAGE, PREV_PAGE, SETUP };
  Kind kind{DEFAULT};
  std::string action;                                       // CALL: "domain.service"
  std::vector<std::pair<std::string, std::string>> data;    // CALL: data, as text
  int page{0};                                              // PAGE: 0-based page index
};

struct CardSpec {
  CardType type{CardType::SENSOR};
  std::string entity_id;
  std::string label;
  std::string icon;         // MDI name without "mdi:", or empty
  std::string attribute;    // sensor: show this attribute instead of the state
  std::string unit;         // sensor: unit text instead of unit_of_measurement
  std::string format;       // clock: strftime format of the time
  std::string date_format;  // clock: strftime format of the date ("" = no date)
  int precision{-1};        // sensor: decimals of a numeric value (-1 = as sent)
  int x{-1}, y{-1};         // cell of the top left corner, -1 = automatic
  int w{1}, h{1};           // size in cells
  int index{0};             // number of the card in its page (1 = first), for messages
  ActionSpec tap;
};

struct PageSpec {
  std::string name;
  int columns{4};
  int rows{3};
  std::vector<CardSpec> cards;
};

struct Theme {
  uint32_t background{0x101418};
  uint32_t card{0x2A3038};
  uint32_t card_on{0xC88A1E};
  uint32_t text{0xF0F0F0};
  uint32_t text_dim{0x9AA4B0};
};

struct Layout {
  int gap{10};
  Theme theme;
  std::vector<PageSpec> pages;
  std::map<std::string, ActionSpec> keys;  // key name -> action
};

// Limits of the format (the same in tsx-layout-check).
static const int MAX_PAGES = 16;
static const int MAX_CARDS = 48;  // per page
static const int MAX_GRID = 12;   // columns and rows of a page

// Parse a layout. Returns false and sets `error` when the file cannot be used
// at all. A card with an error is left out with a line in `warnings`. On
// success, every card has its cell (x, y): the cards with a cell are placed
// first, then the others fill the first free cells, row by row.
bool parse_layout(const std::string &text, Layout &out, std::string &error, std::vector<std::string> &warnings);

// "domain" of "domain.object_id".
std::string entity_domain(const std::string &entity_id);

}  // namespace tsx_cards
}  // namespace esphome
