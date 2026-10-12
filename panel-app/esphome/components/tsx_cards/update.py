"""The tsx_cards update platform: the entity "Update" of the panel app.

    update:
      - platform: tsx_cards
        name: Update
        icon: mdi:package-up
        device_class: firmware

ESPHome has no template update platform. This entity shows the state file of
tsx-autoupdate (/run/tsx/update.state). Install sends update-install to
tsx-panelctl. See docs/panel-app.md, "Updates".
"""

import esphome.codegen as cg
from esphome.components import update
import esphome.config_validation as cv

from . import TsxCards, tsx_cards_ns

CONF_TSX_CARDS_ID = "tsx_cards_id"

DEPENDENCIES = ["tsx_cards"]

TsxUpdate = tsx_cards_ns.class_("TsxUpdate", update.UpdateEntity, cg.PollingComponent)

CONFIG_SCHEMA = (
    update.update_schema(TsxUpdate)
    .extend({cv.GenerateID(CONF_TSX_CARDS_ID): cv.use_id(TsxCards)})
    .extend(cv.polling_component_schema("2s"))
)


async def to_code(config):
    var = await update.new_update(config)
    await cg.register_component(var, config)
    parent = await cg.get_variable(config[CONF_TSX_CARDS_ID])
    cg.add(var.set_parent(parent))
