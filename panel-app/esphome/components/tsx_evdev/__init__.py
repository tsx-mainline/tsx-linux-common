"""tsx_evdev: touch and keys from a Linux input device (evdev), with no SDL.

One `tsx_evdev:` entry opens one input device. The `tsx_evdev` touchscreen
and binary_sensor platforms read it. See docs/panel-accel.md.
"""

import esphome.codegen as cg
import esphome.config_validation as cv
from esphome.const import CONF_DEVICE, CONF_ID, CONF_NAME, PLATFORM_HOST

CONF_TAP_TIME = "tap_time"

CONF_TSX_EVDEV_ID = "tsx_evdev_id"

tsx_evdev_ns = cg.esphome_ns.namespace("tsx_evdev")
TsxEvdev = tsx_evdev_ns.class_("TsxEvdev", cg.Component)

CONFIG_SCHEMA = cv.All(
    cv.ensure_list(
        cv.All(
            cv.Schema(
                {
                    cv.GenerateID(): cv.declare_id(TsxEvdev),
                    # A path such as /dev/input/event0, or a part of the
                    # device name (cat /proc/bus/input/devices).
                    cv.Exclusive(CONF_DEVICE, "device"): cv.string,
                    cv.Exclusive(CONF_NAME, "device"): cv.string,
                    # A touch that ends within this time with no finger
                    # moved is a tap (take_tap(): the number of fingers).
                    cv.Optional(CONF_TAP_TIME, default="600ms"): cv.positive_time_period_milliseconds,
                }
            ).extend(cv.COMPONENT_SCHEMA),
            cv.has_exactly_one_key(CONF_DEVICE, CONF_NAME),
        )
    ),
    cv.only_on(PLATFORM_HOST),
)


async def to_code(config) -> None:
    for conf in config:
        var = cg.new_Pvariable(conf[CONF_ID])
        await cg.register_component(var, conf)
        if CONF_DEVICE in conf:
            cg.add(var.set_device(conf[CONF_DEVICE]))
        else:
            cg.add(var.set_name_match(conf[CONF_NAME]))
        cg.add(var.set_tap_time(conf[CONF_TAP_TIME]))


def key_code(value):
    """A key code: a number, or a name of linux/input-event-codes.h such as
    KEY_F13 or BTN_LEFT."""
    if isinstance(value, int):
        return cv.int_range(0, 0x2FF)(value)
    value = cv.string_strict(value).upper()
    if not value.replace("_", "").isalnum() or not value.startswith(("KEY_", "BTN_")):
        raise cv.Invalid("a key is a number or a name such as KEY_F13")
    return value
