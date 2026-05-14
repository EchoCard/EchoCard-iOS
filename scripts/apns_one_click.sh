#!/usr/bin/env bash
set -euo pipefail

# iOS 仓一键 APNs（与主仓 tools/apns_one_click.sh 行为对齐）。
# 默认使用 Secrets/APNs/AuthKey_3B777RS7JC.p8；可用环境变量覆盖：
#   DEVICE_TOKEN=... TEAM_ID=... BUNDLE_ID=... P8_FILE=... APNS_ENV=prod scripts/apns_one_click.sh ...

KEY_ID="${KEY_ID:-3B777RS7JC}"
# 与 Config/*.xcconfig / Xcode DEVELOPMENT_TEAM 对齐；换团队时传入 TEAM_ID=xxx
TEAM_ID="${TEAM_ID:-Q322S2LD93}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
P8_FILE="${P8_FILE:-${REPO_ROOT}/Secrets/APNs/AuthKey_${KEY_ID}.p8}"
BUNDLE_ID="${BUNDLE_ID:-greater.longshu.CallMateTool}"
APNS_ENV="${APNS_ENV:-sandbox}" # sandbox | prod
DEVICE_TOKEN="${DEVICE_TOKEN:-}"

PY_SCRIPT="${SCRIPT_DIR}/apns_push.py"

usage() {
  cat <<'EOF'
Usage:
  # 须设置 DEVICE_TOKEN（Xcode 控制台 [APNS] didRegister 打印的 hex）
  DEVICE_TOKEN=<hex> scripts/apns_one_click.sh
  DEVICE_TOKEN=<hex> scripts/apns_one_click.sh incoming

  # 生产网关：APNS_ENV=prod
  DEVICE_TOKEN=<hex> APNS_ENV=prod scripts/apns_one_click.sh

  # 静默推送 event: command（默认 task.list）
  DEVICE_TOKEN=<hex> scripts/apns_one_click.sh command
  DEVICE_TOKEN=<hex> scripts/apns_one_click.sh command <request_id_suffix>

  # BLE 转发
  DEVICE_TOKEN=<hex> scripts/apns_one_click.sh ble <cmd> [json_params]

  # 拨号推送
  DEVICE_TOKEN=<hex> scripts/apns_one_click.sh dial <phone_number>
EOF
}

MODE="${1:-incoming}"

if [[ "${MODE}" == "-h" || "${MODE}" == "--help" || "${MODE}" == "help" ]]; then
  usage
  exit 0
fi

if [[ ! -f "${P8_FILE}" ]]; then
  echo "[ERROR] .p8 not found: ${P8_FILE}"
  echo "        Set P8_FILE=... or place AuthKey_${KEY_ID}.p8 under Secrets/APNs/"
  exit 1
fi

if [[ -z "${DEVICE_TOKEN}" ]]; then
  echo "[ERROR] DEVICE_TOKEN is empty. Export hex token from the device logs, e.g.:"
  echo "        DEVICE_TOKEN=abcd... scripts/apns_one_click.sh incoming"
  usage
  exit 1
fi

case "${MODE}" in
  command|cmd)
    REQ_SUFFIX="${2:-$(date +%s)}"
    TMP="$(mktemp -t apns_cmd.XXXXXX)"
    trap 'rm -f "${TMP}"' EXIT
    cat > "${TMP}" <<EOF
{
  "aps": {"content-available": 1},
  "event": "command",
  "request_id": "cli-${REQ_SUFFIX}",
  "action": "task.list",
  "params": {}
}
EOF
    COMMON_ARGS=(
      --device-token "${DEVICE_TOKEN}" \
      --team-id "${TEAM_ID}" \
      --key-id "${KEY_ID}" \
      --p8-file "${P8_FILE}" \
      --bundle-id "${BUNDLE_ID}"
    )
    if [[ "${APNS_ENV}" == "sandbox" ]]; then
      COMMON_ARGS+=(--sandbox)
    fi
    python3 "${PY_SCRIPT}" \
      "${COMMON_ARGS[@]}" \
      raw \
      --payload-file "${TMP}"
    ;;
  incoming)
    COMMON_ARGS=(
      --device-token "${DEVICE_TOKEN}" \
      --team-id "${TEAM_ID}" \
      --key-id "${KEY_ID}" \
      --p8-file "${P8_FILE}" \
      --bundle-id "${BUNDLE_ID}"
    )
    if [[ "${APNS_ENV}" == "sandbox" ]]; then
      COMMON_ARGS+=(--sandbox)
    fi
    python3 "${PY_SCRIPT}" \
      "${COMMON_ARGS[@]}" \
      incoming-call \
      --caller-name "测试来电" \
      --caller-number "13800138000" \
      --status-text "来电中" \
      --tts-text "一键脚本测试"
    ;;
  ble)
    CMD="${2:-}"
    PARAMS="${3:-{}}"
    if [[ -z "${CMD}" ]]; then
      echo "[ERROR] missing BLE cmd"
      usage
      exit 1
    fi
    COMMON_ARGS=(
      --device-token "${DEVICE_TOKEN}" \
      --team-id "${TEAM_ID}" \
      --key-id "${KEY_ID}" \
      --p8-file "${P8_FILE}" \
      --bundle-id "${BUNDLE_ID}"
    )
    if [[ "${APNS_ENV}" == "sandbox" ]]; then
      COMMON_ARGS+=(--sandbox)
    fi
    python3 "${PY_SCRIPT}" \
      "${COMMON_ARGS[@]}" \
      ble-forward \
      --ble-cmd "${CMD}" \
      --ble-params "${PARAMS}"
    ;;
  dial)
    PHONE="${2:-}"
    if [[ -z "${PHONE}" ]]; then
      echo "[ERROR] missing phone number"
      usage
      exit 1
    fi
    COMMON_ARGS=(
      --device-token "${DEVICE_TOKEN}" \
      --team-id "${TEAM_ID}" \
      --key-id "${KEY_ID}" \
      --p8-file "${P8_FILE}" \
      --bundle-id "${BUNDLE_ID}"
    )
    if [[ "${APNS_ENV}" == "sandbox" ]]; then
      COMMON_ARGS+=(--sandbox)
    fi
    python3 "${PY_SCRIPT}" \
      "${COMMON_ARGS[@]}" \
      dial-phone \
      --phone-number "${PHONE}"
    ;;
  *)
    echo "[ERROR] unknown mode: ${MODE}"
    usage
    exit 1
    ;;
esac
