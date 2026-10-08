"""Exec a fixed decoder binary with Linux resource limits; no user-supplied commands."""
import os
import resource
import shutil
import sys

if len(sys.argv) < 2 or sys.argv[1] not in ('ffmpeg', 'ffprobe'):
    raise SystemExit(2)
binary = shutil.which(sys.argv[1])
if not binary:
    raise SystemExit(3)
os.umask(0o077)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
resource.setrlimit(resource.RLIMIT_CPU, (300, 300))
resource.setrlimit(resource.RLIMIT_FSIZE, (524288000, 524288000))
resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))
if sys.platform.startswith('linux'):
    resource.setrlimit(resource.RLIMIT_AS, (1073741824, 1073741824))
os.execv(binary, [binary, *sys.argv[2:]])
