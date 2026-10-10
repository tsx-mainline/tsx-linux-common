import esphome.codegen as cg
from esphome.components import binary_sensor
import esphome.config_validation as cv
from esphome.const import CONF_KEY
from esphome.cpp_generator import RawExpression

from . import CONF_TSX_EVDEV_ID, TsxEvdev, key_code

DEPENDENCIES = ["tsx_evdev"]

CONFIG_SCHEMA = binary_sensor.binary_sensor_schema().extend(
    {
        cv.GenerateID(CONF_TSX_EVDEV_ID): cv.use_id(TsxEvdev),
        cv.Required(CONF_KEY): key_code,
    }
)


async def to_code(config) -> None:
    var = await binary_sensor.new_binary_sensor(config)
    parent = await cg.get_variable(config[CONF_TSX_EVDEV_ID])
    key = config[CONF_KEY]
    code = key if isinstance(key, int) else RawExpression(key)
    cg.add(parent.add_key_sensor(code, var))
