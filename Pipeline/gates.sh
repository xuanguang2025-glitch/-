# Pipeline/gates.sh - every numeric threshold in one place.
# Values are the measured state of this machine (RTX 5060 Laptop, 1280x720, Quality=高),
# set loose enough that normal variance does not cry wolf and tight enough that the
# regressions already found here would have been caught:
#   * a 4x-understated profiler once hid a 46 ms chunk build
#   * a chunk-node origin bug displaced every rendered chunk
#   * a one-shot sample reported 32.6 ms where the median is 17.8 ms, so perf gates take
#     the median of PERF_SAMPLES runs rather than trusting a single reading
#   * the city economy conserved every cent exactly while collapsing to the one-shop floor,
#     so conservation alone is not an acceptance criterion (SIM_SOAK_HOURS gates the outcome)
#   * a 2 % price step truncated to zero at small prices and left every price frozen forever
#   * require() once printed GATE-FAIL without touching the exit status, so an unparseable
#     metric could report PIPELINE: PASS one line under its own failure
#   * a newline-eating edit spliced a function signature onto its first statement; step 1
#     (`--editor --quit`) did NOT report it, because scripts that are never instantiated are
#     not parsed there. Step 2's headless boot is what actually gates compilation.
#   * killing run.sh left its Godot children and a game server on a 240 s self-exit timer
#     ticking at 30 Hz, and the identical build then read 66 ms instead of 9.9 ms. run.sh now
#     counts stray engine processes first and refuses to measure rather than reporting a
#     number that cannot be told apart from a regression.
#   * a median over 3 samples still reported 36.8 ms where 5 consecutive idle samples give
#     17.7-18.0 ms, so the timing gates take 5 samples: one contaminated run must not be able
#     to carry the median by itself
MAX_CHUNK_BUILD_MS=25     # median 17.9 ms; the 7 ms frame budget is still unmet (BUG-002)
PERF_SAMPLES=5            # median over this many runs for every timing gate
MAX_STREAM_MS=30000       # measured ~15 s for 289 chunks; Phase 37 test 1 asks 30 s
MAX_CHUNKS_ALIVE_THRESHOLD=250
STRESS_OBJECTS=1000       # Phase 37 test 3
# City simulation (Part 8). Soak measured 0.31 ms per simulated hour over 11 districts, so
# the limit is set where a 3x regression would still be caught rather than at the roundest
# number above the measurement.
SIM_SOAK_HOURS=8760       # one simulated year, ~2.7 s of wall clock
MAX_SIM_HOUR_MS=1.0
MIN_SIM_ASSERTS=25        # dropping an assertion must fail the gate, not quietly raise the average
MIN_MP_ASSERTS=16         # 10b: two real clients; replication rendered, economy server-owned
SIM_LIVE_MIN_HOURS=1      # a real session crossing an hour boundary must tick the economy
BOOT_ERRORS_ALLOWED=0
FILE_MAX_LINES=900
export FILE_MAX_LINES
