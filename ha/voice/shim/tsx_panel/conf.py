"""conf: the layers of the settings files (kiosk.conf, buttons.conf, ...).

This module loads tsx_conf of tsx-base, the one reader of the layers: the
package defaults, the board file, the user file in /etc and the runtime file
in /run/tsx. A later layer wins. The shell version is conf.sh and the C version
is tsx-conf.h, in the same package. On the panel, tsx_conf is in
/usr/local/lib/tsx (TSX_BASE_LIB_DIR replaces it). A checkout has it in base/.
"""

import os
import sys

for _lib in (os.environ.get("TSX_BASE_LIB_DIR", "/usr/local/lib/tsx"),
             os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "..", "..", "..",
                          "base", "usr", "local", "lib", "tsx")):
    if _lib not in sys.path:
        sys.path.append(_lib)

import tsx_conf  # noqa: E402  pylint: disable=wrong-import-position,unused-import

get = tsx_conf.get
load = tsx_conf.load
layers = tsx_conf.layers
