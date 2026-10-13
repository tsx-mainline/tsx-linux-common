"""The rate limit of the sensors that change often (docs/esphome.md, "Sensor rate").

A sensor that the panel reads every second, such as the CPU temperature,
would send a state to Home Assistant at each reading. Home Assistant stores
each state, and the database grows with no use. A Throttle decides, for each
reading, whether the sensor sends a state.

The rules, in this order:

1. The first value goes out at once.
2. A value goes out after at least MIN_INTERVAL seconds since the last state,
   and only when it differs from the last state that went out by more than
   the deadband of the sensor. The comparison is with the last state that
   went out, not with the last reading, so a slow drift also goes out.
3. A value that did not change enough goes out again after HEARTBEAT seconds
   with the same number (a heartbeat), so Home Assistant sees that the panel
   is alive and does not treat the sensor as stale.
4. A change between "no value" and a number counts as a change in rule 2.

The numbers are the constants below. They are the only place that has them.
tsx-mqtt (ha/usr/local/sbin/tsx-mqtt) uses the same numbers in its own
variables with the same names, and docs/esphome.md lists them. A sensor that
must stay fast (presence, touched recently, the keys, the screen, the volume
after a change by a user, the update and restart states) has no Throttle.
"""

import time

MIN_INTERVAL = 60.0    # seconds: at most one state for each sensor in this time
HEARTBEAT = 900.0      # seconds: a sensor that did not change sends its state again after this time

CPU_TEMP_DEADBAND = 1.0          # degrees Celsius
ILLUMINANCE_DEADBAND = 5.0       # lux. The larger of this and the relative part counts.
ILLUMINANCE_RELATIVE = 0.10      # 10 % of the last state that went out
DISTANCE_DEADBAND = 50.0         # millimeters

# The sensor "Last boot" is the wall clock minus the uptime. The two readings
# are never exact, so the value moves by a fraction of a second at each report.
# A new value counts only when it differs from the kept one by this many seconds
# (a reboot, or a step of the clock). The text does not change by a second.
BOOT_JITTER = 30.0


class Throttle:
    """One Throttle for each sensor. check() says what to do with a reading."""

    PUBLISH = "publish"      # a new value: send it
    REPEAT = "heartbeat"     # the old value again (the heartbeat): send it

    def __init__(self, deadband=0.0, relative=0.0, min_interval=MIN_INTERVAL,
                 heartbeat=HEARTBEAT, clock=time.monotonic):
        self.deadband, self.relative = float(deadband), float(relative)
        self.min_interval, self.heartbeat = float(min_interval), float(heartbeat)
        self._clock = clock
        self._have = False       # a state went out already
        self._value = None       # the last state that went out (None: no value)
        self._at = 0.0           # when it went out

    def threshold(self):
        """How far a value must be from the last state to count as changed."""
        if self._value is None:
            return 0.0
        return max(self.deadband, self.relative * abs(self._value))

    def check(self, value):
        """value: the reading (a number, or None for "no value"). Returns
        PUBLISH, REPEAT or None (send nothing). After PUBLISH or
        REPEAT the Throttle counts the value as sent."""
        now = self._clock()
        if not self._have:
            return self._sent(value, now, self.PUBLISH)
        age = now - self._at
        if age >= self.min_interval:
            if (value is None) != (self._value is None):
                return self._sent(value, now, self.PUBLISH)
            if value is not None and abs(value - self._value) > self.threshold():
                return self._sent(value, now, self.PUBLISH)
        if age >= self.heartbeat:
            return self._sent(self._value, now, self.REPEAT)
        return None

    def reset(self, value):
        """A subscriber asked for the state: the value goes out with that
        answer. Count it as sent."""
        self._sent(value, self._clock(), self.PUBLISH)

    def _sent(self, value, now, what):
        self._have, self._value, self._at = True, value, now
        return what
