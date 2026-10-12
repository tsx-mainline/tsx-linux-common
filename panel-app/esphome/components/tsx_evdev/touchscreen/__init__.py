import esphome.codegen as cg
from esphome.components import touchscreen
import esphome.config_validation as cv
from esphome.const import CONF_ID

from .. import CONF_TSX_EVDEV_ID, TsxEvdev, tsx_evdev_ns

DEPENDENCIES = ["tsx_evdev"]

TsxEvdevTouchscreen = tsx_evdev_ns.class_(
    "TsxEvdevTouchscreen", touchscreen.Touchscreen
)

# The input device reports each touch change at once: tsx_evdev sets the
# touched flag in its loop. So the touchscreen needs no poll. The default
# poll of the touchscreen schema (50 ms) only woke the main loop 20 times a
# second, also with the screen off. update_interval can still set one.
CONFIG_SCHEMA = touchscreen.TOUCHSCREEN_SCHEMA.extend(
    {
        cv.GenerateID(): cv.declare_id(TsxEvdevTouchscreen),
        cv.GenerateID(CONF_TSX_EVDEV_ID): cv.use_id(TsxEvdev),
    }
).extend(cv.polling_component_schema("never"))


async def to_code(config) -> None:
    var = cg.new_Pvariable(config[CONF_ID])
    await touchscreen.register_touchscreen(var, config)
    await cg.register_parented(var, config[CONF_TSX_EVDEV_ID])
