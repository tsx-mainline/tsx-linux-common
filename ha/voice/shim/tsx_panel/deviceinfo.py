"""The identity of the ESPHome device, the same in both front ends.

Home Assistant builds the device page (manufacturer, model, software
version) from the DeviceInfoResponse at each connection. If tsx-esphome
(VOICE=off) and the voice satellite (VOICE=on) report different values, the
page changes with each change of VOICE. linux-voice-assistant reports its own
project, manufacturer and model. So both front ends call apply() on their
response. Only the voice feature flags differ (esphome_server.py,
voice_feature_flags).

Home Assistant shows the part before the "." of project_name as the
manufacturer and the part after it as the model (esphome/manager.py,
async_get_manufacturer_model). The fields manufacturer and model are used only
when project_name is empty.
"""

from .backend import board_call, board_value, esphome_model

PROJECT_NAME = "tsx-mainline.tsx-esphome"
MANUFACTURER = "Crestron (mainline Linux)"

_MODEL = None


def model() -> str:
    """The model of the panel: "<family> panel" on a board that gives only its
    family name, "Crestron <model>" on a board that gives the model of the
    unit (backend.esphome_model)."""
    global _MODEL  # noqa: PLW0603
    if _MODEL is None:
        _MODEL = esphome_model(board_call("tsx_board_ha_model"), board_value("TSX_HA_MODEL")) or "panel"
    return _MODEL


def apply(response):
    """Set the project, versions, manufacturer and model of a DeviceInfoResponse."""
    from linux_voice_assistant.util import get_esphome_version, get_version  # noqa: WPS433 (the host tests stub the package)

    response.project_name = PROJECT_NAME
    response.project_version = get_version()
    response.esphome_version = get_esphome_version()
    response.manufacturer = MANUFACTURER
    response.model = model()
    return response
