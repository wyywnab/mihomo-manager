#!/usr/bin/env bash
# Install Mihomo Manager for Bash or zsh, with native yq v4 by default.
# Run from a checkout with `bash install.sh`, or pipe this file to `bash -s --`.
set -euo pipefail
_MHM_INSTALLER_FILE="${BASH_SOURCE[0]:-}"

_mhm_install_die() { printf 'mhm 安装失败: %s\n' "$*" >&2; return 1; }
_mhm_install_info() { printf 'mhm 安装: %s\n' "$*" >&2; }

_mhm_install_help() {
  cat <<'HELP'
Mihomo Manager 安装器
用法: bash install.sh [选项]

默认安装管理脚本和原生 yq v4，并显示 shell 配置提示。
使用 --add-rc 可自动写入配置；安装过程无需 sudo 或 Python。

安装选项:
  --path <文件>         管理脚本路径，默认 ~/.local/share/mihomo-sub.sh
  --no-yq               跳过 yq 安装
  --yq-path <文件>      yq 路径，默认 ~/.local/bin/yq
  --yq-version <版本>   yq 版本，默认 latest；也可指定 v4.x.x

shell 配置:
  --shell <bash|zsh>    使用 mhm 的 shell，默认 bash
  --add-rc              自动写入或更新 shell 启动配置，备份已有文件
  --rc-file <文件>      启动文件，默认 ~/.bashrc 或 ${ZDOTDIR:-$HOME}/.zshrc

下载选项:
  --gh-proxy <URL>      GitHub 下载前缀；传 '' 时直连
  --repo <OWNER/REPO>   管理脚本仓库，默认 wyywnab/mihomo-manager
  --ref <分支或提交>    管理脚本版本，默认 main
  --source-url <URL>    从指定 HTTP(S) 地址下载管理脚本
  -h, --help            显示帮助

示例:
  bash install.sh                         # 安装并显示配置提示
  bash install.sh --add-rc                # 安装并自动配置 Bash
  bash install.sh --shell zsh --add-rc     # 安装并自动配置 zsh
  bash install.sh --no-yq                 # 跳过 yq 安装
  bash install.sh --gh-proxy ''           # 直接从 GitHub 下载

默认 GitHub 下载前缀为 https://gh-proxy.org/；环境变量和已保存的设置可覆盖默认值。
--gh-proxy 设置下载前缀，并将其写入 shell 配置；下载安装器本身的地址由调用命令决定。
--add-bashrc 和 --bashrc 分别是 --add-rc 和 --rc-file 的兼容别名。
Mihomo 二进制和服务需在启用 mhm 后通过 mhm install、mhm register 安装和注册。
使用 mhm 需要 jq 1.6+；缺少时会显示安装提示。
HELP
}

_mhm_install_github_host() {
  local value="$1" host
  host="${value#*://}"; host="${host%%[/?#]*}"
  host="${host##*@}"; host="${host%%:*}"; host="${host,,}"
  case "${host%.}" in
    github.com|*.github.com|githubusercontent.com|*.githubusercontent.com|github.io|*.github.io|githubassets.com|*.githubassets.com) return 0 ;;
    *) return 1 ;;
  esac
}

_mhm_install_download() {
  local url="$1" output="$2" prefix="$3" metadata status redirect i
  # Redirects are handled manually, including latest Release -> tagged Release
  # -> CDN, so every GitHub hop gets the configured prefix when it is nonempty.
  for ((i=0; i<10; i++)); do
    [[ "${url,,}" == http://* || "${url,,}" == https://* ]] || _mhm_install_die "下载地址必须是 HTTP(S) URL" || return 1
    if [[ -n "$prefix" && "$url" != "$prefix/"* ]] && _mhm_install_github_host "$url"; then
      url="$prefix/$url"
    fi
    metadata="$(curl --noproxy '*' --silent --show-error --fail \
      --connect-timeout 10 --max-time 60 --retry 1 --output "$output" \
      --write-out $'%{http_code}\n%{redirect_url}\n' "$url")" || return 1
    status="${metadata%%$'\n'*}"; redirect="${metadata#*$'\n'}"
    case "$status" in
      2??) [[ -s "$output" ]] || _mhm_install_die "下载内容为空"; return $? ;;
      301|302|303|307|308)
        [[ -n "$redirect" ]] || _mhm_install_die "重定向没有目标地址" || return 1
        url="$redirect" ;;
      *) _mhm_install_die "下载返回 HTTP $status"; return 1 ;;
    esac
  done
  _mhm_install_die "下载重定向过多"
}

_mhm_install_snippet() {
  local target="$1" yq_path="$2" prefix="$3" quoted
  printf '# >>> mihomo-manager >>>\n'
  printf -v quoted '%q' "$target"
  printf 'if [[ -r %s ]]; then\n' "$quoted"
  if [[ -n "$yq_path" ]]; then
    printf '  export MIHOMO_YQ_BIN=%q  # 原生 yq v4 的安装路径\n' "$yq_path"
  else
    printf '  # export MIHOMO_YQ_BIN=yq  # YAML 读取器；默认从 PATH 查找原生 yq v4\n'
  fi
  printf '  export MIHOMO_GH_PROXY_DEFAULT=%q  # GitHub 下载前缀；空值直连，已保存的设置优先\n' "$prefix"
  cat <<'OPTIONS'

  # 可选配置：按需取消行首 # 并修改值，保留在 source 之前。
  # 默认级别与服务
  # export MIHOMO_SCOPE=user  # 默认级别：user 或 system；命令行 --user/--system 优先
  # export MIHOMO_SERVICE=mihomo  # systemd 服务名，默认 mihomo，不带 .service 后缀

  # 代理与 Controller
  # export MIHOMO_PROXY_HOST=127.0.0.1  # 当前 shell 代理的目标主机，默认本机；不修改监听地址
  # export MIHOMO_PROXY_PORT=7897  # 混合代理端口；用户级默认 7897，系统级默认 7898
  # export MIHOMO_CONTROLLER=127.0.0.1:9090  # Controller 地址；用户级默认 9090，系统级默认 9091
  # export MIHOMO_CONTROLLER_SECRET=''  # Controller 访问密钥；默认空值，会覆盖订阅中的密钥

  # 路径：以下示例为用户级；不启用时按级别自动选择，显式设置会应用于两个级别。
  # export MIHOMO_BIN="$HOME/.local/bin/mihomo"  # 二进制路径；系统级默认 /usr/local/bin/mihomo
  # export MIHOMO_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"  # 单元目录；系统级默认 /etc/systemd/system
  # export MIHOMO_CONFIG_TARGET="${XDG_CONFIG_HOME:-$HOME/.config}/mihomo/config.yaml"  # 运行配置文件；系统级默认 /etc/mihomo/config.yaml
  # export MIHOMO_DATA_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mihomo"  # GEO 等数据目录；默认取运行配置文件所在目录
  # export MIHOMO_SUB_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/mihomo-sub"  # 订阅及管理记录目录；系统级默认 /etc/mihomo-sub
  # export MIHOMO_SUB_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/mihomo-sub"  # 订阅缓存目录；系统级默认 /var/cache/mihomo-sub

  # 下载与配置校验
  # export MIHOMO_SUB_UA=clash.meta  # 下载请求的 User-Agent，默认 clash.meta
  # export MIHOMO_SUB_DIRECT=1  # 订阅下载：1 直连（默认），0 允许使用 shell 代理环境变量
  # export MIHOMO_VALIDATE=0  # 配置检查：0 基础检查（默认），1 使用已安装的 mihomo -t 完整校验
  # export MIHOMO_VALIDATE_TIMEOUT=20  # 完整配置校验超时设置，默认 20 秒
  # export MIHOMO_READY_TIMEOUT=12  # Controller 就绪等待设置，默认 12 秒
  # export MIHOMO_PYTHON_FALLBACK=1  # YAML 读取：1 允许 Python + PyYAML 备用读取（默认），0 禁用
  # export MIHOMO_RELEASE_ASSET=''  # 指定 Release 中的 .gz 二进制文件名；默认按架构自动选择

  # GEO 原始下载地址：默认值如下，下载时仍会应用上面的 GitHub 前缀。
  # export MIHOMO_GEO_MMDB_RAW='https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb'  # MMDB 数据
  # export MIHOMO_GEOIP_RAW='https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat'  # GeoIP 数据
  # export MIHOMO_GEOSITE_RAW='https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat'  # GeoSite 数据
  # export MIHOMO_ASN_RAW='https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb'  # ASN 数据

OPTIONS
  printf '  source %s\nfi\n' "$quoted"
  printf '# <<< mihomo-manager <<<\n'
}

_mhm_install_rc() (
  local rc_file="$1" snippet="$2" shell_kind="$3" actual temporary mode=600
  actual="$(realpath -m -- "$rc_file")" || return 1
  mkdir -p -- "$(dirname "$actual")" || return 1
  temporary="$(mktemp "${actual}.tmp.XXXXXX")" || return 1
  trap 'rm -f -- "$temporary"' EXIT
  if [[ -f "$actual" ]]; then
    mode="$(stat -c '%a' "$actual")" || return 1
    # Refuse malformed marker blocks rather than dropping unrelated content.
    awk '
      $0 == "# >>> mihomo-manager >>>" {
        if (inside) { bad=1; exit 1 }; inside=1; next
      }
      $0 == "# <<< mihomo-manager <<<" {
        if (!inside) { bad=1; exit 1 }; inside=0; next
      }
      !inside { print }
      END { if (inside || bad) exit 1 }
    ' "$actual" > "$temporary" || { _mhm_install_die "shell 配置中的 mihomo-manager 配置块不完整，未修改文件"; return 1; }
  fi
  printf '\n' >> "$temporary"
  cat "$snippet" >> "$temporary" || return 1
  if command -v "$shell_kind" >/dev/null 2>&1; then
    "$shell_kind" -n "$temporary" || { _mhm_install_die "shell 配置语法校验失败，未修改文件"; return 1; }
  else
    _mhm_install_info "未检测到 $shell_kind，已生成配置，待该 shell 安装后启用"
  fi
  chmod "$mode" "$temporary" || return 1
  if [[ -f "$actual" && ! -e "${actual}.before-mhm-installer" ]]; then
    cp -p -- "$actual" "${actual}.before-mhm-installer" || return 1
  fi
  mv -f -- "$temporary" "$actual" || return 1
)

_mhm_install_main() (
  local target="$HOME/.local/share/mihomo-sub.sh" yq_path="$HOME/.local/bin/yq"
  local rc_file="" shell_kind=bash install_yq=1 add_rc=0 version=latest
  local repo="${MIHOMO_INSTALL_REPO:-wyywnab/mihomo-manager}" ref="${MIHOMO_INSTALL_REF:-main}" source_url="" repo_explicit=0 ref_explicit=0
  [[ -z "${MIHOMO_INSTALL_REPO:-}" ]] || repo_explicit=1
  [[ -z "${MIHOMO_INSTALL_REF:-}" ]] || ref_explicit=1
  local prefix="${MIHOMO_GH_PROXY_DEFAULT-https://gh-proxy.org/}"
  local settings="${MIHOMO_SUB_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/mihomo-sub}/gh-proxy"
  if [[ ! ${MIHOMO_GH_PROXY_DEFAULT+x} && -f "$settings" ]]; then prefix="$(cat "$settings")"; fi
  while (($#)); do
    case "$1" in
      --no-yq) install_yq=0; shift ;;
      --add-bashrc|--auto-bashrc|--add-rc) add_rc=1; shift ;;
      --path|--yq-path|--yq-version|--bashrc|--rc-file|--shell|--gh-proxy|--repo|--ref|--source-url)
        [[ $# -ge 2 ]] || _mhm_install_die "$1 缺少参数" || return 1
        case "$1" in
          --path) target="$2" ;; --yq-path) yq_path="$2" ;;
          --yq-version) version="$2" ;; --bashrc|--rc-file) rc_file="$2" ;;
          --shell) shell_kind="$2" ;;
          --gh-proxy) prefix="$2" ;; --repo) repo="$2"; repo_explicit=1 ;;
          --ref) ref="$2"; ref_explicit=1 ;; --source-url) source_url="$2" ;;
        esac
        shift 2 ;;
      -h|--help) _mhm_install_help; return 0 ;;
      *) _mhm_install_die "未知参数: $1；使用 --help 查看参数"; return 1 ;;
    esac
  done
  case "$shell_kind" in
    bash) rc_file="${rc_file:-$HOME/.bashrc}" ;;
    zsh) rc_file="${rc_file:-${ZDOTDIR:-$HOME}/.zshrc}" ;;
    *) _mhm_install_die "--shell 当前支持 bash 或 zsh"; return 1 ;;
  esac
  local item dep
  for item in "$target" "$yq_path" "$rc_file"; do
    [[ -n "$item" && "$item" != *$'\n'* && "$item" != *$'\r'* ]] || _mhm_install_die "安装路径不能为空或包含换行" || return 1
  done
  for dep in bash curl install realpath mktemp awk grep stat timeout; do
    command -v "$dep" >/dev/null 2>&1 || _mhm_install_die "需要 $dep" || return 1
  done
  target="$(realpath -m -- "$target")"; yq_path="$(realpath -m -- "$yq_path")"; rc_file="$(realpath -m -- "$rc_file")"
  [[ "$target" != "$rc_file" && "$target" != "$yq_path" && "$yq_path" != "$rc_file" ]] || _mhm_install_die "脚本、yq 和 shell 配置路径必须不同" || return 1
  for item in "$target" "$yq_path"; do
    [[ ! -e "$item" || -f "$item" ]] || _mhm_install_die "安装目标不是普通文件: $item" || return 1
  done
  if (( add_rc )); then
    [[ ! -e "$rc_file" || -f "$rc_file" ]] || _mhm_install_die "shell 配置路径不是普通文件" || return 1
  fi
  [[ -z "$prefix" || "$prefix" == http://* || "$prefix" == https://* ]] || _mhm_install_die "代理前缀必须为空或 HTTP(S) URL" || return 1
  [[ "$prefix" != *$'\n'* && "$prefix" != *$'\r'* && "$prefix" != *'"'* && "$prefix" != *' '* ]] || _mhm_install_die "代理前缀格式无效" || return 1
  prefix="${prefix%/}"
  [[ "$version" == latest || "$version" =~ ^v4\.[0-9]+\.[0-9]+$ ]] || _mhm_install_die "yq 版本必须为 latest 或 v4.x.x" || return 1
  [[ -z "$repo" || "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || _mhm_install_die "仓库格式必须为 OWNER/REPO" || return 1
  [[ "$ref" =~ ^[A-Za-z0-9._/-]+$ && "$ref" != /* && "$ref" != *..* ]] || _mhm_install_die "分支或提交格式无效" || return 1
  local work installer_file local_source arch asset release yq_description yq_new=0
  work="$(mktemp -d)" || return 1
  trap 'rm -rf -- "$work"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  installer_file="$_MHM_INSTALLER_FILE"
  local_source="$(dirname "${installer_file:-.}")/mihomo-sub.sh"
  if [[ -n "$source_url" ]]; then
    _mhm_install_info "下载 mhm 主脚本"
    _mhm_install_download "$source_url" "$work/mihomo-sub.sh" "$prefix" || return 1
  elif [[ "$repo_explicit" == 0 && "$ref_explicit" == 0 && -n "$installer_file" && -f "$local_source" ]]; then
    cp -- "$local_source" "$work/mihomo-sub.sh" || return 1
  elif [[ -n "$repo" ]]; then
    _mhm_install_info "下载 mhm 主脚本: $repo ($ref)"
    _mhm_install_download "https://raw.githubusercontent.com/$repo/$ref/mihomo-sub.sh" "$work/mihomo-sub.sh" "$prefix" || return 1
  else
    _mhm_install_die "找不到相邻的 mihomo-sub.sh；远程安装请传 --repo OWNER/REPO 或 --source-url URL"
    return 1
  fi
  bash -n "$work/mihomo-sub.sh" || return 1
  grep -Eq '^[[:space:]]*mhm[[:space:]]*\(\)' "$work/mihomo-sub.sh" || _mhm_install_die "下载内容不是 mhm 主脚本" || return 1
  if (( install_yq )); then
    yq_description=""
    if [[ -x "$yq_path" ]]; then yq_description="$(timeout 10s "$yq_path" --version 2>/dev/null)" || true; fi
    if [[ "$yq_description" =~ version[[:space:]]+(v4\.[0-9]+\.[0-9]+)([[:space:]]|$) ]] &&
      [[ "$version" == latest || "${BASH_REMATCH[1]}" == "$version" ]]; then
      _mhm_install_info "复用已安装的原生 yq: $yq_path"
    else
      [[ "$(uname -s)" == Linux ]] || _mhm_install_die "默认 yq 安装仅支持 Linux；可使用 --no-yq" || return 1
      arch="$(uname -m)"
      case "$arch" in
        x86_64) asset=amd64 ;; aarch64|arm64) asset=arm64 ;;
        armv6l|armv7l) asset=arm ;; i386|i686) asset=386 ;;
        riscv64|ppc64le|s390x) asset="$arch" ;;
        *) _mhm_install_die "不支持的 yq 架构: $arch；可使用 --no-yq"; return 1 ;;
      esac
      release="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$asset"
      [[ "$version" == latest ]] || release="https://github.com/mikefarah/yq/releases/download/$version/yq_linux_$asset"
      _mhm_install_info "下载原生 yq ($asset)"
      _mhm_install_download "$release" "$work/yq" "$prefix" || return 1
      chmod 700 "$work/yq" || return 1
      yq_description="$(timeout 10s "$work/yq" --version)" || _mhm_install_die "下载的 yq 无法运行" || return 1
      [[ "$yq_description" =~ version[[:space:]]+(v4\.[0-9]+\.[0-9]+)([[:space:]]|$) ]] || _mhm_install_die "下载内容不是原生 yq v4" || return 1
      [[ "$version" == latest || "${BASH_REMATCH[1]}" == "$version" ]] || _mhm_install_die "下载的 yq 版本与请求的 $version 不符" || return 1
      yq_new=1
    fi
  fi
  # Validate all downloads before replacing installed files.
  if (( yq_new )); then install -D -m 0755 "$work/yq" "$yq_path" || return 1; fi
  install -D -m 0644 "$work/mihomo-sub.sh" "$target" || return 1
  if (( ! install_yq )); then yq_path=""; fi
  _mhm_install_snippet "$target" "$yq_path" "$prefix" > "$work/snippet"
  if (( add_rc )); then
    _mhm_install_rc "$rc_file" "$work/snippet" "$shell_kind" || return 1
    _mhm_install_info "已更新 shell 启动配置: $rc_file"
  else
    printf '\n请把下面内容加入 %s，以便新终端自动加载 mhm：\n\n' "$rc_file"
    cat "$work/snippet"
  fi
  _mhm_install_info "管理脚本已安装到: $target"
  if ! command -v jq >/dev/null 2>&1; then
    printf '\n使用 mhm 前还需安装 jq 1.6+（Debian/Ubuntu: sudo apt install jq）。\n'
  fi
  printf '\n在当前终端执行以下命令以启用 mhm：\n'
  if [[ -n "$yq_path" ]]; then printf 'export MIHOMO_YQ_BIN=%q\n' "$yq_path"; fi
  printf 'export MIHOMO_GH_PROXY_DEFAULT=%q\nsource %q\n' "$prefix" "$target"
  printf '\n启用后运行 mhm help 查看命令；首次使用可依次执行 mhm install、mhm register。\n'
)

_mhm_install_main "$@"
