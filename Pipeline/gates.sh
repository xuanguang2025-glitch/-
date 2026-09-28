# Pipeline/gates.sh - every numeric threshold in one place.
# Values are the measured state of this machine (RTX 5060 Laptop, 1280x720, Quality=高),
# set loose enough that normal variance does not cry wolf and tight enough that the
# regressions already found here would have been caught:
#   * a 4x-understated profiler once hid a 46 ms chunk build
#   * a chunk-node origin bug displaced every rendered chunk
MAX_CHUNK_BUILD_MS=25     # measured 17.9 ms; the 7 ms frame budget is still unmet (BUG-002)
MAX_STREAM_MS=30000       # measured ~15 s for 289 chunks; Phase 37 test 1 asks 30 s
MAX_CHUNKS_ALIVE_THRESHOLD=250
STRESS_OBJECTS=1000       # Phase 37 test 3
BOOT_ERRORS_ALLOWED=0
FILE_MAX_LINES=900
export FILE_MAX_LINES
