#!/usr/bin/env bash
# Mihomo Manager: installation, systemd services, subscriptions and node selection.
#
# Source this file from ~/.bashrc or ~/.zshrc if you want `mhm proxy on/off` to affect
# the current shell:
#   source ~/.local/share/mihomo-sub.sh

# zsh can source the same file. Bash remains the backend; shell proxy changes
# are applied in the calling zsh rather than a child process.
if [ -n "${ZSH_VERSION-}" ] && [ -z "${BASH_VERSION-}" ]; then
  _MHM_ZSH_SCRIPT="${${(%):-%N}:A}"
  _mhm_zsh_run() {
    emulate -L zsh
    local mhm_zsh_key
    local -a mhm_zsh_environment=()
    for mhm_zsh_key in "${(@k)parameters}"; do
      if [[ "$mhm_zsh_key" == MIHOMO_* || "$mhm_zsh_key" == XDG_CONFIG_HOME || "$mhm_zsh_key" == XDG_CACHE_HOME ]]; then
        mhm_zsh_environment+=("$mhm_zsh_key=${(P)mhm_zsh_key}")
      fi
    done
    env "${mhm_zsh_environment[@]}" bash "$_MHM_ZSH_SCRIPT" "$@"
  }
  mhm() {
    emulate -L zsh
    local mhm_zsh_exports
    local -a mhm_zsh_scope=()
    while [[ "${1:-}" == --user || "${1:-}" == --system ]]; do
      mhm_zsh_scope+=("$1")
      shift
    done
    if [[ "${1:-}" == proxy || "${1:-}" == env ]]; then
      case "${2:-status}" in
        on)
          mhm_zsh_exports="$(_mhm_zsh_run "${mhm_zsh_scope[@]}" proxy env)" || return 1
          # The backend serializes these fixed export assignments using %q.
          eval "$mhm_zsh_exports"
          printf 'mhm: 当前 shell 已启用代理: %s\n' "$http_proxy"
          return 0 ;;
        off)
          unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
          printf 'mhm: 当前 shell 已关闭代理环境变量\n'
          return 0 ;;
      esac
    fi
    _mhm_zsh_run "${mhm_zsh_scope[@]}" "$@"
  }
  return 0
fi

# Capture explicit path overrides before applying scope defaults. Set overrides
# before sourcing; per-command defaults must never leak into the other scope.
if [[ "${_MHM_PATHS_INITIALIZED:-0}" != 1 ]]; then
  declare -gA _MHM_OVERRIDES=()
  for _mhm_var in MIHOMO_SUB_HOME MIHOMO_SUB_CACHE MIHOMO_CONFIG_TARGET \
    MIHOMO_DATA_DIR MIHOMO_BIN MIHOMO_UNIT_DIR MIHOMO_PROXY_PORT MIHOMO_CONTROLLER; do
    if [[ -n "${!_mhm_var:-}" ]]; then
      _MHM_OVERRIDES[$_mhm_var]="${!_mhm_var}"
    fi
  done
  unset _mhm_var
  _MHM_PATHS_INITIALIZED=1
fi
: "${MIHOMO_SCOPE:=user}"
: "${MIHOMO_SERVICE:=mihomo}"
: "${MIHOMO_PROXY_HOST:=127.0.0.1}"
: "${MIHOMO_CONTROLLER_SECRET:=}"
: "${MIHOMO_SUB_UA:=clash.meta}"
: "${MIHOMO_VALIDATE:=0}"
: "${MIHOMO_VALIDATE_TIMEOUT:=20}"
: "${MIHOMO_SUB_DIRECT:=1}"
# GitHub asset proxy used for Mihomo GEO downloads. Persisted setting overrides this default.
: "${MIHOMO_GH_PROXY_DEFAULT=https://gh-proxy.org/}"
: "${MIHOMO_GEO_MMDB_RAW:=https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb}"
: "${MIHOMO_GEOIP_RAW:=https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat}"
: "${MIHOMO_GEOSITE_RAW:=https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat}"
: "${MIHOMO_ASN_RAW:=https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb}"
: "${MIHOMO_READY_TIMEOUT:=12}"
: "${MIHOMO_RELEASE_ASSET:=}"
: "${MIHOMO_YQ_BIN:=yq}"
: "${MIHOMO_PYTHON_FALLBACK:=1}"
_MHM_SCRIPT_PATH="$(realpath -- "${BASH_SOURCE[0]}")"

_mhm_scope_paths() {
  local key
  case "$MIHOMO_SCOPE" in
    user)
      MIHOMO_SUB_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/mihomo-sub"
      MIHOMO_SUB_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/mihomo-sub"
      MIHOMO_CONFIG_TARGET="${XDG_CONFIG_HOME:-$HOME/.config}/mihomo/config.yaml"
      MIHOMO_BIN="$HOME/.local/bin/mihomo"
      MIHOMO_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
      MIHOMO_PROXY_PORT=7897
      MIHOMO_CONTROLLER=127.0.0.1:9090
      ;;
    system)
      MIHOMO_SUB_HOME=/etc/mihomo-sub
      MIHOMO_SUB_CACHE=/var/cache/mihomo-sub
      MIHOMO_CONFIG_TARGET=/etc/mihomo/config.yaml
      MIHOMO_BIN=/usr/local/bin/mihomo
      MIHOMO_UNIT_DIR=/etc/systemd/system
      MIHOMO_PROXY_PORT=7898
      MIHOMO_CONTROLLER=127.0.0.1:9091
      ;;
    *) _mhm_die "级别必须是 user 或 system"; return 1 ;;
  esac
  for key in "${!_MHM_OVERRIDES[@]}"; do
    printf -v "$key" '%s' "${_MHM_OVERRIDES[$key]}"
  done
  MIHOMO_DATA_DIR="${_MHM_OVERRIDES[MIHOMO_DATA_DIR]:-$(dirname "$MIHOMO_CONFIG_TARGET")}"
  _SUB_DIR="$MIHOMO_SUB_HOME/subscriptions"
  _PROFILE_DIR="$MIHOMO_SUB_CACHE/profiles"
  _ACTIVE_FILE="$MIHOMO_SUB_HOME/active"
  _GROUP_FILE="$MIHOMO_SUB_HOME/node-group"
  _GH_PROXY_FILE="$MIHOMO_SUB_HOME/gh-proxy"
  _UNIT_FILE="$MIHOMO_UNIT_DIR/${MIHOMO_SERVICE}.service"
  _INSTALL_FILE="$MIHOMO_SUB_HOME/install.json"
}

_mhm_die() { printf 'mhm: %s\n' "$*" >&2; return 1; }
_mhm_info() { printf 'mhm: %s\n' "$*"; }

_mhm_scope_paths

_mhm_owned_dir() {
  local dir="$1"
  if [[ ! -e "$dir" && ! -L "$dir" ]]; then
    mkdir -p -m 0700 -- "$dir" || return 1
    printf 'mihomo-sub:%s\n' "$MIHOMO_SCOPE" > "$dir/.mihomo-manager" || return 1
  fi
}

_mhm_init() {
  _mhm_owned_dir "$MIHOMO_SUB_HOME" || return 1
  _mhm_owned_dir "$MIHOMO_SUB_CACHE" || return 1
  mkdir -p "$_SUB_DIR" "$_PROFILE_DIR" || return 1
  chmod 700 "$MIHOMO_SUB_HOME" "$MIHOMO_SUB_CACHE" "$_SUB_DIR" "$_PROFILE_DIR" 2>/dev/null || true
}

_mhm_gh_proxy() {
  if [[ -f "$_GH_PROXY_FILE" ]]; then
    cat "$_GH_PROXY_FILE"
  else
    printf '%s\n' "$MIHOMO_GH_PROXY_DEFAULT"
  fi
}

_mhm_proxy_github_url() {
  local raw="$1" pfx
  pfx="$(_mhm_gh_proxy)" || return 1
  if [[ -z "$pfx" ]]; then printf '%s\n' "$raw"; return 0; fi
  [[ "$pfx" == https://* || "$pfx" == http://* ]] || \
    _mhm_die "GitHub 代理前缀必须是 HTTP(S) URL；使用 mhm gh-proxy off 可切换为直连" || return 1
  [[ "$pfx" != *$'\n'* && "$pfx" != *$'\r'* && "$pfx" != *'"'* && "$pfx" != *' '* ]] || \
    _mhm_die "GitHub 代理前缀格式无效" || return 1
  pfx="${pfx%/}"
  if [[ "$raw" == "$pfx/"* ]]; then printf '%s\n' "$raw"
  else printf '%s/%s\n' "$pfx" "$raw"; fi
}

_mhm_save_gh_proxy() {
  local value="$1" old_umask
  [[ -z "$value" || "$value" == http://* || "$value" == https://* ]] || _mhm_die "代理前缀必须为空或 HTTP(S) URL" || return 1
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *'"'* && "$value" != *' '* ]] || _mhm_die "代理前缀格式无效" || return 1
  old_umask="$(umask)"
  umask 077
  printf '%s\n' "$value" > "$_GH_PROXY_FILE" || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  chmod 600 "$_GH_PROXY_FILE" 2>/dev/null || true
}

_mhm_geo_mmdb_url() { _mhm_proxy_github_url "$MIHOMO_GEO_MMDB_RAW"; }
_mhm_geoip_url()    { _mhm_proxy_github_url "$MIHOMO_GEOIP_RAW"; }
_mhm_geosite_url()  { _mhm_proxy_github_url "$MIHOMO_GEOSITE_RAW"; }
_mhm_asn_url()      { _mhm_proxy_github_url "$MIHOMO_ASN_RAW"; }

_mhm_geo_file_ok() {
  local f="$MIHOMO_DATA_DIR/geoip.metadb"
  [[ -s "$f" ]] || return 1
  # A failed proxy/download often leaves an HTML/text stub. GEO DBs are comfortably larger than this.
  [[ $(wc -c < "$f" 2>/dev/null || echo 0) -gt 131072 ]] || return 1
  if LC_ALL=C head -c 256 "$f" 2>/dev/null | strings 2>/dev/null | grep -qiE '<!doctype|<html'; then
    return 1
  fi
  return 0
}

_mhm_geo_update() {
  local dst="$MIHOMO_DATA_DIR/geoip.metadb" tmp url
  command -v wget >/dev/null 2>&1 || _mhm_die "需要 wget" || return 1
  url="$(_mhm_geo_mmdb_url)" || return 1
  _mhm_owned_dir "$MIHOMO_DATA_DIR" || return 1
  tmp="${dst}.tmp.$$"
  _mhm_info "下载 GEO 数据: $url"
  if ! _mhm_github_download "$MIHOMO_GEO_MMDB_RAW" "$tmp"; then
    rm -f "$tmp"
    _mhm_die "GEO 数据下载失败"
    return 1
  fi
  if [[ $(wc -c < "$tmp" 2>/dev/null || echo 0) -le 131072 ]]; then
    rm -f "$tmp"
    _mhm_die "GEO 数据文件异常（文件过小）"
    return 1
  fi
  mv -f "$tmp" "$dst"
  chmod 644 "$dst" 2>/dev/null || true
  _mhm_info "已更新 GEO 数据: $dst ($(wc -c < "$dst") bytes)"
}

_mhm_ensure_geo() {
  _mhm_geo_file_ok && return 0
  _mhm_info "geoip.metadb 缺失或无效，先下载 GEO 数据"
  _mhm_geo_update
}

_mhm_valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
_mhm_check_name() {
  _mhm_valid_name "$1" || _mhm_die "名称只能包含字母、数字、点、下划线、短横线"
}
_mhm_url_file() {
  _mhm_check_name "$1" || return 1
  printf '%s/%s.url\n' "$_SUB_DIR" "$1"
}
_mhm_profile_file() {
  _mhm_check_name "$1" || return 1
  printf '%s/%s.yaml\n' "$_PROFILE_DIR" "$1"
}
_mhm_exists() { [[ -f "$(_mhm_url_file "$1")" ]]; }
_mhm_active() {
  local name
  [[ -f "$_ACTIVE_FILE" ]] || return 1
  name="$(cat "$_ACTIVE_FILE")" || return 1
  _mhm_check_name "$name" || return 1
  printf '%s\n' "$name"
}

_mhm_save_url() {
  local name="$1" url="$2" f old_umask rc
  f="$(_mhm_url_file "$name")" || return 1
  old_umask="$(umask)"
  umask 077
  printf '%s\n' "$url" > "$f"
  rc=$?
  umask "$old_umask"
  (( rc == 0 )) || return "$rc"
  chmod 600 "$f" 2>/dev/null || true
}

_mhm_read_url() { cat "$(_mhm_url_file "$1")"; }

_mhm_validate_profile() {
  local f="$1" rc log validated
  [[ -s "$f" ]] || _mhm_die "下载结果为空" || return 1

  if LC_ALL=C sed -e 's/^[[:space:]]*//' "$f" | head -n 1 | grep -qiE '^<!doctype html|^<html|^<'; then
    _mhm_die "下载结果看起来是 HTML，不是 Clash/Mihomo 配置"
    return 1
  fi

  if [[ "$MIHOMO_VALIDATE" == "1" ]] && command -v "$MIHOMO_BIN" >/dev/null 2>&1; then
    log="${f}.validate.log"
    validated="$(mktemp)" || return 1
    _mhm_render_runtime_config "$f" "$validated" || { rm -f -- "$validated"; return 1; }
    _mhm_info "完整校验配置（最多 ${MIHOMO_VALIDATE_TIMEOUT}s，数据目录: $MIHOMO_DATA_DIR）..."
    if command -v timeout >/dev/null 2>&1; then
      timeout "${MIHOMO_VALIDATE_TIMEOUT}s" "$MIHOMO_BIN" -t -d "$MIHOMO_DATA_DIR" -f "$validated" >"$log" 2>&1
      rc=$?
    else
      "$MIHOMO_BIN" -t -d "$MIHOMO_DATA_DIR" -f "$validated" >"$log" 2>&1
      rc=$?
    fi
    rm -f -- "$validated"
    if (( rc != 0 )); then
      cat "$log" >&2
      rm -f "$log"
      if (( rc == 124 )); then
        _mhm_die "mihomo -t 校验超时；未覆盖现有缓存"
      else
        _mhm_die "mihomo 配置校验失败；未覆盖现有缓存"
      fi
      return 1
    fi
    rm -f "$log"
  fi
}

_mhm_is_github_url() {
  local url="$1" authority host
  [[ "${url,,}" == http://* || "${url,,}" == https://* ]] || _mhm_die "订阅地址必须是 HTTP(S) URL" || return 1
  authority="${url#*://}"
  authority="${authority%%[/?#]*}"
  authority="${authority##*@}"
  [[ -n "$authority" ]] || _mhm_die "订阅 URL 缺少主机" || return 1
  if [[ "$authority" == \[* ]]; then host="${authority%%]*}]"; else host="${authority%%:*}"; fi
  host="${host,,}"
  case "${host%.}" in
    github.com|*.github.com|githubusercontent.com|*.githubusercontent.com|github.io|*.github.io|githubassets.com|*.githubassets.com) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

_mhm_download_subscription() {
  local url="$1" dst="$2" github metadata status redirect i
  command -v curl >/dev/null 2>&1 || _mhm_die "下载订阅需要 curl" || return 1
  # Follow redirects one hop at a time so even a non-GitHub subscription that
  # redirects to GitHub gets prefixed before the next request.
  for (( i=0; i<10; i++ )); do
    github="$(_mhm_is_github_url "$url")" || return 1
    if [[ "$github" == 1 ]]; then
      url="$(_mhm_proxy_github_url "$url")" || return 1
    fi
    local -a args=(--silent --show-error --fail --connect-timeout 20 --max-time 40
      --retry 1 --user-agent "$MIHOMO_SUB_UA" --output "$dst"
      --write-out $'%{http_code}\n%{redirect_url}\n')
    if [[ "$MIHOMO_SUB_DIRECT" == 1 || "$github" == 1 ]]; then args+=(--noproxy '*'); fi
    metadata="$(curl "${args[@]}" "$url")" || return 1
    status="${metadata%%$'\n'*}"
    redirect="${metadata#*$'\n'}"
    case "$status" in
      2??) return 0 ;;
      301|302|303|307|308)
        [[ -n "$redirect" ]] || _mhm_die "订阅重定向没有目标地址" || return 1
        url="$redirect" ;;
      *) _mhm_die "订阅下载返回 HTTP $status"; return 1 ;;
    esac
  done
  _mhm_die "订阅重定向次数过多"
}

_mhm_fetch() {
  local name="$1" url tmp dst
  _mhm_check_name "$name" || return 1
  _mhm_exists "$name" || _mhm_die "订阅不存在: $name" || return 1
  url="$(_mhm_read_url "$name")" || return 1
  dst="$(_mhm_profile_file "$name")" || return 1
  tmp="${dst}.tmp.$$"

  _mhm_info "下载订阅 $name ..."
  if ! _mhm_download_subscription "$url" "$tmp"; then
    rm -f "$tmp"
    _mhm_die "下载失败: $name"
    return 1
  fi

  _mhm_info "下载完成：$(wc -c < "$tmp") bytes"
  if ! _mhm_validate_profile "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$dst"
  chmod 600 "$dst" 2>/dev/null || true
  _mhm_info "已更新: $dst"
}

# Local machine settings should not be dictated by an airport subscription.
# Force one local mixed-port and a localhost controller whenever a profile is activated.
_mhm_need_jq() {
  command -v jq >/dev/null 2>&1 || _mhm_die "需要 jq 1.6+" || return 1
}

_mhm_yaml_json() (
  # JSON is already valid YAML. Only actual YAML input needs a YAML reader.
  set -o pipefail
  _mhm_need_jq || return 1
  local single='if length == 1 and (.[0] | type == "object") then .[0] else error("配置必须是单个映射文档") end'
  if jq -se "$single" "$1" 2>/dev/null; then return 0; fi
  local version
  if command -v "$MIHOMO_YQ_BIN" >/dev/null 2>&1; then
    version="$("$MIHOMO_YQ_BIN" --version 2>/dev/null)" || return 1
    [[ "$version" == *'version v4.'* ]] || _mhm_die "需要 mikefarah 原生 yq v4，不能使用 Python 版 yq" || return 1
    local -a options=(eval -o=json)
    # Older v4 releases do not have this flag; newer ones must use correct
    # merge-key precedence when expanding aliases.
    if "$MIHOMO_YQ_BIN" --help 2>/dev/null | grep -q -- '--yaml-fix-merge-anchor-to-spec'; then
      options+=(--yaml-fix-merge-anchor-to-spec=true)
    fi
    "$MIHOMO_YQ_BIN" "${options[@]}" 'explode(.)' "$1" | jq -se "$single"
  elif [[ "$MIHOMO_PYTHON_FALLBACK" == 1 ]] && command -v python3 >/dev/null 2>&1; then
    # Optional compatibility reader only. All configuration edits use jq.
    python3 - "$1" <<'PYYAML' | jq -se "$single"
import json, sys
try:
    import yaml
except ImportError:
    sys.exit('mhm: YAML 读取需要原生 yq v4，或可选的 PyYAML 模块')
try:
    with open(sys.argv[1], encoding='utf-8') as stream:
        config = yaml.safe_load(stream)
    if not isinstance(config, dict):
        raise ValueError('配置必须是单个映射文档')
    print(json.dumps(config, ensure_ascii=False, allow_nan=False))
except (OSError, ValueError, yaml.YAMLError) as exc:
    sys.exit(f'mhm: YAML 读取失败，请安装原生 yq v4: {exc}')
PYYAML
  else
    _mhm_die "读取 YAML 订阅需要原生 yq v4；JSON 配置无需 YAML 读取器"
  fi
)

_mhm_render_runtime_config() (
  set -o pipefail
  local src="$1" out="$2" mmdb geoip geosite asn pfx config
  _mhm_need_jq || return 1
  [[ "$MIHOMO_PROXY_PORT" =~ ^[0-9]{1,5}$ ]] || _mhm_die "端口必须是 1 到 65535 的整数" || return 1
  local port=$((10#$MIHOMO_PROXY_PORT))
  (( port >= 1 && port <= 65535 )) || _mhm_die "端口必须是 1 到 65535 的整数" || return 1
  mmdb="$(_mhm_geo_mmdb_url)" || return 1
  geoip="$(_mhm_geoip_url)" || return 1
  geosite="$(_mhm_geosite_url)" || return 1
  asn="$(_mhm_asn_url)" || return 1
  pfx="$(_mhm_gh_proxy)" || return 1
  config="$(_mhm_yaml_json "$src")" || return 1
  # Emit JSON (valid YAML) to escape all strings without another serializer.
  jq --argjson port "$port" --arg controller "$MIHOMO_CONTROLLER" \
    --arg secret "$MIHOMO_CONTROLLER_SECRET" --arg geoip "$geoip" \
    --arg geosite "$geosite" --arg mmdb "$mmdb" --arg asn "$asn" --arg prefix "${pfx%/}" '
    def github: test("^https?://([^/@]+@)?([A-Za-z0-9-]+\\.)*(github\\.com|githubusercontent\\.com|github\\.io|githubassets\\.com)\\.?(:[0-9]+)?([/?#]|$)"; "i");
    def url_value:
      walk(if type == "string" and $prefix != "" then
        if github and (startswith($prefix + "/") | not) then $prefix + "/" + . else . end
      else . end);
    del(.port, .["socks-port"], .["redir-port"], .["tproxy-port"], .listeners,
        .["external-controller-tls"], .["external-controller-unix"],
        .["external-controller-pipe"], .["geo-update-interval"])
    | .["allow-lan"] = false | .["bind-address"] = "127.0.0.1"
    | .["mixed-port"] = $port | .["external-controller"] = $controller
    | .secret = $secret | .["geo-auto-update"] = false
    | .["geox-url"] = {geoip: $geoip, geosite: $geosite, mmdb: $mmdb, asn: $asn}
    | walk(if type == "object" then with_entries(
        if (.key == "url" or .key == "urls" or .key == "geox-url" or (.key | test("-urls?$")))
        then .value |= url_value else . end) else . end)
  ' <<< "$config" > "$out"
)

_mhm_install_target() (
  # Stage both files before changing the runtime config. An unsuccessful commit
  # restores the previous config without depending on a writable install record.
  local staged_record staged_config="" rollback="" had_old=0 replaced=0 committed=0
  staged_record="$(mktemp "${_INSTALL_FILE}.tmp.XXXXXX")" || return 1
  trap '
    if (( replaced && ! committed )); then
      if (( had_old )); then
        if ! mv -f -- "$rollback" "$MIHOMO_CONFIG_TARGET"; then
          _mhm_die "恢复配置失败，原配置保留在: $rollback"
          rollback=""
        fi
      else
        rm -f -- "$MIHOMO_CONFIG_TARGET" || _mhm_die "无法移除未提交的配置"
      fi
    fi
    rm -f -- "$staged_record" "$staged_config"
    if [[ -n "$rollback" ]]; then rm -f -- "$rollback"; fi
  ' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  _mhm_artifact prepare config "$MIHOMO_CONFIG_TARGET" "$1" > "$staged_record" || return 1
  [[ ! -L "$MIHOMO_CONFIG_TARGET" && ( ! -e "$MIHOMO_CONFIG_TARGET" || -f "$MIHOMO_CONFIG_TARGET" ) ]] || \
    _mhm_die "配置目标必须是普通文件，不能是符号链接" || return 1
  mkdir -p -- "$(dirname "$MIHOMO_CONFIG_TARGET")" || return 1
  staged_config="$(mktemp "${MIHOMO_CONFIG_TARGET}.tmp.XXXXXX")" || return 1
  install -m 0600 -- "$1" "$staged_config" || return 1
  if [[ -e "$MIHOMO_CONFIG_TARGET" ]]; then
    rollback="$(mktemp "${MIHOMO_CONFIG_TARGET}.rollback.XXXXXX")" || return 1
    cp -p -- "$MIHOMO_CONFIG_TARGET" "$rollback" || return 1
    had_old=1
  fi
  mv -f -- "$staged_config" "$MIHOMO_CONFIG_TARGET" || return 1
  replaced=1
  mv -f -- "$staged_record" "$_INSTALL_FILE" || return 1
  committed=1
)

_mhm_copy_target() {
  local dst="$1"
  cp -- "$MIHOMO_CONFIG_TARGET" "$dst"
}

_mhm_remove_target() {
  rm -f -- "$MIHOMO_CONFIG_TARGET"
}

_mhm_systemctl() {
  if [[ "$MIHOMO_SCOPE" == user ]]; then
    systemctl --user "$@"
  else
    systemctl --system "$@"
  fi
}

_mhm_is_root() { [[ "$EUID" == 0 ]]; }

_mhm_service_exists() {
  local state
  command -v systemctl >/dev/null 2>&1 || return 1
  state="$(_mhm_systemctl show -p LoadState --value "${MIHOMO_SERVICE}.service" 2>/dev/null)" || return 1
  [[ -n "$state" && "$state" != "not-found" && "$state" != "error" ]]
}

_mhm_controller_url() {
  local c="$MIHOMO_CONTROLLER"
  if [[ "$c" == http://* || "$c" == https://* ]]; then
    printf '%s\n' "${c%/}"
    return
  fi
  # Config values like 0.0.0.0:9090 are listener addresses, not useful client destinations.
  c="${c/#0.0.0.0:/127.0.0.1:}"
  c="${c/#:/127.0.0.1:}"
  printf 'http://%s\n' "${c%/}"
}

_mhm_controller_secret() (
  set -o pipefail
  if [[ -n "$MIHOMO_CONTROLLER_SECRET" ]]; then
    printf '%s\n' "$MIHOMO_CONTROLLER_SECRET"
  elif [[ -r "$MIHOMO_CONFIG_TARGET" ]]; then
    _mhm_yaml_json "$MIHOMO_CONFIG_TARGET" | jq -r '
      (.secret // "") | if type == "string" then . else error("Controller 密钥必须是字符串") end'
  fi
)

_mhm_api() {
  local method="$1" path="$2" body="${3-}" base secret
  shift 3 2>/dev/null || true
  command -v curl >/dev/null 2>&1 || _mhm_die "节点管理需要 curl" || return 1
  base="$(_mhm_controller_url)"
  secret="$(_mhm_controller_secret)" || return 1
  local -a args=(--noproxy '*' -fsS --connect-timeout 2 --max-time 5 -X "$method")
  [[ -n "$secret" ]] && args+=(-H "Authorization: Bearer $secret")
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary "$body")
  fi
  curl "${args[@]}" "${base}${path}"
}

_mhm_api_proxies() {
  local out
  if ! out="$(_mhm_api GET /proxies '' 2>&1)"; then
    printf '%s\n' "$out" >&2
    _mhm_die "连不上 Mihomo Controller: $(_mhm_controller_url)。当前运行配置需包含 external-controller: $MIHOMO_CONTROLLER"
    return 1
  fi
  printf '%s' "$out"
}

_mhm_wait_ready() {
  local i loops
  loops=$(( MIHOMO_READY_TIMEOUT * 2 ))
  for ((i=0; i<loops; i++)); do
    if _mhm_api GET /version '' >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

_mhm_reload_runtime() {
  local body
  if command -v jq >/dev/null 2>&1; then
    body="$(jq -cn --arg path "$MIHOMO_CONFIG_TARGET" '{path: $path}')" || return 1
    if _mhm_api PUT '/configs?force=true' "$body" >/dev/null 2>&1; then
      if _mhm_wait_ready; then
        _mhm_info "已通过 Controller 热重载 Mihomo"
        return 0
      fi
      _mhm_info "Controller 热重载后未就绪，尝试重启服务..."
    fi
  fi

  if _mhm_service_exists; then
    if _mhm_systemctl restart "${MIHOMO_SERVICE}.service"; then
      if _mhm_wait_ready; then
        _mhm_info "已重启 ${MIHOMO_SERVICE}.service，Controller 已就绪"
        return 0
      fi
      _mhm_info "${MIHOMO_SERVICE}.service 已重启，但 ${MIHOMO_READY_TIMEOUT}s 内 Controller 未就绪"
      _mhm_systemctl status "${MIHOMO_SERVICE}.service" --no-pager -l 2>/dev/null || true
      return 1
    fi
    return 1
  fi

  _mhm_info "未检测到可用 Controller 或 ${MIHOMO_SERVICE}.service；配置已写入 $MIHOMO_CONFIG_TARGET"
  _mhm_info "若 Mihomo 由命令行启动，请按原启动方式重启并加载此配置"
  return 2
}

_mhm_activate_cached() {
  local name="$1" src backup rollback rendered had_old=0 reload_rc
  src="$(_mhm_profile_file "$name")" || return 1
  [[ -s "$src" ]] || _mhm_die "没有缓存配置；先运行: mhm update $name" || return 1

  backup="${MIHOMO_CONFIG_TARGET}.before-mihomo-sub"
  if [[ -e "$MIHOMO_CONFIG_TARGET" && ! -e "$backup" ]]; then
    install -m 0600 "$MIHOMO_CONFIG_TARGET" "$backup" || return 1
    _mhm_info "已备份原配置到 $backup"
  fi

  rollback="$(mktemp)" || return 1
  rendered="$(mktemp)" || { rm -f "$rollback"; return 1; }
  chmod 600 "$rollback" "$rendered" 2>/dev/null || true

  if [[ -e "$MIHOMO_CONFIG_TARGET" ]]; then
    _mhm_copy_target "$rollback" || { rm -f "$rollback" "$rendered"; return 1; }
    had_old=1
  fi

  _mhm_ensure_geo || { rm -f "$rollback" "$rendered"; return 1; }
  _mhm_render_runtime_config "$src" "$rendered" || { rm -f "$rollback" "$rendered"; return 1; }
  _mhm_install_target "$rendered" || { rm -f "$rollback" "$rendered"; return 1; }
  rm -f "$rendered"

  if _mhm_reload_runtime; then reload_rc=0; else reload_rc=$?; fi
  if (( reload_rc == 1 )); then
    _mhm_info "应用新配置失败，正在回滚..."
    if (( had_old )); then
      _mhm_install_target "$rollback" || true
      _mhm_reload_runtime >/dev/null 2>&1 || true
    else
      _mhm_remove_target
    fi
    rm -f "$rollback"
    _mhm_die "切换失败，已尝试恢复旧配置"
    return 1
  fi

  rm -f "$rollback"
  printf '%s\n' "$name" > "$_ACTIVE_FILE"
  chmod 600 "$_ACTIVE_FILE" 2>/dev/null || true
  _mhm_info "已切换到订阅: $name"
  _mhm_info "本机固定 mixed-port: $MIHOMO_PROXY_PORT；Controller: $MIHOMO_CONTROLLER"
}

_mhm_cmd_add() {
  local name="${1:-}" url="${2:-}"
  [[ -n "$name" && -n "$url" ]] || _mhm_die "用法: mhm add <名称> <订阅URL>" || return 1
  _mhm_check_name "$name" || return 1
  if _mhm_exists "$name"; then
    _mhm_die "订阅已存在: $name"
    return 1
  fi

  _mhm_save_url "$name" "$url" || return 1
  if ! _mhm_fetch "$name"; then
    rm -f "$(_mhm_url_file "$name")"
    return 1
  fi
  _mhm_info "已添加订阅: $name"
}

_mhm_cmd_set_url() {
  local name="${1:-}" url="${2:-}"
  [[ -n "$name" && -n "$url" ]] || _mhm_die "用法: mhm set-url <名称> <新URL>" || return 1
  _mhm_check_name "$name" || return 1
  _mhm_exists "$name" || _mhm_die "订阅不存在: $name" || return 1
  _mhm_save_url "$name" "$url" || return 1
  _mhm_info "已修改 $name 的订阅地址；运行 'mhm update $name' 拉取新配置"
}

_mhm_cmd_update() {
  local target="${1:-}" name active rc=0 f
  if [[ -z "$target" ]]; then
    target="$(_mhm_active)"
    [[ -n "$target" ]] || _mhm_die "没有当前订阅；指定名称或先 mhm use <名称>" || return 1
  fi

  active="$(_mhm_active)"
  if [[ "$target" == "all" || "$target" == "--all" ]]; then
    local files=()
    for f in "$_SUB_DIR"/*.url; do
      [[ -f "$f" ]] && files+=("$f")
    done
    ((${#files[@]})) || _mhm_die "还没有订阅" || return 1
    for f in "${files[@]}"; do
      name="${f##*/}"; name="${name%.url}"
      if _mhm_fetch "$name"; then
        if [[ "$name" == "$active" ]]; then
          _mhm_activate_cached "$name" || rc=1
        fi
      else
        rc=1
      fi
    done
    return "$rc"
  fi

  _mhm_check_name "$target" || return 1
  _mhm_fetch "$target" || return 1
  if [[ "$target" == "$active" ]]; then
    _mhm_activate_cached "$target" || return 1
  fi
  return 0
}

_mhm_cmd_use() {
  local name="${1:-}"
  [[ -n "$name" ]] || _mhm_die "用法: mhm use <名称>" || return 1
  _mhm_check_name "$name" || return 1
  _mhm_exists "$name" || _mhm_die "订阅不存在: $name" || return 1
  [[ -s "$(_mhm_profile_file "$name")" ]] || _mhm_fetch "$name" || return 1
  _mhm_activate_cached "$name"
}

_mhm_cmd_del() {
  local name="${1:-}" active
  [[ -n "$name" ]] || _mhm_die "用法: mhm del <名称>" || return 1
  _mhm_check_name "$name" || return 1
  _mhm_exists "$name" || _mhm_die "订阅不存在: $name" || return 1
  active="$(_mhm_active)"
  if [[ "$name" == "$active" ]]; then
    _mhm_die "不能删除当前订阅；先 mhm use <其他名称>"
    return 1
  fi
  rm -f "$(_mhm_url_file "$name")" "$(_mhm_profile_file "$name")"
  _mhm_info "已删除订阅: $name"
}

_mhm_cmd_ls() {
  local active name f
  active="$(_mhm_active)"
  printf '%-2s %-24s %-8s\n' '' 'NAME' 'CACHE'
  local files=()
  for f in "$_SUB_DIR"/*.url; do
    [[ -f "$f" ]] && files+=("$f")
  done
  if ((${#files[@]} == 0)); then
    printf '   (无订阅)\n'
    return 0
  fi
  for f in "${files[@]}"; do
    name="${f##*/}"; name="${name%.url}"
    if [[ "$name" == "$active" ]]; then printf '*  '; else printf '   '; fi
    printf '%-24s %-8s\n' "$name" "$([[ -s "$(_mhm_profile_file "$name")" ]] && echo yes || echo no)"
  done
}

_mhm_cmd_show() {
  local name="${1:-}" url
  [[ -n "$name" ]] || name="$(_mhm_active)"
  [[ -n "$name" ]] || _mhm_die "没有当前订阅" || return 1
  _mhm_check_name "$name" || return 1
  _mhm_exists "$name" || _mhm_die "订阅不存在: $name" || return 1
  url="$(_mhm_read_url "$name")"
  printf 'name: %s\n' "$name"
  printf 'url:  %s\n' "$url"
  printf 'file: %s\n' "$(_mhm_profile_file "$name")"
}

_mhm_cmd_gh_proxy() {
  local action="${1:-show}" value active
  case "$action" in
    show|status)
      value="$(_mhm_gh_proxy)"
      if [[ -n "$value" ]]; then
        printf '%s\n' "$value"
      else
        printf '(direct / no GitHub proxy)\n'
      fi
      ;;
    reset|default)
      _mhm_save_gh_proxy "$MIHOMO_GH_PROXY_DEFAULT" || return 1
      _mhm_info "GitHub 代理已恢复默认: $MIHOMO_GH_PROXY_DEFAULT"
      ;;
    off|direct|none)
      _mhm_save_gh_proxy "" || return 1
      _mhm_info "GitHub 代理前缀已清空，将直接访问 GitHub"
      ;;
    set)
      [[ $# -ge 2 ]] || _mhm_die "用法: mhm gh-proxy set <前缀URL|空字符串>" || return 1
      value="$2"
      _mhm_save_gh_proxy "$value" || return 1
      _mhm_info "GitHub 代理已设置为: $value"
      ;;
    http://*|https://*)
      _mhm_save_gh_proxy "$action" || return 1
      _mhm_info "GitHub 代理已设置为: $action"
      ;;
    *)
      _mhm_die "用法: mhm gh-proxy [show|set <URL>|reset|off]"
      return 1
      ;;
  esac

  # Re-render the active profile so future GEO downloads use the new prefix.
  case "$action" in
    show|status) return 0 ;;
  esac
  active="$(_mhm_active)"
  if [[ -n "$active" && -s "$(_mhm_profile_file "$active")" ]]; then
    _mhm_info "重新应用当前订阅以更新 geox-url: $active"
    _mhm_activate_cached "$active"
  fi
}

_mhm_cmd_geo() {
  case "${1:-status}" in
    status)
      printf 'GitHub proxy: %s\n' "$(_mhm_gh_proxy)"
      printf 'MMDB URL:     %s\n' "$(_mhm_geo_mmdb_url)"
      if _mhm_geo_file_ok; then
        printf 'geoip.metadb: OK (%s bytes)\n' "$(wc -c < "$MIHOMO_DATA_DIR/geoip.metadb")"
      else
        printf 'geoip.metadb: missing/invalid\n'
      fi
      ;;
    update|refresh) _mhm_geo_update ;;
    *) _mhm_die "用法: mhm geo {status|update}" ;;
  esac
}

# ----- Node / proxy-group management through Mihomo Controller -----

_mhm_pick_group() {
  local json="$1" preferred=""
  [[ ! -f "$_GROUP_FILE" ]] || preferred="$(cat "$_GROUP_FILE")"
  _mhm_need_jq || return 1
  jq -er --arg preferred "$preferred" '
    [.proxies | to_entries[] | select(.value.type == "Selector")] as $groups
    | if ($groups | length) == 0 then error("没有 Selector 组")
      elif any($groups[]; .key == $preferred) then $preferred
      else ([ ["节点选择","节点","手动","代理","proxy","select","global"][] as $hint
              | $groups[] | select(.key | ascii_downcase | contains($hint)) | .key ][0]
            // $groups[0].key) end' <<< "$json"
}

_mhm_node_groups() {
  local json selected line index=0 name current
  _mhm_need_jq || return 1
  json="$(_mhm_api_proxies)" || return 1
  selected="$(_mhm_pick_group "$json")" || selected=""
  local groups
  groups="$(jq -c '[.proxies | to_entries[] | select(.value.type == "Selector")]' <<< "$json")" || return 1
  if [[ "$groups" == '[]' ]]; then printf '(没有 Selector 组)\n'; return 0; fi
  while IFS= read -r line; do
    name="$(jq -r '.key' <<< "$line")" || return 1
    current="$(jq -r '.value.now // "?"' <<< "$line")" || return 1
    index=$((index + 1))
    if [[ "$name" == "$selected" ]]; then printf '* '; else printf '  '; fi
    printf '%2d. %s    当前: %s\n' "$index" "$name" "$current"
  done < <(jq -c '.[]' <<< "$groups")
}

_mhm_choose_name() {
  # stdin: array of group/node names. Numeric input is a one-based index.
  jq -er --arg target "$1" '
    if $target | test("^[0-9]+$") then
      ($target | tonumber) as $i
      | if $i >= 1 and $i <= length then .[$i - 1] else error("编号越界") end
    else if index($target) != null then $target else error("名称不存在") end end'
}

_mhm_node_set_group() {
  local target="${1:-}" json group names
  [[ -n "$target" ]] || _mhm_die "用法: mhm node group <编号|组名>" || return 1
  _mhm_need_jq || return 1
  json="$(_mhm_api_proxies)" || return 1
  names="$(jq -c '[.proxies | to_entries[] | select(.value.type == "Selector") | .key]' <<< "$json")" || return 1
  group="$(_mhm_choose_name "$target" <<< "$names")" || { _mhm_die "找不到 Selector 组: $target"; return 1; }
  printf '%s\n' "$group" > "$_GROUP_FILE" || return 1
  chmod 600 "$_GROUP_FILE" || return 1
  _mhm_info "节点选择组: $group"
  _mhm_node_list
}

_mhm_node_list() {
  local json group current nodes node index=0
  _mhm_need_jq || return 1
  json="$(_mhm_api_proxies)" || return 1
  group="$(_mhm_pick_group "$json")" || return 1
  current="$(jq -r --arg group "$group" '.proxies[$group].now // "?"' <<< "$json")" || return 1
  nodes="$(jq -c --arg group "$group" '.proxies[$group].all // []' <<< "$json")" || return 1
  printf '组:   %s\n当前: %s\n' "$group" "$current"
  while IFS= read -r node; do
    node="$(jq -r '.' <<< "$node")" || return 1
    index=$((index + 1))
    if [[ "$node" == "$current" ]]; then printf '* '; else printf '  '; fi
    printf '%3d. %s\n' "$index" "$node"
  done < <(jq -c '.[]' <<< "$nodes")
}

_mhm_node_current() {
  local json group
  _mhm_need_jq || return 1
  json="$(_mhm_api_proxies)" || return 1
  group="$(_mhm_pick_group "$json")" || return 1
  jq -r --arg group "$group" '$group + ": " + (.proxies[$group].now // "?")' <<< "$json"
}

_mhm_node_use() {
  local target="${1:-}" json group node enc_group body names
  [[ -n "$target" ]] || _mhm_die "用法: mhm node <编号|节点名>" || return 1
  _mhm_need_jq || return 1
  json="$(_mhm_api_proxies)" || return 1
  group="$(_mhm_pick_group "$json")" || return 1
  names="$(jq -c --arg group "$group" '.proxies[$group].all // []' <<< "$json")" || return 1
  node="$(_mhm_choose_name "$target" <<< "$names")" || { _mhm_die "找不到节点: $target"; return 1; }
  enc_group="$(jq -rn --arg group "$group" '$group | @uri')" || return 1
  body="$(jq -cn --arg node "$node" '{name: $node}')" || return 1
  _mhm_api PUT "/proxies/$enc_group" "$body" >/dev/null || { _mhm_die "切换节点失败"; return 1; }
  _mhm_info "已切换：$group -> $node"
}

_mhm_node_test() {
  local url="${1:-https://www.google.com/generate_204}"
  command -v curl >/dev/null 2>&1 || _mhm_die "需要 curl" || return 1
  _mhm_info "测试 http://${MIHOMO_PROXY_HOST}:${MIHOMO_PROXY_PORT} -> $url"
  curl --noproxy '' -x "http://${MIHOMO_PROXY_HOST}:${MIHOMO_PROXY_PORT}" \
    --connect-timeout 5 --max-time 12 -sS -o /dev/null \
    -w 'HTTP %{http_code}  connect=%{time_connect}s  TLS=%{time_appconnect}s  total=%{time_total}s\n' \
    "$url"
}

_mhm_cmd_node() {
  local sub="${1:-ls}"
  case "$sub" in
    ls|list) _mhm_node_list ;;
    current|now) _mhm_node_current ;;
    groups) _mhm_node_groups ;;
    group) shift; _mhm_node_set_group "${1:-}" ;;
    use|select) shift; _mhm_node_use "${1:-}" ;;
    test) shift; _mhm_node_test "${1:-}" ;;
    help|-h|--help)
      cat <<'NODEHELP'
节点与选择组:
  mhm node                      列出当前选择组的节点及编号
  mhm node 3                    切换到第 3 个节点
  mhm node use 3                按编号切换节点，与 mhm node 3 等效
  mhm node use '节点名'         按完整名称切换节点
  mhm node current              查看当前节点
  mhm node test [URL]            通过本级代理测试连接，默认使用 Google 204 地址
  mhm node groups               列出所有 Selector 组
  mhm node group 2              将第 2 个 Selector 组设为操作对象
  mhm node group '组名'         按完整组名选择操作对象

使用前需启动所选级别的 Mihomo，并在配置中提供 Selector 组。
节点和组的编号分别以 mhm node、mhm node groups 的输出为准。
NODEHELP
      ;;
    *)
      # Convenience shorthand: `mhm node 3` or `mhm node "节点名"`.
      _mhm_node_use "$sub"
      ;;
  esac
}

_mhm_is_sourced() { [[ "${BASH_SOURCE[0]}" != "$0" ]]; }

_mhm_proxy_on() {
  _mhm_is_sourced || {
    _mhm_die "要影响当前 shell，请先 source 本脚本，然后运行 mhm proxy on"
    return 1
  }
  local hp="http://${MIHOMO_PROXY_HOST}:${MIHOMO_PROXY_PORT}"
  local sp="socks5h://${MIHOMO_PROXY_HOST}:${MIHOMO_PROXY_PORT}"
  export http_proxy="$hp" https_proxy="$hp" all_proxy="$sp"
  export HTTP_PROXY="$hp" HTTPS_PROXY="$hp" ALL_PROXY="$sp"
  _mhm_info "当前 shell 已启用代理: $hp"
}

_mhm_proxy_off() {
  _mhm_is_sourced || {
    _mhm_die "要影响当前 shell，请先 source 本脚本，然后运行 mhm proxy off"
    return 1
  }
  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
  _mhm_info "当前 shell 已关闭代理环境变量"
}

_mhm_proxy_status() {
  printf 'http_proxy=%s\n' "${http_proxy:-<unset>}"
  printf 'https_proxy=%s\n' "${https_proxy:-<unset>}"
  printf 'all_proxy=%s\n' "${all_proxy:-<unset>}"
}

_mhm_proxy_env() {
  local hp="http://${MIHOMO_PROXY_HOST}:${MIHOMO_PROXY_PORT}"
  local sp="socks5h://${MIHOMO_PROXY_HOST}:${MIHOMO_PROXY_PORT}"
  printf 'export http_proxy=%q https_proxy=%q all_proxy=%q\n' "$hp" "$hp" "$sp"
  printf 'export HTTP_PROXY=%q HTTPS_PROXY=%q ALL_PROXY=%q\n' "$hp" "$hp" "$sp"
}

_mhm_cmd_proxy() {
  case "${1:-status}" in
    on) _mhm_proxy_on ;;
    off) _mhm_proxy_off ;;
    status) _mhm_proxy_status ;;
    env) _mhm_proxy_env ;;
    *) _mhm_die "用法: mhm proxy {on|off|status|env}" ;;
  esac
}

# ----- Installation and systemd lifecycle (all paths belong to one scope) -----

_mhm_github_download() {
  local url pfx redirects=10
  url="$(_mhm_proxy_github_url "$1")" || return 1
  pfx="$(_mhm_gh_proxy)" || return 1
  # Direct GitHub assets need redirects to their CDN. With a prefix, never
  # silently follow a redirect back to GitHub without applying that prefix.
  [[ -z "$pfx" ]] || redirects=0
  wget --no-proxy --max-redirect="$redirects" --timeout=30 --tries=2 \
    --user-agent="$MIHOMO_SUB_UA" -O "$2" "$url"
}

_mhm_sha256() {
  local sum
  sum="$(sha256sum < "$1")" || return 1
  printf '%s\n' "${sum%% *}"
}

_mhm_artifact() {
  local action="$1" kind="$2" path="$3" data previous expected hash="" temporary filter
  _mhm_need_jq || return 1
  if [[ -f "$_INSTALL_FILE" ]]; then data="$(cat "$_INSTALL_FILE")" || return 1
  else data="$(jq -cn --arg scope "$MIHOMO_SCOPE" '{scope: $scope}')" || return 1; fi
  jq -e --arg scope "$MIHOMO_SCOPE" 'type == "object" and .scope == $scope' <<< "$data" >/dev/null || \
    _mhm_die "安装记录无效或与当前级别不符" || return 1
  case "$action" in
    check)
      previous="$(jq -r --arg kind "$kind" '.[$kind].path // ""' <<< "$data")" || return 1
      [[ -z "$previous" || "$previous" == "$path" ]] || _mhm_die "路径与安装记录不符，请使用安装时的路径设置" || return 1
      if [[ -e "$path" || -L "$path" ]]; then
        [[ -f "$path" && ! -L "$path" && -n "$previous" ]] || _mhm_die "拒绝操作未由本工具安装的文件: $path" || return 1
        expected="$(jq -er --arg kind "$kind" '.[$kind].sha256' <<< "$data")" || return 1
        hash="$(_mhm_sha256 "$path")" || return 1
        [[ "$hash" == "$expected" ]] || _mhm_die "文件已被外部修改，保留文件: $path" || return 1
      fi ;;
    prepare)
      previous="$(jq -r --arg kind "$kind" '.[$kind].path // ""' <<< "$data")" || return 1
      [[ -z "$previous" || "$previous" == "$path" ]] || _mhm_die "路径与安装记录不符，请使用安装时的路径设置" || return 1
      hash="$(_mhm_sha256 "$4")" || return 1
      jq --arg kind "$kind" --arg path "$path" --arg hash "$hash" \
        '.[$kind] = {path: $path, sha256: $hash}' <<< "$data" ;;
    record|retain-data)
      if [[ "$action" == record ]]; then
        hash="$(_mhm_sha256 "$path")" || return 1
        filter='.[$kind] = {path: $path, sha256: $hash}'
      else
        filter='del(.binary, .unit)'
      fi
      temporary="$(mktemp "${_INSTALL_FILE}.tmp.XXXXXX")" || return 1
      if ! jq --arg kind "$kind" --arg path "$path" --arg hash "$hash" \
        "$filter" <<< "$data" > "$temporary"; then
        rm -f -- "$temporary"; return 1
      fi
      mv -f -- "$temporary" "$_INSTALL_FILE" || { rm -f -- "$temporary"; return 1; } ;;
    *) _mhm_die "未知安装记录操作"; return 1 ;;
  esac
}

_mhm_cmd_install() (
  local version="${1:-latest}" work asset_url arch
  [[ $# -le 1 && ( "$version" == latest || "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ) ]] || \
    _mhm_die "用法: mhm [--user|--system] install [latest|v版本号]" || return 1
  local dep
  for dep in wget jq gzip timeout sha256sum; do
    command -v "$dep" >/dev/null 2>&1 || _mhm_die "安装需要 $dep" || return 1
  done
  [[ "$(uname -s)" == Linux ]] || _mhm_die "安装仅支持 Linux" || return 1
  [[ "$MIHOMO_BIN" == /* ]] || _mhm_die "安装目标 MIHOMO_BIN 必须是绝对路径" || return 1
  _mhm_artifact check binary "$MIHOMO_BIN" || return 1
  work="$(mktemp -d)" || return 1
  trap 'rm -rf -- "$work"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  local api=https://api.github.com/repos/MetaCubeX/mihomo/releases/latest
  if [[ "$version" != latest ]]; then
    version="v${version#v}"
    api="https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/$version"
  fi
  _mhm_info "查询 GitHub 发行版: $version"
  _mhm_github_download "$api" "$work/release.json" || return 1
  arch="$(uname -m)"

  local tag names asset digest hash
  local -a arches=()
  tag="$(jq -er '.tag_name | select(type == "string" and length > 0)' "$work/release.json")" || return 1
  if [[ -n "$MIHOMO_RELEASE_ASSET" ]]; then
    names="$(jq -cn --arg name "$MIHOMO_RELEASE_ASSET" '[$name]')" || return 1
  else
    case "$arch" in
      x86_64) arches=(amd64-v1 amd64-compatible) ;;
      aarch64|arm64) arches=(arm64) ;;
      armv7l) arches=(armv7 arm32v7) ;;
      armv6l) arches=(armv6 arm32v6) ;;
      i386|i686) arches=(386) ;;
      riscv64) arches=(riscv64) ;;
      *) _mhm_die "不支持的架构: $arch；可设置 MIHOMO_RELEASE_ASSET 指定文件"; return 1 ;;
    esac
    names="$(printf '%s\n' "${arches[@]}" | jq -Rsc --arg tag "$tag" 'split("\n") | map(select(length > 0) | "mihomo-linux-" + . + "-" + $tag + ".gz")')" || return 1
  fi
  asset="$(jq -ce --argjson names "$names" '
    [$names[] as $name | .assets[] | select(.name == $name)][0]
    | select(.name | endswith(".gz"))' "$work/release.json")" || { _mhm_die "发行版中没有匹配的 Linux gzip 二进制文件"; return 1; }
  asset_url="$(jq -er '.browser_download_url | select(startswith("https://github.com/MetaCubeX/mihomo/releases/download/"))' <<< "$asset")" || { _mhm_die "下载地址不属于官方仓库"; return 1; }
  _mhm_info "下载: ${asset_url##*/}"
  _mhm_github_download "$asset_url" "$work/mihomo.gz" || return 1
  digest="$(jq -r '.digest // ""' <<< "$asset")" || return 1
  if [[ -n "$digest" ]]; then
    hash="$(_mhm_sha256 "$work/mihomo.gz")" || return 1
    [[ "$digest" == "sha256:$hash" ]] || _mhm_die "发行版 SHA256 校验失败" || return 1
  fi
  gzip -dc "$work/mihomo.gz" > "$work/mihomo" || return 1
  [[ -s "$work/mihomo" ]] || _mhm_die "解压结果为空" || return 1
  chmod 700 "$work/mihomo" || return 1
  timeout 10s "$work/mihomo" -v || { _mhm_die "下载的 Mihomo 无法运行，未覆盖已安装版本"; return 1; }
  install -D -m 0755 "$work/mihomo" "$MIHOMO_BIN" || return 1
  _mhm_artifact record binary "$MIHOMO_BIN" || return 1
  _mhm_info "已安装 ($MIHOMO_SCOPE): $MIHOMO_BIN；运行 mhm --$MIHOMO_SCOPE register 注册服务"
)


_mhm_unit_quote() {
  local value="$1"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || _mhm_die "systemd 路径不能包含换行" || return 1
  value="${value//\/\\}"
  value="${value//\"/\\\"}"
  value="${value//%/%%}"
  value="${value//\$/\$\$}"
  printf '"%s"' "$value"
}

_mhm_cmd_register() (
  local work
  [[ $# == 0 ]] || _mhm_die "用法: mhm [--user|--system] register" || return 1
  command -v systemctl >/dev/null 2>&1 || _mhm_die "需要 systemctl" || return 1
  _mhm_need_jq || return 1
  [[ -x "$MIHOMO_BIN" && "$MIHOMO_BIN" == /* ]] || _mhm_die "请先安装 Mihomo，或指定 MIHOMO_BIN 的绝对路径" || return 1
  _mhm_artifact check binary "$MIHOMO_BIN" || return 1
  _mhm_artifact check unit "$_UNIT_FILE" || return 1
  if [[ ! -e "$_UNIT_FILE" ]] && _mhm_service_exists; then
    _mhm_die "已存在外部注册的同名服务，请设置不同的 MIHOMO_SERVICE"
    return 1
  fi
  _mhm_systemctl show-environment >/dev/null || { _mhm_die "无法连接 $MIHOMO_SCOPE systemd 管理器"; return 1; }
  work="$(mktemp -d)" || return 1
  trap 'rm -rf -- "$work"' EXIT
  _mhm_owned_dir "$MIHOMO_DATA_DIR" || return 1
  chmod 700 "$MIHOMO_DATA_DIR" || return 1
  if [[ ! -e "$MIHOMO_CONFIG_TARGET" ]]; then
    printf '{"rules":["MATCH,DIRECT"]}\n' > "$work/base.yaml"
    _mhm_render_runtime_config "$work/base.yaml" "$work/config.yaml" || return 1
    _mhm_install_target "$work/config.yaml" || return 1
  fi

  local binary data config target=default.target
  binary="$(_mhm_unit_quote "$MIHOMO_BIN")" || return 1
  data="$(_mhm_unit_quote "$MIHOMO_DATA_DIR")" || return 1
  config="$(_mhm_unit_quote "$MIHOMO_CONFIG_TARGET")" || return 1
  [[ "$MIHOMO_SCOPE" != system ]] || target=multi-user.target
  cat > "$work/unit" <<UNIT
# Managed by mihomo-sub ($MIHOMO_SCOPE)
[Unit]
Description=Mihomo ($MIHOMO_SCOPE)
After=network.target

[Service]
Type=simple
ExecStart=$binary -d $data -f $config
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
UMask=0077

[Install]
WantedBy=$target
UNIT
  install -D -m 0644 "$work/unit" "$_UNIT_FILE" || return 1
  _mhm_artifact record unit "$_UNIT_FILE" || return 1
  _mhm_systemctl daemon-reload || return 1
  _mhm_systemctl enable "${MIHOMO_SERVICE}.service" || return 1
  _mhm_info "已注册并启用 $MIHOMO_SCOPE 服务；运行 mhm --$MIHOMO_SCOPE start 启动"
)

_mhm_cmd_status() {
  local state enabled load
  printf 'scope:      %s\nbinary:     %s\nconfig:     %s\nunit:       %s\n' \
    "$MIHOMO_SCOPE" "$MIHOMO_BIN" "$MIHOMO_CONFIG_TARGET" "$_UNIT_FILE"
  if [[ -x "$MIHOMO_BIN" ]]; then
    if command -v timeout >/dev/null 2>&1; then timeout 5s "$MIHOMO_BIN" -v; else "$MIHOMO_BIN" -v; fi
  else
    printf 'installed:  no\n'
  fi
  if ! load="$(_mhm_systemctl show -p LoadState --value "${MIHOMO_SERVICE}.service" 2>/dev/null)" || [[ -z "$load" ]]; then
    printf 'systemd:    unavailable\n'
    return 1
  fi
  state="$(_mhm_systemctl is-active "${MIHOMO_SERVICE}.service" 2>/dev/null)" || true
  enabled="$(_mhm_systemctl is-enabled "${MIHOMO_SERVICE}.service" 2>/dev/null)" || true
  printf 'load:       %s\nstate:      %s\nenabled:    %s\n' "$load" "${state:-unknown}" "${enabled:-unknown}"
}

_mhm_cmd_service() {
  local action="${1:-status}"
  case "$action" in
    register) shift; _mhm_cmd_register "$@" ;;
    status) _mhm_cmd_status ;;
    start|stop|restart|enable|disable)
      _mhm_systemctl "$action" "${MIHOMO_SERVICE}.service" ;;
    logs)
      if [[ "$MIHOMO_SCOPE" == user ]]; then
        journalctl --user -u "${MIHOMO_SERVICE}.service" -n 50 --no-pager
      else
        journalctl --system -u "${MIHOMO_SERVICE}.service" -n 50 --no-pager
      fi ;;
    *) _mhm_die "用法: mhm service {register|status|start|stop|restart|enable|disable|logs}" ;;
  esac
}

_mhm_cleanup_data() {
  local action="${1:-apply}" root resolved marker config_owned=0 f hash expected previous
  local -a roots=("$MIHOMO_SUB_HOME" "$MIHOMO_SUB_CACHE" "$MIHOMO_DATA_DIR") owned=() known=()
  _mhm_need_jq || return 1
  for root in "${roots[@]}"; do
    resolved="$(realpath -m -- "$root")" || return 1
    [[ "$root" == /* && ! -L "$root" && "$resolved" != "$HOME" ]] || _mhm_die "拒绝清理非独立目录: $root" || return 1
    case "$resolved" in /|/etc|/usr|/var|/tmp|/usr/local|/usr/local/bin) _mhm_die "拒绝清理非独立目录: $root"; return 1 ;; esac
    marker="$root/.mihomo-manager"
    if [[ -f "$marker" && "$(cat "$marker")" == "mihomo-sub:$MIHOMO_SCOPE" ]]; then
      owned+=("$root")
      [[ "$MIHOMO_CONFIG_TARGET" != "$root/"* ]] || config_owned=1
    fi
  done
  # Do not follow subscription/cache directory symlinks into another scope.
  [[ ! -L "$_SUB_DIR" && ! -L "$_PROFILE_DIR" ]] || _mhm_die "拒绝清理符号链接目录" || return 1
  [[ "$action" != check ]] || return 0
  known=("$_ACTIVE_FILE" "$_GROUP_FILE" "$_GH_PROXY_FILE" "$_INSTALL_FILE")
  for f in "$_SUB_DIR"/*.url "$_PROFILE_DIR"/*.yaml; do
    [[ ! -f "$f" && ! -L "$f" ]] || known+=("$f")
  done
  if (( ! config_owned )); then
    if [[ -f "${MIHOMO_CONFIG_TARGET}.before-mihomo-sub" ]]; then
      mv -f -- "${MIHOMO_CONFIG_TARGET}.before-mihomo-sub" "$MIHOMO_CONFIG_TARGET" || return 1
    elif [[ -f "$_INSTALL_FILE" && -f "$MIHOMO_CONFIG_TARGET" ]]; then
      previous="$(jq -r '.config.path // ""' "$_INSTALL_FILE")" || return 1
      expected="$(jq -r '.config.sha256 // ""' "$_INSTALL_FILE")" || return 1
      if [[ "$previous" == "$MIHOMO_CONFIG_TARGET" ]]; then
        hash="$(_mhm_sha256 "$MIHOMO_CONFIG_TARGET")" || return 1
        if [[ "$hash" == "$expected" ]]; then known+=("$MIHOMO_CONFIG_TARGET")
        else _mhm_info "配置已被外部修改，保留: $MIHOMO_CONFIG_TARGET"; fi
      fi
    fi
  fi
  local i j temporary
  for ((i=0; i<${#owned[@]}; i++)); do
    for ((j=i+1; j<${#owned[@]}; j++)); do
      if (( ${#owned[j]} > ${#owned[i]} )); then
        temporary="${owned[i]}"; owned[i]="${owned[j]}"; owned[j]="$temporary"
      fi
    done
  done
  for root in "${owned[@]}"; do rm -rf -- "$root" || return 1; done
  for f in "${known[@]}"; do
    if [[ -f "$f" || -L "$f" ]]; then rm -f -- "$f" || return 1; fi
  done
  for root in "$_SUB_DIR" "$_PROFILE_DIR" "${roots[@]}"; do
    [[ ! -d "$root" ]] || rmdir -- "$root" 2>/dev/null || true
  done
}

_mhm_cmd_uninstall() {
  local keep=0
  if [[ "${1:-}" == --keep-data && $# == 1 ]]; then keep=1
  elif [[ $# != 0 ]]; then _mhm_die "用法: mhm uninstall [--keep-data]"; return 1; fi
  _mhm_need_jq || return 1
  _mhm_artifact check binary "$MIHOMO_BIN" || return 1
  _mhm_artifact check unit "$_UNIT_FILE" || return 1
  (( keep )) || _mhm_cleanup_data check || return 1
  if [[ ! -e "$_UNIT_FILE" ]] && _mhm_service_exists; then
    _mhm_die "检测到未由本工具注册的服务，拒绝停用或清理: ${MIHOMO_SERVICE}.service"
    return 1
  fi
  if [[ -e "$_UNIT_FILE" ]]; then
    _mhm_systemctl disable --now "${MIHOMO_SERVICE}.service" || return 1
  fi
  if [[ -e "$_UNIT_FILE" ]]; then
    rm -f -- "$_UNIT_FILE" || return 1
    _mhm_systemctl daemon-reload || return 1
    _mhm_systemctl reset-failed "${MIHOMO_SERVICE}.service" 2>/dev/null || true
  fi
  rm -f -- "$MIHOMO_BIN" || return 1
  if (( keep )); then
    _mhm_artifact retain-data config "$MIHOMO_CONFIG_TARGET" || return 1
    _mhm_info "已卸载 $MIHOMO_SCOPE 二进制和服务，保留订阅及配置"
  else
    _mhm_cleanup_data || return 1
    _mhm_info "已卸载并清理 $MIHOMO_SCOPE 安装、订阅、配置和缓存"
  fi
}

_mhm_help() {
  cat <<'HELP'
Mihomo Manager
用法: mhm [--user|--system] <命令> [参数]

默认管理用户级实例；--system 管理系统级实例，写入时按需使用 sudo。
安装、服务、订阅、配置和节点按级别分别管理。

安装与服务:
  mhm install [latest|v版本号]  安装或更新 Mihomo，默认选择最新正式版本
  mhm register                 注册 systemd 服务并启用自动启动
  mhm status                   查看安装版本、路径、服务和自动启动状态
  mhm start|stop|restart        启动、停止或重启服务
  mhm enable|disable           启用或禁用自动启动
  mhm logs                     显示所选级别服务最近 50 条日志
  mhm uninstall                卸载服务、二进制并清理本工具管理的数据
  mhm uninstall --keep-data    卸载服务和二进制，保留订阅、配置及缓存

订阅管理:
  mhm add <名称> <URL>          添加订阅并下载缓存
  mhm ls                       列出订阅，* 标记当前订阅
  mhm use <名称>               激活订阅并更新运行配置
  mhm set-url <名称> <URL>     修改订阅地址，稍后通过 update 下载
  mhm update [名称]            更新订阅；省略名称时更新当前订阅
  mhm update --all             更新全部订阅，并应用当前订阅的新配置
  mhm del <名称>               删除订阅和缓存；当前订阅需先切换再删除
  mhm show [名称]              查看订阅名称、URL 和缓存路径

节点与选择组:
  mhm node                     列出当前选择组的节点及编号
  mhm node 3                   切换到第 3 个节点
  mhm node use '节点名'        按完整名称切换节点
  mhm node current             查看当前选择组和节点
  mhm node test [URL]           通过所选级别的代理测试连接
  mhm node groups              列出所有 Selector 组
  mhm node group <编号|组名>   选择要管理的 Selector 组

终端代理:
  mhm proxy on                 为当前 shell 设置 HTTP、HTTPS 和 SOCKS 代理变量
  mhm proxy off                清除当前 shell 的代理变量
  mhm proxy status             查看当前 shell 的代理变量

GitHub 下载与 GEO 数据:
  mhm gh-proxy                 查看当前 GitHub 下载前缀
  mhm gh-proxy set <URL>       设置并保存前缀；传 '' 时直连
  mhm gh-proxy reset           恢复 MIHOMO_GH_PROXY_DEFAULT
  mhm gh-proxy off             使用直连下载
  mhm geo status               检查 geoip.metadb 和实际下载地址
  mhm geo update               下载或更新 geoip.metadb
  mhm help                     显示此帮助

用户级默认路径与端口:
  二进制:         ~/.local/bin/mihomo
  配置:           ~/.config/mihomo/config.yaml
  systemd:        ~/.config/systemd/user/mihomo.service
  mixed-port:     127.0.0.1:7897；Controller: 127.0.0.1:9090
系统级默认路径与端口:
  二进制:         /usr/local/bin/mihomo
  配置:           /etc/mihomo/config.yaml
  systemd:        /etc/systemd/system/mihomo.service
  mixed-port:     127.0.0.1:7898；Controller: 127.0.0.1:9091

首次使用: mhm install → mhm register → mhm add <名称> <URL> → mhm use <名称> → mhm start
register 注册并启用服务，start 启动服务。节点操作需要服务运行且配置含有 Selector 组。
用户级服务在用户管理器运行期间可用；需要开机运行时可设置 loginctl enable-linger。
卸载只清理所选级别中本工具管理的文件，保留其他级别及手动安装的文件。
GitHub 默认前缀为 https://gh-proxy.org/；空前缀表示直连，非空前缀用于 GitHub 下载及配置 URL。

可配置的环境变量:
  MIHOMO_SCOPE=user|system, MIHOMO_SUB_HOME, MIHOMO_SUB_CACHE,
  MIHOMO_CONFIG_TARGET, MIHOMO_SERVICE, MIHOMO_BIN, MIHOMO_UNIT_DIR,
  MIHOMO_PROXY_HOST, MIHOMO_PROXY_PORT,
  MIHOMO_CONTROLLER, MIHOMO_CONTROLLER_SECRET,
  MIHOMO_SUB_UA, MIHOMO_VALIDATE=1, MIHOMO_VALIDATE_TIMEOUT,
  MIHOMO_DATA_DIR, MIHOMO_SUB_DIRECT=0,
  MIHOMO_GH_PROXY_DEFAULT, MIHOMO_READY_TIMEOUT, MIHOMO_RELEASE_ASSET,
  MIHOMO_YQ_BIN, MIHOMO_PYTHON_FALLBACK=0（禁用 Python YAML 备用读取器）

路径、端口和 Controller 地址请在加载脚本前设置；自定义值会应用于两个级别。

在 Bash 或 zsh 中启用 mhm（自定义安装位置时请替换路径）:
  source ~/.local/share/mihomo-sub.sh

运行依赖 jq 1.6+；读取 YAML 优先使用 mikefarah 原生 yq v4，也支持 Python + PyYAML 备用读取。
HELP
}

_mhm_dispatch() {
  # Dynamic locals keep a --system invocation from changing a sourced shell's
  # default user scope, paths or proxy environment.
  local MIHOMO_SCOPE="$MIHOMO_SCOPE"
  local MIHOMO_SUB_HOME MIHOMO_SUB_CACHE MIHOMO_CONFIG_TARGET MIHOMO_DATA_DIR
  local MIHOMO_BIN MIHOMO_UNIT_DIR MIHOMO_PROXY_PORT MIHOMO_CONTROLLER
  local _SUB_DIR _PROFILE_DIR _ACTIVE_FILE _GROUP_FILE _GH_PROXY_FILE _UNIT_FILE _INSTALL_FILE
  while [[ "${1:-}" == --user || "${1:-}" == --system ]]; do
    MIHOMO_SCOPE="${1#--}"
    shift
  done
  _mhm_scope_paths || return 1
  [[ "$MIHOMO_SERVICE" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$MIHOMO_SERVICE" != *.service ]] || \
    _mhm_die "MIHOMO_SERVICE 必须是不带 .service 后缀的服务名称" || return 1
  local key
  for key in MIHOMO_SUB_HOME MIHOMO_SUB_CACHE MIHOMO_CONFIG_TARGET MIHOMO_DATA_DIR MIHOMO_BIN MIHOMO_UNIT_DIR; do
    [[ "${!key}" == /* && "${!key}" != *$'\n'* && "${!key}" != *$'\r'* ]] || \
      _mhm_die "$key 必须是绝对路径且不能包含换行" || return 1
  done
  local command="${1:-help}" elevate=1
  case "$command" in
    help|-h|--help|status|proxy|env) elevate=0 ;;
    service) [[ "${2:-status}" == status ]] && elevate=0 ;;
  esac
  if [[ "$MIHOMO_SCOPE" == system && "$elevate" == 1 ]] && ! _mhm_is_root; then
    command -v sudo >/dev/null 2>&1 || _mhm_die "系统级操作需要 root 或 sudo" || return 1
    local -a settings=()
    for key in MIHOMO_SCOPE MIHOMO_SUB_HOME MIHOMO_SUB_CACHE MIHOMO_CONFIG_TARGET \
      MIHOMO_DATA_DIR MIHOMO_BIN MIHOMO_UNIT_DIR MIHOMO_PROXY_PORT MIHOMO_CONTROLLER \
      MIHOMO_SERVICE MIHOMO_PROXY_HOST MIHOMO_CONTROLLER_SECRET MIHOMO_SUB_UA \
      MIHOMO_VALIDATE MIHOMO_VALIDATE_TIMEOUT MIHOMO_SUB_DIRECT MIHOMO_GH_PROXY_DEFAULT \
      MIHOMO_GEO_MMDB_RAW MIHOMO_GEOIP_RAW MIHOMO_GEOSITE_RAW MIHOMO_ASN_RAW \
      MIHOMO_READY_TIMEOUT MIHOMO_RELEASE_ASSET MIHOMO_YQ_BIN MIHOMO_PYTHON_FALLBACK; do
      settings+=("$key=${!key}")
    done
    sudo -- env "${settings[@]}" bash "$_MHM_SCRIPT_PATH" --system "$@"
    return $?
  fi
  case "$command" in
    help|-h|--help|status|uninstall|proxy|env|service|start|stop|restart|enable|disable|logs) ;;
    *) _mhm_init || return 1 ;;
  esac
  case "${1:-help}" in
    install) shift; _mhm_cmd_install "$@" ;;
    register) shift; _mhm_init && _mhm_cmd_register "$@" ;;
    status) _mhm_cmd_status ;;
    uninstall) shift; _mhm_cmd_uninstall "$@" ;;
    service)
      shift
      [[ "${1:-status}" != register ]] || _mhm_init || return 1
      _mhm_cmd_service "$@" ;;
    start|stop|restart|enable|disable|logs) _mhm_cmd_service "$@" ;;
    add) shift; _mhm_cmd_add "$@" ;;
    ls|list) shift; _mhm_cmd_ls "$@" ;;
    use|switch) shift; _mhm_cmd_use "$@" ;;
    set-url|url) shift; _mhm_cmd_set_url "$@" ;;
    update|refresh) shift; _mhm_cmd_update "$@" ;;
    del|delete|rm) shift; _mhm_cmd_del "$@" ;;
    show) shift; _mhm_cmd_show "$@" ;;
    gh-proxy|github-proxy) shift; _mhm_cmd_gh_proxy "$@" ;;
    geo) shift; _mhm_cmd_geo "$@" ;;
    node|nodes) shift; _mhm_cmd_node "$@" ;;
    proxy|env) shift; _mhm_cmd_proxy "$@" ;;
    help|-h|--help) _mhm_help ;;
    *) _mhm_die "未知命令: $1"; _mhm_help; return 1 ;;
  esac
}

mhm() { _mhm_dispatch "$@"; }

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _mhm_dispatch "$@"
fi
