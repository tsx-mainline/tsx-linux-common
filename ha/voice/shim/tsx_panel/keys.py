"""Fixed entity keys for the ESPHome device of the panel (docs/esphome.md).

The key of an entity is the FNV-1a hash (32 bit) of a fixed text:
"tsx:<object_id>" for a panel entity, "tsx:action:<name>" for an LED bar
action and "lva:<object_id>" for an own entity of the voice satellite. An
entity has the same key in tsx-esphome and in the voice satellite, and in
each version. The order of the entities and the optional entities do not
change a key.

Why: Home Assistant identifies an entity by its unique id
({mac}/{device_id}/{platform}/{name} since 2026.8). When a listed entity has a
new unique id, Home Assistant 2026.9 and later also look at its key. If an
entity that is gone had this key, the new entity gets the entity registry
entry of the old entity (homeassistant/components/esphome/entity.py,
async_static_info_updated). Earlier versions pair the entities by the key
only. With counted keys (0, 1, 2, ...) a change of VOICE moved the keys. Home
Assistant then gave the entity IDs and names of satellite entities to panel
entities.

No key is below MIN_KEY. These keys stay free for code that counts keys from
0. The voice satellite gives a new entity the next number until
fix_satellite_keys() gives it its fixed key. The rule also keeps out the key
0. If a key is in use (a hash collision), the entity gets the hash of
"<text>#1", "<text>#2" and so on, and the log shows a warning.
tests/test-shim-keys.sh fails on a collision of the known entities.
"""

import logging

_LOGGER = logging.getLogger("tsx_panel.keys")

PANEL = "tsx"
SATELLITE = "lva"
MIN_KEY = 0x10000
_FNV_OFFSET = 0x811C9DC5
_FNV_PRIME = 0x01000193


def fnv1a32(text: str) -> int:
    value = _FNV_OFFSET
    for byte in text.encode("utf-8"):
        value = ((value ^ byte) * _FNV_PRIME) & 0xFFFFFFFF
    return value


def candidates(text: str):
    """The keys for `text`, best first: the hash of the text, then the hashes
    of "<text>#1", "<text>#2", ... Never a key below MIN_KEY."""
    n = 0
    while True:
        key = fnv1a32(text if n == 0 else f"{text}#{n}")
        if key >= MIN_KEY:
            yield key
        n += 1


def stable_key(ident: str, namespace: str = PANEL) -> int:
    """The fixed key of one identity when no other key is in use."""
    return next(candidates(f"{namespace}:{ident}"))


class Keys:
    """Gives the keys of one device. `taken`: keys that other entities
    already use. Call it with the object id of an entity, or use action()
    for a user-defined action."""

    def __init__(self, namespace: str = PANEL, taken=()):
        self.namespace = namespace
        self.used = {key: None for key in taken}  # key -> identity (None: not ours)

    def __call__(self, ident: str) -> int:
        text = f"{self.namespace}:{ident}"
        for key in candidates(text):
            owner = self.used.get(key, text)
            if owner == text:
                self.used[key] = text
                return key
            _LOGGER.warning("%s: key %#010x is in use by %s. The entity gets the next key", text, key,
                            owner or "another entity")
        raise AssertionError("unreachable")

    def action(self, name: str) -> int:
        return self(f"action:{name}")


def keys_in_use(entities) -> list:
    """The keys of the entities and of their actions (ActionsEntity has no
    key of its own, only service_keys)."""
    used = []
    for entity in entities:
        if hasattr(entity, "key"):
            used.append(entity.key)
        used.extend(getattr(entity, "service_keys", ()))
    return used


def is_satellite_entity(entity) -> bool:
    """An own entity of the voice satellite (a class of
    linux_voice_assistant), not an entity of the panel. PanelLight is a
    subclass of LEDLightEntity, but its class is in tsx_panel."""
    return type(entity).__module__.split(".")[0] == "linux_voice_assistant"


def fix_satellite_keys(entities) -> None:
    """Give the own entities of the voice satellite the fixed key of
    "lva:<object_id>". The satellite counts its keys (key=len(state.entities)),
    so its keys move with each new entity or version. Run this after each
    place where the satellite adds entities. It is safe to run it again: an
    entity keeps its key. The entities of the panel keep their keys."""
    satellite = sorted((e for e in entities if is_satellite_entity(e)), key=lambda e: e.object_id)
    keys = Keys(SATELLITE, taken=keys_in_use(e for e in entities if not is_satellite_entity(e)))
    for entity in satellite:
        entity.key = keys(entity.object_id)
