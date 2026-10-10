import esphome.codegen as cg
from esphome.components import touchscreen
import esphome.config_validation as cv
from esphome.const import CONF_ID

from .. import CONF_TSX_EVDEV_ID, TsxEvdev, tsx_evdev_ns

DEPENDENCIES = ["tsx_evdev"]

TsxEvdevTouchscreen = tsx_evdev_ns.class_(
    "TsxEvdevTouchscreen", touchscreen.Touchscreen
)

# The input device reports each touch change at once (the poll interval of
# the schema is only a fallback).
CONFIG_SCHEMA = touchscreen.TOUCHSCREEN_SCHEMA.extend(
    {
        cv.GenerateID(): cv.declare_id(TsxEvdevTouchscreen),
        cv.GenerateID(CONF_TSX_EVDEV_ID): cv.use_id(TsxEvdev),
    }
)


async def to_code(config) -> None:
    var = cg.new_Pvariable(config[CONF_ID])
    await touchscreen.register_touchscreen(var, config)
    await cg.register_parented(var, config[CONF_TSX_EVDEV_ID])
