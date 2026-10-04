#!/bin/bash
set -euo pipefail
set -a
source /etc/pressure_sensor/service.env
set +a
export PYTHONPATH=/opt/pressure_sensor/current/service:/opt/pressure_sensor/deps
export PYTHONDONTWRITEBYTECODE=1
exec /opt/mesemondo/venv/bin/python -m pressure.admin "$@"
