"""The tsx_leds light platform.

    light:
      - platform: tsx_leds
        id: bar_left
        name: Light left              # for example
        led: rgb:status               # for example: a name in /sys/class/leds, or a path
        restore_mode: ALWAYS_OFF

A multicolor LED device (multi_index and multi_intensity) is an RGB light.
Each value of multi_intensity gets the red, green or blue part of the color
that multi_index names. A device with one color is a light with a
brightness only.
"""

import esphome.codegen as cg
from esphome.components import light
import esphome.config_validation as cv
from esphome.const import CONF_OUTPUT_ID, PLATFORM_HOST

CONF_LED = "led"

tsx_leds_ns = cg.esphome_ns.namespace("tsx_leds")
TsxLed = tsx_leds_ns.class_("TsxLed", light.LightOutput, cg.Component)

CONFIG_SCHEMA = cv.All(
    light.RGB_LIGHT_SCHEMA.extend(
        {
            cv.GenerateID(CONF_OUTPUT_ID): cv.declare_id(TsxLed),
            cv.Required(CONF_LED): cv.string_strict,
        }
    ).extend(cv.COMPONENT_SCHEMA),
    cv.only_on(PLATFORM_HOST),
)


async def to_code(config):
    var = cg.new_Pvariable(config[CONF_OUTPUT_ID])
    await cg.register_component(var, config)
    await light.register_light(var, config)
    led = config[CONF_LED]
    cg.add(var.set_path(led if led.startswith("/") else "/sys/class/leds/" + led))
