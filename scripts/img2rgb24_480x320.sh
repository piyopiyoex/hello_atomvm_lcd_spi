#!/usr/bin/env bash
set -Eeuo pipefail

# If invoked by /bin/sh or similar, re-run with bash for consistent behavior.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

# Colors (disabled when not a TTY; respects NO_COLOR)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_BOLD=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
fi

usage() {
  local script_name
  script_name="$(basename "$0")"

  cat <<EOF
Usage:
  ${script_name} INPUT_IMAGE [--fit|--stretch] [-o OUTPUT] [--bg COLOR]

Modes:
  --fit      Keep aspect ratio, letterbox with background color (default)
  --stretch  Force exact 480x320 (may distort)

Options:
  -o, --output PATH   Output file path (default: INPUT basename + .rgb)
  --bg COLOR          Background color for --fit padding (default: black)
  -h, --help          Show help

Notes:
  - Output is raw RGB888 (rgb24), 480x320, 460800 bytes.
EOF
}

die() {
  printf "%b✖%b %s\n" "${C_RED}${C_BOLD}" "${C_RESET}" "$*" >&2
  exit 1
}

say() {
  local msg="$*"

  case "${msg}" in
  "✔"*)
    printf "%b%s%b\n" "${C_GREEN}" "${msg}" "${C_RESET}"
    ;;
  "Next:"*)
    printf "%b%s%b\n" "${C_YELLOW}" "${msg}" "${C_RESET}"
    ;;
  *)
    printf "%s\n" "${msg}"
    ;;
  esac
}

run() {
  printf "%b+%b %s\n" "${C_CYAN}${C_BOLD}" "${C_RESET}" "$*"
  "$@"
}

require_cmd() {
  local cmd="$1"
  if command -v "${cmd}" >/dev/null 2>&1; then
    :
  else
    die "Missing dependency: ${cmd}"
  fi
}

stat_size_bytes() {
  local path="$1"

  if stat -c '%s' "${path}" >/dev/null 2>&1; then
    stat -c '%s' "${path}"
    return 0
  fi

  if stat -f '%z' "${path}" >/dev/null 2>&1; then
    stat -f '%z' "${path}"
    return 0
  fi

  return 1
}

main() {
  if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
    usage
    return 0
  fi

  local input="$1"
  shift

  [ -f "${input}" ] || die "Input file not found: ${input}"

  local mode="fit"
  local bg="black"
  local output=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --fit)
        mode="fit"
        shift
        ;;
      --stretch)
        mode="stretch"
        shift
        ;;
      --bg)
        [ $# -ge 2 ] || die "--bg requires a value"
        bg="$2"
        shift 2
        ;;
      -o|--output)
        [ $# -ge 2 ] || die "$1 requires a path"
        output="$2"
        shift 2
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        die "Unknown option: $1 (use --help)"
        ;;
    esac
  done

  if [ -z "${output}" ]; then
    local base
    base="$(basename "${input}")"
    base="${base%.*}"
    output="${base}.rgb"
  fi

  local vf_fit="scale=480:320:flags=lanczos:force_original_aspect_ratio=decrease,pad=480:320:(ow-iw)/2:(oh-ih)/2:color=${bg}"
  local vf_stretch="scale=480:320"
  local vf=""

  if [ "${mode}" = "fit" ]; then
    vf="${vf_fit}"
  else
    vf="${vf_stretch}"
  fi

  require_cmd ffmpeg

  say "Converting to raw RGB888 (480x320)…"
  run ffmpeg -y -i "${input}" \
    -vf "${vf}" \
    -f rawvideo -pix_fmt rgb24 "${output}"

  local expected_size=460800
  local actual_size=""

  if actual_size="$(stat_size_bytes "${output}")"; then
    :
  else
    die "Could not stat output size (verify manually): ${output}"
  fi

  if [ "${actual_size}" -ne "${expected_size}" ]; then
    die "Unexpected output size: ${actual_size} bytes (expected ${expected_size}) for ${output}"
  fi

  say "✔ wrote ${output} (${actual_size} bytes, mode=${mode})"
  say "Next: copy it to SD root as /foo.RGB (or replace priv/default.rgb)"
}

main "$@"
