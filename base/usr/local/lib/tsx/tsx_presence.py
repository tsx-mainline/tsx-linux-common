"""tsx_presence: the one rule that maps PRESENCE of /run/tsx/hw.conf to a
sensor kind. The shell version is presence-kind.sh in the same folder. Keep
both the same.

  no            no sensor
  tof           time-of-flight sensor: presence and distance
  pir           motion sensor: presence only
  yes, empty    tof (yes is the old name. A missing key means the part is there.)
  other         no, with a warning
"""

import logging

NO, TOF, PIR = "no", "tof", "pir"

_LOGGER = logging.getLogger("tsx.presence")


def kind(raw, warn=True):
    """The kind ("no", "tof" or "pir") for the raw value of PRESENCE."""
    raw = (raw or "").strip()
    if raw in ("tof", "yes", ""):
        return TOF
    if raw in (NO, PIR):
        return raw
    if warn:
        _LOGGER.warning("PRESENCE=%s in hw.conf is not no, tof, pir or yes. Treated as no.", raw)
    return NO


def has_presence(k):
    """The kind has a presence (motion) sensor."""
    return k in (TOF, PIR)


def has_distance(k):
    """The kind measures a distance."""
    return k == TOF
