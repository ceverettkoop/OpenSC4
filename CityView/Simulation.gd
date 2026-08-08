extends RefCounted

# The game clock, and the registry of simulation systems that run on it.
#
# SC4's field simulators (pollution, land value, crime...) run on a MONTHLY
# cadence, so a month is the unit here: step() advances whole months and runs
# every system whose cadence divides the new month index. Systems run in
# REGISTRATION order, which is load-bearing -- land value reads the pollution
# field, crime reads land value -- so City registers them pollution first.
#
# Two ways to drive it:
#   - interactively, City._process calls advance(delta) and the speed setting
#     (SPEED_PAUSED / SPEED_NORMAL / SPEED_FAST) turns wall time into months;
#   - headless, harnesses call step() directly. Checks must NEVER depend on
#     frame time, which is why the clock starts PAUSED: nothing moves unless
#     someone asks it to.
class_name Simulation

signal month_ticked(month : int)

const SPEED_PAUSED : int = 0
const SPEED_NORMAL : int = 1
const SPEED_FAST : int = 3

# Wall seconds per simulated month at SPEED_NORMAL. Big enough to watch the
# fields breathe without the city aging away under the camera.
const SECONDS_PER_MONTH : float = 5.0

var month : int = 0              # months since the save was loaded
var speed : int = SPEED_PAUSED
var _accumulator : float = 0.0
var _systems : Array = []        # of {"name": String, "callable": Callable, "cadence": int}

func add_system(system_name : String, callable : Callable, cadence_months : int = 1) -> void:
    _systems.append({
        "name": system_name,
        "callable": callable,
        "cadence": maxi(1, cadence_months),
    })

func system_names() -> Array:
    var out : Array = []
    for s in _systems:
        out.append(s["name"])
    return out

# Advances the clock by whole months and runs the due systems, in order.
func step(months : int = 1) -> void:
    for _i in range(months):
        month += 1
        for s in _systems:
            if month % s["cadence"] == 0:
                s["callable"].call(month)
        month_ticked.emit(month)

# Interactive driver: wall time -> months at the current speed setting.
func advance(delta : float) -> void:
    if speed == SPEED_PAUSED:
        return
    _accumulator += delta * speed
    while _accumulator >= SECONDS_PER_MONTH:
        _accumulator -= SECONDS_PER_MONTH
        step()

# Pause -> normal -> fast -> pause. Returns the new speed for the HUD.
func cycle_speed() -> int:
    match speed:
        SPEED_PAUSED:
            speed = SPEED_NORMAL
        SPEED_NORMAL:
            speed = SPEED_FAST
        _:
            speed = SPEED_PAUSED
    return speed
