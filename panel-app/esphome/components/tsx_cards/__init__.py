"""tsx_cards: a Home Assistant card grid for LVGL, built at run time from a
JSON layout file. See docs/panel-app.md of tsx-linux-common.

    tsx_cards:
      id: panel_cards
      time_id: ha_time              # for the clock cards
      layout_files:                 # the first file that exists is used
        - /var/lib/tsx/panel-layout.json
        - /etc/tsx/panel-layout.json
      page_bar_height: 36           # 0 = no page bar
      setup_file: /run/tsx-setup/screen.json      # "" = no setup banner
      entities_file: /run/tsx/panel-app/entities.json  # "" = no entity list
      fonts:
        small: montserrat_16
        label: montserrat_20
        value: montserrat_28
        clock: montserrat_48
        icon: tsx_icon_font         # an ESPHome font with the glyphs of icon-glyphs.yaml

A key of the panel calls the component from a lambda:
    id(panel_cards).key_press("home");
"""

import esphome.codegen as cg
from esphome.components.lvgl.defines import add_lv_use
from esphome.components.lvgl.lv_validation import lv_font
from esphome.components.time import RealTimeClock
import esphome.config_validation as cv
from esphome.const import CONF_ID, CONF_TIME_ID

CODEOWNERS = []
DEPENDENCIES = ["lvgl", "api"]
AUTO_LOAD = ["json"]

CONF_LAYOUT_FILES = "layout_files"
CONF_PAGE_BAR_HEIGHT = "page_bar_height"
CONF_FONTS = "fonts"
CONF_SETUP_FILE = "setup_file"
CONF_ENTITIES_FILE = "entities_file"

# The font slots of tsx_cards.h (enum FontSlot).
FONT_SLOTS = {"small": 0, "label": 1, "value": 2, "clock": 3, "icon": 4}

DEFAULT_LAYOUT_FILES = ["/var/lib/tsx/panel-layout.json", "/etc/tsx/panel-layout.json"]

tsx_cards_ns = cg.esphome_ns.namespace("tsx_cards")
TsxCards = tsx_cards_ns.class_("TsxCards", cg.Component)


def _lvgl_uses(config):
    # The LVGL widgets that the component makes at run time. ESPHome turns
    # on only the widgets that a configuration names.
    add_lv_use("label")
    return config


CONFIG_SCHEMA = cv.All(
    cv.Schema(
        {
            cv.GenerateID(): cv.declare_id(TsxCards),
            cv.Optional(CONF_TIME_ID): cv.use_id(RealTimeClock),
            cv.Optional(CONF_LAYOUT_FILES, default=DEFAULT_LAYOUT_FILES): cv.All(
                cv.ensure_list(cv.string_strict), cv.Length(min=1)
            ),
            cv.Optional(CONF_PAGE_BAR_HEIGHT, default=36): cv.int_range(min=0, max=120),
            cv.Optional(CONF_SETUP_FILE, default="/run/tsx-setup/screen.json"): cv.string,
            cv.Optional(CONF_ENTITIES_FILE, default="/run/tsx/panel-app/entities.json"): cv.string,
            cv.Required(CONF_FONTS): cv.Schema(
                {cv.Optional(name): lv_font for name in FONT_SLOTS}
            ),
        }
    ).extend(cv.COMPONENT_SCHEMA),
    _lvgl_uses,
)


async def to_code(config):
    var = cg.new_Pvariable(config[CONF_ID])
    await cg.register_component(var, config)
    for path in config[CONF_LAYOUT_FILES]:
        cg.add(var.add_layout_file(path))
    cg.add(var.set_page_bar_height(config[CONF_PAGE_BAR_HEIGHT]))
    cg.add(var.set_setup_file(config[CONF_SETUP_FILE]))
    cg.add(var.set_entities_file(config[CONF_ENTITIES_FILE]))
    if CONF_TIME_ID in config:
        clock = await cg.get_variable(config[CONF_TIME_ID])
        cg.add(var.set_time(clock))
    for name, slot in FONT_SLOTS.items():
        if name in config[CONF_FONTS]:
            font = await lv_font.process(config[CONF_FONTS][name])
            cg.add(var.set_font(slot, font))
    # The component subscribes to states and sends actions itself, through
    # the api component.
    cg.add_define("USE_API_HOMEASSISTANT_STATES")
    cg.add_define("USE_API_HOMEASSISTANT_SERVICES")
