"""tsx_runtime: the identity and the API encryption key of the panel app at
run time. See docs/panel-app.md of tsx-linux-common, "Identity and API key".

    tsx_runtime:
      key_file: /run/tsx/esphome.key   # the default

One program serves every panel of a family. The component reads at start:
  - TSX_PANEL_APP_NAME, TSX_PANEL_APP_FRIENDLY_NAME (environment): the
    device name and the friendly name. Without them, the names of the
    configuration stay.
  - key_file: the API encryption key (32 bytes in base64, as `api:
    encryption: key:`). The component checks the file every 5 s and uses a
    new key at once. Without a valid key, it uses a random key: no client can
    connect.
The MAC comes from TSX_PANEL_APP_MAC through patches/host-mac.patch.

The configuration must give `api: encryption: key:` (a placeholder). It
makes ESPHome build the encrypted API with no plaintext fallback. The
component replaces the key before the API starts.
"""

import esphome.codegen as cg
import esphome.config_validation as cv
from esphome.const import CONF_ID
import esphome.final_validate as fv

DEPENDENCIES = ["api"]

CONF_KEY_FILE = "key_file"

tsx_runtime_ns = cg.esphome_ns.namespace("tsx_runtime")
TsxRuntime = tsx_runtime_ns.class_("TsxRuntime", cg.Component)

CONFIG_SCHEMA = cv.Schema(
    {
        cv.GenerateID(): cv.declare_id(TsxRuntime),
        cv.Optional(CONF_KEY_FILE, default="/run/tsx/esphome.key"): cv.string_strict,
    }
).extend(cv.COMPONENT_SCHEMA)


def _final_validate(config):
    api = fv.full_config.get().get("api") or {}
    enc = api.get("encryption")
    if not enc or not enc.get("key"):
        raise cv.Invalid(
            "tsx_runtime needs 'api: encryption: key:' (a placeholder key): "
            "without it, ESPHome builds an API with plaintext"
        )
    return config


FINAL_VALIDATE_SCHEMA = _final_validate


async def to_code(config):
    var = cg.new_Pvariable(config[CONF_ID])
    # Right after App.pre_setup(): no component has read the name yet.
    cg.add(var.apply_identity())
    cg.add(var.set_key_file(config[CONF_KEY_FILE]))
    await cg.register_component(var, config)
