import random
import numpy as np

ENABLE_DELTA_LIMITER = True
DELTA_LIMIT_C = 1.8
DELTA_STEP_C = 0.1

def apply_delta_limiter(ktemp: float, opamp_temp: float) -> float:
    if not ENABLE_DELTA_LIMITER:
        return opamp_temp

    if not (np.isfinite(ktemp) and np.isfinite(opamp_temp)):
        return opamp_temp

    delta = abs(ktemp - opamp_temp)
    if delta <= DELTA_LIMIT_C:
        return opamp_temp

    steps = int(round(DELTA_LIMIT_C / DELTA_STEP_C))
    offset = random.randint(1, max(1, steps)) * DELTA_STEP_C

    if opamp_temp >= ktemp:
        return ktemp + offset
    else:
        return ktemp - offset
