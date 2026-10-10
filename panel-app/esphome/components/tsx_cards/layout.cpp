// layout.cpp: parse the JSON panel layout (format in docs/panel-app.md).
#include "layout.h"

#include <ArduinoJson.h>
#include <cstdio>
#include <cstring>

namespace esphome {
namespace tsx_cards {

namespace {

struct TypeName {
  const char *name;
  CardType type;
};
const TypeName TYPES[] = {
    {"light", CardType::LIGHT},   {"switch", CardType::SWITCH},   {"scene", CardType::SCENE},
    {"script", CardType::SCRIPT}, {"sensor", CardType::SENSOR},   {"weather", CardType::WEATHER},
    {"clock", CardType::CLOCK},
};

std::string fmt(const char *f, const std::string &a, const std::string &b = "") {
  char buf[256];
  snprintf(buf, sizeof buf, f, a.c_str(), b.c_str());
  return buf;
}

bool valid_id_part(const char *s, size_t n) {
  if (n == 0)
    return false;
  for (size_t i = 0; i < n; i++) {
    char c = s[i];
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'))
      return false;
  }
  return true;
}

// "domain.object_id": lowercase letters, digits and "_", one dot.
bool valid_entity_id(const std::string &e) {
  size_t dot = e.find('.');
  if (dot == std::string::npos)
    return false;
  return valid_id_part(e.c_str(), dot) && valid_id_part(e.c_str() + dot + 1, e.size() - dot - 1);
}

bool valid_icon(const std::string &s) {
  if (s.compare(0, 4, "mdi:") != 0 || s.size() == 4)
    return false;
  for (size_t i = 4; i < s.size(); i++) {
    char c = s[i];
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'))
      return false;
  }
  return true;
}

bool parse_color(JsonVariantConst v, uint32_t &out) {
  const char *s = v.as<const char *>();
  if (s == nullptr || s[0] != '#' || strlen(s) != 7)
    return false;
  uint32_t c = 0;
  for (int i = 1; i < 7; i++) {
    char ch = s[i];
    int d;
    if (ch >= '0' && ch <= '9')
      d = ch - '0';
    else if (ch >= 'a' && ch <= 'f')
      d = ch - 'a' + 10;
    else if (ch >= 'A' && ch <= 'F')
      d = ch - 'A' + 10;
    else
      return false;
    c = (c << 4) | d;
  }
  out = c;
  return true;
}

// An int in [lo, hi]. Returns false when the value is not such an int.
bool get_int(JsonVariantConst v, int lo, int hi, int &out) {
  if (!v.is<int>() || v.is<bool>())
    return false;
  int i = v.as<int>();
  if (i < lo || i > hi)
    return false;
  out = i;
  return true;
}

// The text form of a scalar data value: a string as is, a number or a bool
// as JSON text ("50", "1.5", "true").
bool scalar_text(JsonVariantConst v, std::string &out) {
  if (v.is<const char *>()) {
    out = v.as<const char *>();
    return true;
  }
  if (v.is<bool>() || v.is<int>() || v.is<float>() || v.is<double>()) {
    out.clear();
    serializeJson(v, out);
    return true;
  }
  return false;
}

// "domain.service"
bool valid_action_name(const std::string &a) { return valid_entity_id(a); }

// An action: "none", "default" (cards only), "next_page", "prev_page",
// "page:N", "setup" (keys only) or {"action": "domain.service", "data": {...}}.
bool parse_action(JsonVariantConst v, bool is_key, ActionSpec &out, std::string &err) {
  if (v.is<const char *>()) {
    std::string s = v.as<const char *>();
    if (s == "none") {
      out.kind = ActionSpec::NONE;
      return true;
    }
    if (!is_key && s == "default") {
      out.kind = ActionSpec::DEFAULT;
      return true;
    }
    if (is_key && s == "next_page") {
      out.kind = ActionSpec::NEXT_PAGE;
      return true;
    }
    if (is_key && s == "prev_page") {
      out.kind = ActionSpec::PREV_PAGE;
      return true;
    }
    if (is_key && s == "setup") {
      out.kind = ActionSpec::SETUP;
      return true;
    }
    if (is_key && s.compare(0, 5, "page:") == 0) {
      int n = atoi(s.c_str() + 5);
      if (n >= 1 && n <= MAX_PAGES && s.size() > 5 && s.find_first_not_of("0123456789", 5) == std::string::npos) {
        out.kind = ActionSpec::PAGE;
        out.page = n - 1;
        return true;
      }
    }
    err = fmt("unknown action \"%s\"", s);
    return false;
  }
  if (!v.is<JsonObjectConst>()) {
    err = "an action must be a text or an object";
    return false;
  }
  JsonObjectConst o = v.as<JsonObjectConst>();
  const char *a = o["action"].as<const char *>();
  if (a == nullptr || !valid_action_name(a)) {
    err = "an action object needs \"action\": \"domain.service\"";
    return false;
  }
  out.kind = ActionSpec::CALL;
  out.action = a;
  out.data.clear();
  for (JsonPairConst kv : o) {
    std::string k = kv.key().c_str();
    if (k == "action")
      continue;
    if (k != "data") {
      err = fmt("unknown key \"%s\" in an action", k);
      return false;
    }
    if (!kv.value().is<JsonObjectConst>()) {
      err = "\"data\" of an action must be an object";
      return false;
    }
    for (JsonPairConst d : kv.value().as<JsonObjectConst>()) {
      std::string text;
      if (!scalar_text(d.value(), text)) {
        err = fmt("data \"%s\" of an action must be a text, a number or true/false", d.key().c_str());
        return false;
      }
      out.data.emplace_back(d.key().c_str(), text);
    }
  }
  return true;
}

bool parse_card(JsonVariantConst v, const PageSpec &page, CardSpec &c, std::string &err,
                std::vector<std::string> &warnings, const std::string &where) {
  if (!v.is<JsonObjectConst>()) {
    err = "a card must be an object";
    return false;
  }
  JsonObjectConst o = v.as<JsonObjectConst>();
  const char *t = o["type"].as<const char *>();
  if (t == nullptr) {
    err = "no \"type\"";
    return false;
  }
  bool found = false;
  for (const auto &tn : TYPES) {
    if (strcmp(tn.name, t) == 0) {
      c.type = tn.type;
      found = true;
    }
  }
  if (!found) {
    err = fmt("unknown type \"%s\"", t);
    return false;
  }
  // The keys that each type accepts, after the common ones.
  static const char *const COMMON[] = {"type", "entity_id", "label", "icon", "x", "y", "w", "h", "tap"};
  for (JsonPairConst kv : o) {
    std::string k = kv.key().c_str();
    bool known = false;
    for (const char *ck : COMMON)
      known |= k == ck;
    if (c.type == CardType::SENSOR)
      known |= k == "attribute" || k == "unit" || k == "precision";
    if (c.type == CardType::CLOCK)
      known |= k == "format" || k == "date_format";
    if (!known)
      warnings.push_back(where + fmt(": unknown key \"%s\" (ignored)", k));
  }
  if (c.type != CardType::CLOCK) {
    const char *e = o["entity_id"].as<const char *>();
    if (e == nullptr || !valid_entity_id(e)) {
      err = "no valid \"entity_id\" (domain.object_id)";
      return false;
    }
    c.entity_id = e;
    std::string dom = entity_domain(c.entity_id);
    const char *need = nullptr;
    switch (c.type) {
      case CardType::LIGHT:
        need = "light";
        break;
      case CardType::SCENE:
        need = "scene";
        break;
      case CardType::SCRIPT:
        need = "script";
        break;
      case CardType::WEATHER:
        need = "weather";
        break;
      default:
        break;
    }
    if (need != nullptr && dom != need) {
      err = fmt("a %s card needs a %s entity", t, need);
      return false;
    }
  } else if (!o["entity_id"].isNull()) {
    warnings.push_back(where + ": a clock card has no entity_id (ignored)");
  }
  JsonVariantConst lv = o["label"];
  if (!lv.isNull()) {
    if (!lv.is<const char *>()) {
      err = "\"label\" must be a text";
      return false;
    }
    c.label = lv.as<const char *>();
  }
  JsonVariantConst iv = o["icon"];
  if (!iv.isNull()) {
    if (!iv.is<const char *>() || !valid_icon(iv.as<const char *>())) {
      err = "\"icon\" must be \"mdi:name\"";
      return false;
    }
    c.icon = iv.as<const char *>() + 4;
  }
  if (!o["w"].isNull() && !get_int(o["w"], 1, page.columns, c.w)) {
    err = "\"w\" must be 1 to the columns of the page";
    return false;
  }
  if (!o["h"].isNull() && !get_int(o["h"], 1, page.rows, c.h)) {
    err = "\"h\" must be 1 to the rows of the page";
    return false;
  }
  bool hx = !o["x"].isNull(), hy = !o["y"].isNull();
  if (hx != hy) {
    err = "give both \"x\" and \"y\", or none";
    return false;
  }
  if (hx) {
    if (!get_int(o["x"], 0, page.columns - 1, c.x) || !get_int(o["y"], 0, page.rows - 1, c.y)) {
      err = "\"x\" or \"y\" is outside the grid of the page";
      return false;
    }
    if (c.x + c.w > page.columns || c.y + c.h > page.rows) {
      err = "the card goes past the edge of the grid";
      return false;
    }
  }
  if (c.type == CardType::SENSOR) {
    JsonVariantConst a = o["attribute"], u = o["unit"], p = o["precision"];
    if (!a.isNull()) {
      if (!a.is<const char *>() || a.as<const char *>()[0] == '\0') {
        err = "\"attribute\" must be a text";
        return false;
      }
      c.attribute = a.as<const char *>();
    }
    if (!u.isNull()) {
      if (!u.is<const char *>()) {
        err = "\"unit\" must be a text";
        return false;
      }
      c.unit = u.as<const char *>();
    }
    if (!p.isNull() && !get_int(p, 0, 6, c.precision)) {
      err = "\"precision\" must be 0 to 6";
      return false;
    }
  }
  if (c.type == CardType::CLOCK) {
    c.format = "%H:%M";
    c.date_format = "%a %d %b";
    JsonVariantConst f = o["format"], d = o["date_format"];
    if (!f.isNull()) {
      if (!f.is<const char *>() || f.as<const char *>()[0] == '\0') {
        err = "\"format\" must be a text";
        return false;
      }
      c.format = f.as<const char *>();
    }
    if (!d.isNull()) {
      if (!d.is<const char *>()) {
        err = "\"date_format\" must be a text";
        return false;
      }
      c.date_format = d.as<const char *>();
    }
  }
  if (!o["tap"].isNull()) {
    std::string aerr;
    if (!parse_action(o["tap"], false, c.tap, aerr)) {
      err = "\"tap\": " + aerr;
      return false;
    }
  }
  return true;
}

// Place the cards of a page on its grid. Cards with x/y first, in order, then
// the others in the first free cell, row by row. A card that does not fit is
// removed with a warning.
void place_cards(PageSpec &page, std::vector<std::string> &warnings, const std::string &where) {
  std::vector<char> used(page.columns * page.rows, 0);
  auto free_at = [&](int x, int y, int w, int h) {
    for (int j = y; j < y + h; j++)
      for (int i = x; i < x + w; i++)
        if (used[j * page.columns + i])
          return false;
    return true;
  };
  auto take = [&](int x, int y, int w, int h) {
    for (int j = y; j < y + h; j++)
      for (int i = x; i < x + w; i++)
        used[j * page.columns + i] = 1;
  };
  std::vector<bool> keep(page.cards.size(), true);
  for (size_t n = 0; n < page.cards.size(); n++) {
    CardSpec &c = page.cards[n];
    if (c.x < 0)
      continue;
    if (!free_at(c.x, c.y, c.w, c.h)) {
      warnings.push_back(where + fmt(" card %s: overlaps an earlier card (left out)", std::to_string(c.index)));
      keep[n] = false;
      continue;
    }
    take(c.x, c.y, c.w, c.h);
  }
  for (size_t n = 0; n < page.cards.size(); n++) {
    CardSpec &c = page.cards[n];
    if (c.x >= 0 || !keep[n])
      continue;
    bool placed = false;
    for (int y = 0; y + c.h <= page.rows && !placed; y++) {
      for (int x = 0; x + c.w <= page.columns && !placed; x++) {
        if (free_at(x, y, c.w, c.h)) {
          c.x = x;
          c.y = y;
          take(x, y, c.w, c.h);
          placed = true;
        }
      }
    }
    if (!placed) {
      warnings.push_back(where + fmt(" card %s: no free place on the page (left out)", std::to_string(c.index)));
      keep[n] = false;
    }
  }
  std::vector<CardSpec> out;
  for (size_t n = 0; n < page.cards.size(); n++)
    if (keep[n])
      out.push_back(std::move(page.cards[n]));
  page.cards = std::move(out);
}

}  // namespace

const char *card_type_name(CardType t) {
  for (const auto &tn : TYPES)
    if (tn.type == t)
      return tn.name;
  return "?";
}

std::string entity_domain(const std::string &entity_id) { return entity_id.substr(0, entity_id.find('.')); }

bool parse_layout(const std::string &text, Layout &out, std::string &error, std::vector<std::string> &warnings) {
  out = Layout();
  JsonDocument doc;
  DeserializationError de = deserializeJson(doc, text.c_str(), text.size());
  if (de) {
    error = std::string("not valid JSON: ") + de.c_str();
    return false;
  }
  if (!doc.is<JsonObjectConst>()) {
    error = "the top level must be an object";
    return false;
  }
  JsonObjectConst root = doc.as<JsonObjectConst>();
  int version = 0;
  if (!get_int(root["version"], 1, 1000, version) || version != 1) {
    error = "\"version\" must be 1";
    return false;
  }
  for (JsonPairConst kv : root) {
    std::string k = kv.key().c_str();
    if (k != "version" && k != "grid" && k != "theme" && k != "keys" && k != "pages")
      warnings.push_back(fmt("unknown key \"%s\" (ignored)", k));
  }
  int def_cols = 4, def_rows = 3;
  JsonVariantConst grid = root["grid"];
  if (!grid.isNull()) {
    if (!grid.is<JsonObjectConst>()) {
      error = "\"grid\" must be an object";
      return false;
    }
    if ((!grid["columns"].isNull() && !get_int(grid["columns"], 1, MAX_GRID, def_cols)) ||
        (!grid["rows"].isNull() && !get_int(grid["rows"], 1, MAX_GRID, def_rows)) ||
        (!grid["gap"].isNull() && !get_int(grid["gap"], 0, 40, out.gap))) {
      error = "\"grid\": columns and rows must be 1 to 12, gap 0 to 40";
      return false;
    }
  }
  JsonVariantConst theme = root["theme"];
  if (!theme.isNull()) {
    if (!theme.is<JsonObjectConst>()) {
      error = "\"theme\" must be an object";
      return false;
    }
    for (JsonPairConst kv : theme.as<JsonObjectConst>()) {
      std::string k = kv.key().c_str();
      uint32_t *dst = k == "background" ? &out.theme.background
                      : k == "card"     ? &out.theme.card
                      : k == "card_on"  ? &out.theme.card_on
                      : k == "text"     ? &out.theme.text
                      : k == "text_dim" ? &out.theme.text_dim
                                        : nullptr;
      if (dst == nullptr) {
        warnings.push_back(fmt("theme: unknown key \"%s\" (ignored)", k));
        continue;
      }
      if (!parse_color(kv.value(), *dst)) {
        error = fmt("theme \"%s\" must be a color \"#RRGGBB\"", k);
        return false;
      }
    }
  }
  JsonVariantConst keys = root["keys"];
  if (!keys.isNull()) {
    if (!keys.is<JsonObjectConst>()) {
      error = "\"keys\" must be an object";
      return false;
    }
    for (JsonPairConst kv : keys.as<JsonObjectConst>()) {
      ActionSpec a;
      std::string aerr;
      if (!parse_action(kv.value(), true, a, aerr)) {
        error = fmt("key \"%s\": %s", kv.key().c_str(), aerr);
        return false;
      }
      out.keys[kv.key().c_str()] = a;
    }
  }
  JsonVariantConst pages = root["pages"];
  if (!pages.is<JsonArrayConst>() || pages.as<JsonArrayConst>().size() == 0) {
    error = "\"pages\" must be a list with one page or more";
    return false;
  }
  if (pages.as<JsonArrayConst>().size() > (size_t) MAX_PAGES) {
    error = "more than 16 pages";
    return false;
  }
  int pn = 0;
  for (JsonVariantConst pv : pages.as<JsonArrayConst>()) {
    pn++;
    std::string where = "page " + std::to_string(pn);
    if (!pv.is<JsonObjectConst>()) {
      error = where + ": a page must be an object";
      return false;
    }
    JsonObjectConst po = pv.as<JsonObjectConst>();
    PageSpec page;
    page.columns = def_cols;
    page.rows = def_rows;
    page.name = "Page " + std::to_string(pn);
    for (JsonPairConst kv : po) {
      std::string k = kv.key().c_str();
      if (k != "name" && k != "columns" && k != "rows" && k != "cards")
        warnings.push_back(where + fmt(": unknown key \"%s\" (ignored)", k));
    }
    if (!po["name"].isNull()) {
      if (!po["name"].is<const char *>()) {
        error = where + ": \"name\" must be a text";
        return false;
      }
      page.name = po["name"].as<const char *>();
    }
    if ((!po["columns"].isNull() && !get_int(po["columns"], 1, MAX_GRID, page.columns)) ||
        (!po["rows"].isNull() && !get_int(po["rows"], 1, MAX_GRID, page.rows))) {
      error = where + ": columns and rows must be 1 to 12";
      return false;
    }
    JsonVariantConst cards = po["cards"];
    if (!cards.isNull() && !cards.is<JsonArrayConst>()) {
      error = where + ": \"cards\" must be a list";
      return false;
    }
    if (cards.is<JsonArrayConst>() && cards.as<JsonArrayConst>().size() > (size_t) MAX_CARDS) {
      error = where + ": more than 48 cards";
      return false;
    }
    int cn = 0;
    for (JsonVariantConst cv : cards.as<JsonArrayConst>()) {
      cn++;
      std::string cwhere = where + " card " + std::to_string(cn);
      CardSpec c;
      c.index = cn;
      std::string cerr;
      if (!parse_card(cv, page, c, cerr, warnings, cwhere)) {
        warnings.push_back(cwhere + ": " + cerr + " (left out)");
        // Keep the place in the list, so the numbers in later warnings stay right.
        c.w = 0;
      }
      page.cards.push_back(std::move(c));
    }
    std::vector<CardSpec> valid;
    for (auto &c : page.cards)
      if (c.w > 0)
        valid.push_back(std::move(c));
    page.cards = std::move(valid);
    place_cards(page, warnings, where);
    out.pages.push_back(std::move(page));
  }
  return true;
}

}  // namespace tsx_cards
}  // namespace esphome
