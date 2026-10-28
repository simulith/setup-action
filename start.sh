#!/usr/bin/env bash
# Start Simulith for a GitHub Actions job.
# Usage: start.sh plan | start.sh start | start.sh self-test
set -euo pipefail

# Public release repo. The product repository stays private.
RELEASE_REPO="${SIMULITH_RELEASE_REPO:-simulith/setup-action}"

phase="${1:-start}"

goos() {
  case "${RUNNER_OS:-$(uname -s)}" in
    Linux|linux) echo linux ;;
    macOS|Darwin|darwin) echo darwin ;;
    Windows|MINGW*|MSYS*|CYGWIN*|windows) echo windows ;;
    *)
      echo "::error::unsupported OS: ${RUNNER_OS:-$(uname -s)}" >&2
      return 1
      ;;
  esac
}

goarch() {
  local arch="${RUNNER_ARCH:-$(uname -m)}"
  case "$arch" in
    X64|x86_64|amd64) echo amd64 ;;
    ARM64|aarch64|arm64) echo arm64 ;;
    *)
      echo "::error::unsupported arch: $arch" >&2
      return 1
      ;;
  esac
}

strip_v() {
  local v="$1"
  echo "${v#v}"
}

asset_name() {
  local ver_num="$1" os="$2" arch="$3"
  if [[ "$os" == "windows" ]]; then
    echo "simulith_${ver_num}_${os}_${arch}.zip"
  else
    echo "simulith_${ver_num}_${os}_${arch}.tar.gz"
  fi
}

bin_dir() {
  local root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  echo "${root}/simulith-bin"
}

# Archives, logs, and the pid stay out of bin_dir so actions/cache stores only the binary.
work_dir() {
  local root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  echo "${root}/simulith-work"
}

ensure_github_files() {
  if [[ -z "${GITHUB_OUTPUT:-}" ]]; then
    GITHUB_OUTPUT="$(mktemp)"
    export GITHUB_OUTPUT
  fi
  if [[ -z "${GITHUB_ENV:-}" ]]; then
    GITHUB_ENV="$(mktemp)"
    export GITHUB_ENV
  fi
}

write_output() {
  echo "${1}=${2}" >> "$GITHUB_OUTPUT"
}

resolve_tag() {
  local v="$1"
  if [[ "$v" != "latest" ]]; then
    if [[ "$v" == v* ]]; then
      echo "$v"
    else
      echo "v${v}"
    fi
    return
  fi
  if command -v gh >/dev/null 2>&1; then
    gh release view --repo "$RELEASE_REPO" --json tagName --jq .tagName
    return
  fi
  local auth=()
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -n "$token" ]]; then
    auth=(-H "Authorization: Bearer ${token}")
  fi
  local tag
  tag="$(curl -fsSL "${auth[@]}" "https://api.github.com/repos/${RELEASE_REPO}/releases/latest" \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' \
    | head -n 1)"
  if [[ -z "$tag" ]]; then
    echo "::error::Could not resolve the latest Simulith release" >&2
    return 1
  fi
  echo "$tag"
}

cmd_self_test() {
  [[ "$(strip_v v1.2.3)" == "1.2.3" ]]
  [[ "$(strip_v 1.2.3)" == "1.2.3" ]]
  [[ "$(asset_name 1.2.3 linux amd64)" == "simulith_1.2.3_linux_amd64.tar.gz" ]]
  [[ "$(asset_name 1.2.3 windows amd64)" == "simulith_1.2.3_windows_amd64.zip" ]]
  RUNNER_OS=Linux RUNNER_ARCH=X64
  [[ "$(goos)" == "linux" ]]
  [[ "$(goarch)" == "amd64" ]]
  RUNNER_OS=macOS RUNNER_ARCH=ARM64
  [[ "$(goos)" == "darwin" ]]
  [[ "$(goarch)" == "arm64" ]]
  RUNNER_OS=Windows RUNNER_ARCH=X64
  [[ "$(goos)" == "windows" ]]
  echo "self-test ok"
}

endpoint_url() {
  echo "http://127.0.0.1:${PORT}"
}

assert_port_free() {
  local url
  url="$(endpoint_url)"
  if curl -fsS --max-time 2 "${url}/health" >/dev/null 2>&1; then
    echo "::error::${url}/health is already responding. Choose another port input." >&2
    return 1
  fi
}

wait_health() {
  local url i
  url="$(endpoint_url)"
  for i in $(seq 1 "$TIMEOUT_SECONDS"); do
    if curl -fsS --max-time 2 "${url}/health" 2>/dev/null | grep -q '"status":"ok"'; then
      return 0
    fi
    sleep 1
  done
  echo "::error::Simulith did not become healthy at ${url}/health within ${TIMEOUT_SECONDS}s" >&2
  return 1
}

export_env() {
  local url
  url="$(endpoint_url)"
  write_output endpoint-url "$url"
  write_output container-name "${CONTAINER_NAME}"
  {
    echo "AWS_ACCESS_KEY_ID=test"
    echo "AWS_SECRET_ACCESS_KEY=test"
    echo "AWS_DEFAULT_REGION=${REGION}"
    echo "AWS_REGION=${REGION}"
    echo "AWS_ENDPOINT_URL=${url}"
    echo "AWS_EC2_METADATA_DISABLED=true"
    echo "SIMULITH_ENDPOINT=${url}"
  } >> "$GITHUB_ENV"
  if [[ "$MODE" == "binary" && -n "${GITHUB_PATH:-}" ]]; then
    echo "$(bin_dir)" >> "$GITHUB_PATH"
  fi
}

check_checksum() {
  local dir="$1" asset="$2"
  (
    cd "$dir"
    if command -v sha256sum >/dev/null 2>&1; then
      grep -E "  ${asset}$" checksums.txt | sha256sum -c -
    else
      grep -E "  ${asset}$" checksums.txt | shasum -a 256 -c -
    fi
  )
}

cmd_plan() {
  ensure_github_files
  if [[ "$MODE" == "docker" ]]; then
    write_output cache-key "docker-${IMAGE}-${VERSION}"
    write_output resolved-version "$VERSION"
    return
  fi
  if [[ "$MODE" != "binary" ]]; then
    echo "::error::mode must be docker or binary (got ${MODE})" >&2
    return 1
  fi
  local tag os arch ver_num asset
  tag="$(resolve_tag "$VERSION")"
  os="$(goos)"
  arch="$(goarch)"
  ver_num="$(strip_v "$tag")"
  asset="$(asset_name "$ver_num" "$os" "$arch")"
  write_output cache-key "$asset"
  write_output resolved-version "$tag"
  write_output asset "$asset"
}

cmd_start_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "::error::docker is required when mode=docker" >&2
    return 1
  fi
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  assert_port_free
  docker run -d --name "$CONTAINER_NAME" \
    -p "${PORT}:4566" \
    -e SIMULITH_HOST=0.0.0.0 \
    -e SIMULITH_PORT=4566 \
    "${IMAGE}:${VERSION}"
  if ! wait_health; then
    docker logs "$CONTAINER_NAME" || true
    return 1
  fi
  export_env
}

install_binary() {
  local dir work tag os arch ver_num asset url archive dest
  dir="$(bin_dir)"
  work="$(work_dir)"
  mkdir -p "$dir" "$work"
  dest="${dir}/simulith"
  if [[ "$(goos)" == "windows" ]]; then
    dest="${dir}/simulith.exe"
  fi
  if [[ -f "$dest" ]]; then
    echo "$dest"
    return
  fi
  tag="$(resolve_tag "$VERSION")"
  os="$(goos)"
  arch="$(goarch)"
  ver_num="$(strip_v "$tag")"
  asset="$(asset_name "$ver_num" "$os" "$arch")"
  url="https://github.com/${RELEASE_REPO}/releases/download/${tag}/${asset}"
  archive="${work}/${asset}"
  echo "Downloading ${url}" >&2
  if command -v gh >/dev/null 2>&1; then
    gh release download "$tag" --repo "$RELEASE_REPO" \
      --pattern "$asset" --pattern "checksums.txt" \
      --dir "$work" --clobber
  else
    local curl_auth=()
    local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    if [[ -n "$token" ]]; then
      curl_auth=(-H "Authorization: Bearer ${token}" -H "Accept: application/octet-stream")
    fi
    curl -fsSL "${curl_auth[@]}" -o "$archive" "$url"
    curl -fsSL "${curl_auth[@]}" -o "${work}/checksums.txt" \
      "https://github.com/${RELEASE_REPO}/releases/download/${tag}/checksums.txt"
  fi
  check_checksum "$work" "$asset" >&2
  local staging="${work}/extract"
  rm -rf "$staging"
  mkdir -p "$staging"
  if [[ "$asset" == *.zip ]]; then
    if command -v unzip >/dev/null 2>&1; then
      unzip -q -o "$archive" -d "$staging"
    else
      powershell.exe -NoProfile -Command "Expand-Archive -LiteralPath '$archive' -DestinationPath '$staging' -Force"
    fi
  else
    tar -xzf "$archive" -C "$staging"
  fi
  local found
  found="$(find "$staging" -type f \( -name simulith -o -name simulith.exe \) | head -n 1 || true)"
  if [[ -z "$found" ]]; then
    echo "::error::release archive ${asset} did not contain a simulith binary" >&2
    return 1
  fi
  cp "$found" "$dest"
  chmod +x "$dest" || true
  echo "$dest"
}

cmd_start_binary() {
  assert_port_free
  local bin dir
  bin="$(install_binary)" || return 1
  dir="$(work_dir)"
  mkdir -p "$dir"
  chmod +x "$bin" || true
  "$bin" start --host 127.0.0.1 --port "$PORT" >"${dir}/simulith.log" 2>&1 &
  echo $! >"${dir}/simulith.pid"
  if ! wait_health; then
    echo "---- simulith.log ----" >&2
    cat "${dir}/simulith.log" >&2 || true
    return 1
  fi
  export_env
}

cmd_start() {
  ensure_github_files
  case "$MODE" in
    docker) cmd_start_docker ;;
    binary) cmd_start_binary ;;
    *)
      echo "::error::mode must be docker or binary (got ${MODE})" >&2
      return 1
      ;;
  esac
}

case "$phase" in
  self-test) cmd_self_test ;;
  plan|start)
    MODE="${MODE:?MODE is required}"
    VERSION="${VERSION:-latest}"
    IMAGE="${IMAGE:-simulith/simulith}"
    PORT="${PORT:-4566}"
    REGION="${REGION:-us-east-1}"
    CONTAINER_NAME="${CONTAINER_NAME:-simulith}"
    TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-60}"
    if [[ ! "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 || "$PORT" -gt 65535 ]]; then
      echo "::error::port must be an integer from 1 to 65535" >&2
      exit 1
    fi
    if [[ "$phase" == "plan" ]]; then
      cmd_plan
    else
      cmd_start
    fi
    ;;
  *)
    echo "::error::usage: start.sh plan|start|self-test" >&2
    exit 1
    ;;
esac
