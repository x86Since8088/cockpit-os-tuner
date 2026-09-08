#!/usr/bin/env python3
"""deploy.sh --verify's negative .env probe. Dev-tree only; never deployed.

Loads the DEPLOYED tuner-snapshot.py as a module and asks it, using its own
parser, which TUNER_HISTORY_DIR it resolves through the DEPLOYED install.conf.
deploy.sh has meanwhile planted an obviously wrong value in the checkout's
.env, so a "booby-trap" in the answer means the deployed consumer reached back
into the dev tree - the exact failure section 4.3 exists to prevent.

Prints one of: CLEAN <value> | LEAK <value> | INCONCLUSIVE <why>
"""
import importlib.util
import sys

try:
    spec = importlib.util.spec_from_file_location("snap", sys.argv[1])
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    env_file = mod.load_env(sys.argv[2]).get("ENV_FILE")
    if not env_file:
        print("INCONCLUSIVE install.conf sets no ENV_FILE")
        raise SystemExit(2)
    got = mod.load_env(env_file).get("TUNER_HISTORY_DIR", "")
except SystemExit:
    raise
except Exception as e:                                   # noqa: BLE001
    print("INCONCLUSIVE %s: %s" % (type(e).__name__, e))
    raise SystemExit(2)

print(("LEAK " if "booby-trap" in got else "CLEAN ") + got)
