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

      input_id: panel_input         # tsx_evdev: the five-finger tap, no tap with two fingers or more
      panel_lights: [light_left, light_right]  # the lights of the key action "lights"
      key_events:                   # the Home Assistant event entity of each key
        power: key_power_event
      backlight: auto               # a folder in /sys/class/backlight, or auto
      dim_timeout: 60s              # 0s = never (panel.conf DIM_TIMEOUT wins)
      blank_timeout: 300s           # 0s = never (panel.conf BLANK_TIMEOUT wins)
      dim_level: 30%                # panel.conf DIM_LEVEL wins
      overlay_timeout: 10s
      on_screen:                    # the screen goes on (on = true) or off
        - lambda: id(panel_display).set_power(on);
      screen_off_loop_interval: 0ms # the main loop interval while the screen is off (0ms = no change)

The CPU boost (CPUFREQ_BOOST_MS and CPUFREQ_SCREEN_OFF of panel-board.conf)
needs no YAML: see docs/panel-app.md, "CPU speed".

A key of the panel calls the component from a lambda, at each change:
    id(panel_cards).key_state("home", x);
"""

import esphome.codegen as cg
from esphome.components.lvgl.defines import add_lv_use
from esphome.components.lvgl.lv_validation import lv_font
from esphome.components.time import RealTimeClock
import esphome.config_validation as cv
from esphome import automation
from esphome.const import CONF_ID, CONF_TIME_ID

CODEOWNERS = []
DEPENDENCIES = ["lvgl", "api"]
AUTO_LOAD = ["json"]

CONF_LAYOUT_FILES = "layout_files"
CONF_PAGE_BAR_HEIGHT = "page_bar_height"
CONF_FONTS = "fonts"
CONF_SETUP_FILE = "setup_file"
CONF_ENTITIES_FILE = "entities_file"
CONF_INPUT_ID = "input_id"
CONF_PANEL_LIGHTS = "panel_lights"
CONF_KEY_EVENTS = "key_events"
CONF_BACKLIGHT = "backlight"
CONF_DIM_TIMEOUT = "dim_timeout"
CONF_BLANK_TIMEOUT = "blank_timeout"
CONF_DIM_LEVEL = "dim_level"
CONF_OVERLAY_TIMEOUT = "overlay_timeout"
CONF_ON_SCREEN = "on_screen"
CONF_OFF_LOOP_INTERVAL = "screen_off_loop_interval"

# The font slots of tsx_cards.h (enum FontSlot).
FONT_SLOTS = {"small": 0, "label": 1, "value": 2, "clock": 3, "icon": 4}

DEFAULT_LAYOUT_FILES = ["/var/lib/tsx/panel-layout.json", "/etc/tsx/panel-layout.json"]

tsx_cards_ns = cg.esphome_ns.namespace("tsx_cards")
TsxCards = tsx_cards_ns.class_("TsxCards", cg.Component)

# Optional parts of other components (ids only, so the build needs them only
# when the YAML names them).
TsxEvdev = cg.esphome_ns.namespace("tsx_evdev").class_("TsxEvdev", cg.Component)
LightState = cg.esphome_ns.namespace("light").class_("LightState", cg.EntityBase)
Event = cg.esphome_ns.namespace("event").class_("Event", cg.EntityBase)


def _lvgl_uses(config):
    # The LVGL widgets that the component makes at run time. ESPHome turns
    # on only the widgets that a configuration names.
    add_lv_use("label", "bar", "slider")
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
            cv.Optional(CONF_INPUT_ID): cv.use_id(TsxEvdev),
            cv.Optional(CONF_PANEL_LIGHTS, default=[]): cv.ensure_list(cv.use_id(LightState)),
            cv.Optional(CONF_KEY_EVENTS, default={}): cv.Schema(
                {cv.string_strict: cv.use_id(Event)}
            ),
            cv.Optional(CONF_BACKLIGHT, default="auto"): cv.string_strict,
            cv.Optional(CONF_DIM_TIMEOUT, default="60s"): cv.All(
                cv.positive_time_period_seconds, cv.Range(max=cv.TimePeriod(seconds=86400))
            ),
            cv.Optional(CONF_BLANK_TIMEOUT, default="300s"): cv.All(
                cv.positive_time_period_seconds, cv.Range(max=cv.TimePeriod(seconds=86400))
            ),
            cv.Optional(CONF_DIM_LEVEL, default="30%"): cv.All(cv.percentage_int, cv.Range(min=1)),
            cv.Optional(CONF_OVERLAY_TIMEOUT, default="10s"): cv.positive_time_period_milliseconds,
            cv.Optional(CONF_ON_SCREEN): automation.validate_automation({}),
            # The main loop interval while the screen is off (0ms: no
            # change). With input_id a touch or a key still ends the wait
            # at once.
            cv.Optional(CONF_OFF_LOOP_INTERVAL, default="0ms"): cv.All(
                cv.positive_time_period_milliseconds,
                cv.Range(max=cv.TimePeriod(milliseconds=1000)),
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
    if CONF_INPUT_ID in config:
        cg.add_define("USE_TSX_CARDS_INPUT")
        cg.add(var.set_input(await cg.get_variable(config[CONF_INPUT_ID])))
    for lamp in config[CONF_PANEL_LIGHTS]:
        cg.add(var.add_panel_light(await cg.get_variable(lamp)))
    for name, ev in config[CONF_KEY_EVENTS].items():
        cg.add(var.set_key_event(name, await cg.get_variable(ev)))
    cg.add(var.set_backlight_dir(config[CONF_BACKLIGHT]))
    cg.add(
        var.set_screen_defaults(
            config[CONF_DIM_TIMEOUT].total_seconds,
            config[CONF_BLANK_TIMEOUT].total_seconds,
            config[CONF_DIM_LEVEL],
        )
    )
    cg.add(var.set_overlay_timeout(config[CONF_OVERLAY_TIMEOUT].total_milliseconds))
    cg.add(var.set_off_loop_interval(config[CONF_OFF_LOOP_INTERVAL].total_milliseconds))
    for conf in config.get(CONF_ON_SCREEN, []):
        await automation.build_automation(var.get_screen_trigger(), [(bool, "on")], conf)
    # The component subscribes to states and sends actions itself, through
    # the api component.
    cg.add_define("USE_API_HOMEASSISTANT_STATES")
    cg.add_define("USE_API_HOMEASSISTANT_SERVICES")
