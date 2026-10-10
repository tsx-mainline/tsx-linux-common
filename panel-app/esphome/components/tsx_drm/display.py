"""tsx_drm: an ESPHome display on a Linux DRM/KMS device, with no SDL.

The app draws into a RAM copy of the screen. The changed areas go to the back
one of two DRM dumb buffers, and a page flip shows it at the next vertical
blank. See docs/panel-accel.md.
"""

import esphome.codegen as cg
from esphome.components import display
from esphome.components.const import CONF_BYTE_ORDER
from esphome.components.snapshot import Snapshot, register_snapshot
import esphome.config_validation as cv
from esphome.const import (
    CONF_AUTO_CLEAR_ENABLED,
    CONF_ID,
    CONF_LAMBDA,
    CONF_UPDATE_INTERVAL,
    PLATFORM_HOST,
)
from esphome.types import ConfigType

AUTO_LOAD = ["snapshot"]

CONF_DEVICE = "device"
CONF_FLIP = "page_flip"

tsx_drm_ns = cg.esphome_ns.namespace("tsx_drm")
TsxDrm = tsx_drm_ns.class_("TsxDrm", display.Display, cg.Component, Snapshot)

CONFIG_SCHEMA = cv.All(
    display.FULL_DISPLAY_SCHEMA.extend(
        {
            cv.GenerateID(): cv.declare_id(TsxDrm),
            # Empty: the first /dev/dri/card* with a connected output.
            cv.Optional(CONF_DEVICE, default=""): cv.string,
            # false: one buffer and no flip (less memory traffic, the
            # screen can show a half-drawn area for one frame).
            cv.Optional(CONF_FLIP, default=True): cv.boolean,
            # The dumb buffer is RGB565 in the CPU byte order.
            cv.Optional(CONF_BYTE_ORDER, default="little_endian"): cv.one_of(
                "little_endian", lower=True
            ),
            cv.Optional(CONF_AUTO_CLEAR_ENABLED, default=False): cv.boolean,
            cv.Optional(CONF_UPDATE_INTERVAL, default="never"): cv.update_interval,
        }
    ),
    cv.only_on(PLATFORM_HOST),
)


async def to_code(config: ConfigType) -> None:
    var = cg.new_Pvariable(config[CONF_ID])
    await display.register_display(var, config)
    await register_snapshot(var, config)
    cg.add(var.set_device(config[CONF_DEVICE]))
    cg.add(var.set_page_flip(config[CONF_FLIP]))
    cg.add_build_flag("-I/usr/include/libdrm")
    cg.add_build_flag("-ldrm")
    if lamb := config.get(CONF_LAMBDA):
        lambda_ = await cg.process_lambda(
            lamb, [(display.DisplayRef, "it")], return_type=cg.void
        )
        cg.add(var.set_writer(lambda_))
