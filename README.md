# Mihomo Manager

Mihomo Manager 是适用于 Linux 的 Mihomo 命令行管理工具。通过 `mhm`，
可以安装 Mihomo、管理 systemd 服务、切换订阅和节点，以及设置终端代理。
支持 Bash 和 zsh，默认管理用户级实例，也可通过 `--system` 管理系统级实例。

## 快速开始

选择以下任意一种方式，复制整行命令执行即可。

**通过 GitHub 代理安装**（默认前缀：`https://gh-proxy.org/`）：

```sh
bash -o pipefail -c 'export MIHOMO_GH_PROXY_DEFAULT="https://gh-proxy.org/"; curl --noproxy "*" -fsS "${MIHOMO_GH_PROXY_DEFAULT}https://raw.githubusercontent.com/wyywnab/mihomo-manager/main/install.sh" | bash -s -- "$@"' --
```

**直接连接 GitHub 安装**：

```sh
bash -o pipefail -c 'export MIHOMO_GH_PROXY_DEFAULT=""; curl --noproxy "*" -fsS "https://raw.githubusercontent.com/wyywnab/mihomo-manager/main/install.sh" | bash -s -- "$@"' --
```

两条命令分别为安装器、管理脚本和 yq 设置代理下载或直连下载。
默认安装位置为 `~/.local/share/mihomo-sub.sh`，同时安装原生 yq v4。
安装完成后，按输出提示启用 `mhm`，并将配置加入 shell 启动文件。
默认目标是 Bash，只有指定 `--add-rc` 时才会自动写入配置。

**可选参数**：直接追加到所选命令的末尾。例如追加 `--shell zsh --add-rc`，
即可为 zsh 自动配置 `mhm`；追加 `--no-yq` 可跳过 yq 安装。

| 参数 | 作用 |
| --- | --- |
| `--shell bash\|zsh` | 选择使用 `mhm` 的 shell，默认 `bash` |
| `--add-rc` | 自动写入或更新 shell 启动配置 |
| `--rc-file <文件>` | 指定启动文件，默认 `~/.bashrc` 或 `${ZDOTDIR:-$HOME}/.zshrc` |
| `--path <文件>` | 指定管理脚本的安装位置 |
| `--no-yq` | 跳过 yq 安装 |
| `--yq-path <文件>` | 指定 yq 路径，默认 `~/.local/bin/yq` |
| `--yq-version <版本>` | 指定 `v4.x.x` 版本，默认 `latest` |
| `--gh-proxy <URL>` | 指定管理脚本和 yq 的下载前缀；传 `''` 时直连 |
| `--repo <OWNER/REPO>` | 指定主脚本仓库，默认 `wyywnab/mihomo-manager` |
| `--ref <分支或提交>` | 指定下载版本，默认 `main` |
| `--source-url <URL>` | 从指定 HTTP(S) 地址下载主脚本 |
| `--help` | 查看完整帮助 |

使用其他代理服务时，修改代理版命令中的 `https://gh-proxy.org/`，即可让
安装器和后续 GitHub 下载使用同一前缀。`--gh-proxy` 只影响安装器启动后的
下载；安装时选定的前缀也会写入输出的 shell 配置，供 `mhm` 后续使用。

运行环境：Linux、Bash 4.2+、jq 1.6+、wget、curl、coreutils、gzip 和 systemd。
在 zsh 中使用时也需要 Bash。普通用户执行系统级写入操作时需要 sudo。

## 从本地安装

已下载或克隆本仓库时，可在仓库目录执行：

```sh
bash install.sh                            # 安装管理脚本和 yq，并显示配置提示
```

安装器将管理脚本保存到 `~/.local/share/mihomo-sub.sh`，将原生 yq v4 保存到
`~/.local/bin/yq`。安装过程无需 sudo 或 Python。

选择 shell，并自动添加配置：

```sh
bash install.sh --shell bash --add-rc       # 安装并配置 Bash
bash install.sh --shell zsh --add-rc        # 安装并配置 zsh
```

`--shell` 默认是 `bash`，可指定 `zsh`。Bash 默认使用 `~/.bashrc`；zsh
默认使用 `${ZDOTDIR:-$HOME}/.zshrc`。`--rc-file /路径/配置文件` 可以指定其他
配置文件，`--path /路径/mihomo-sub.sh` 可以改变主脚本安装位置。
使用 `--add-rc` 时，原配置会备份为 `<配置文件>.before-mhm-installer`。
重复安装会更新已有的 `mhm` 配置，不会重复添加。按安装输出中的命令启用当前
终端；后续打开的终端会自动加载。
输出提示和自动写入的配置块均包含可选环境变量模板，每行附有用途和默认值说明。
这些可选 `export` 默认被注释；需要定制时，取消相应行首的 `#` 并修改值，
保持它们位于 `source` 前即可。

其他安装选项：

```sh
bash install.sh --no-yq                       # 跳过 yq 安装
bash install.sh --gh-proxy ''                 # GitHub 直连
bash install.sh --gh-proxy 'https://代理前缀/' # 所有 GitHub 下载应用此前缀
bash install.sh --help                        # 查看安装选项
```

本地安装时，GitHub 下载前缀依次取自 `--gh-proxy`、环境变量
`MIHOMO_GH_PROXY_DEFAULT`、用户已保存的设置，最后使用默认值
`https://gh-proxy.org/`。空前缀表示直连；使用代理时，GitHub 重定向下载也会
应用此前缀。`--yq-version v4.x.x` 可指定版本，已有版本不匹配时会替换；
`--yq-path` 可指定安装位置。显式传入 `--ref` 或设置 `MIHOMO_INSTALL_REF` 时，
即使从本地 checkout 运行安装器，也会下载指定版本的管理脚本。
缺少 jq 时会提示安装命令，Debian/Ubuntu 可执行 `sudo apt install jq`。

完成管理脚本安装后，使用 `mhm install` 安装 Mihomo，再用 `mhm register`
注册 systemd 服务。具体步骤见下文。

## mhm 用法

基本格式：

```text
mhm [--user|--system] <命令> [参数]
```

`--user` 和 `--system` 放在命令前；省略时默认使用用户级实例。
可在加载脚本前通过环境变量 `MIHOMO_SCOPE=user|system` 覆盖默认级别，例如
`export MIHOMO_SCOPE=system`；命令行级别参数优先，且只对本次命令生效。
两个级别分别管理安装、服务、订阅、配置、节点和 GitHub 前缀。
以下示例未指定级别时，均操作默认实例。

```sh
source ~/.local/share/mihomo-sub.sh # 在当前 Bash/zsh 中启用 mhm；自定义安装路径需替换
mhm help                          # 查看完整帮助
mhm --user status                 # 检查用户级安装和服务状态
mhm --system status               # 检查系统级安装和服务状态
```

### 首次安装与启动

安装并启动用户级实例，替换示例中的订阅 URL：
GitHub 下载沿用安装时选择的前缀；需要更改时可使用下文的 `mhm gh-proxy` 命令。

```bash
mhm --user install                 # 安装最新正式 Release 的 Mihomo 二进制
mhm --user register                # 注册并启用用户级 systemd 服务，不立即启动
mhm --user add demo '订阅URL'       # 添加名为 demo 的订阅并下载缓存
mhm --user use demo                # 生成运行配置并激活 demo 订阅
mhm --user start                   # 启动用户级 Mihomo 服务
mhm --user status                  # 检查安装版本、路径、服务状态和自动启动状态
mhm --user node                    # 列出当前 Selector 组中的节点及编号
mhm --user proxy on                # 给当前 shell 设置代理环境变量
```

安装系统级实例：

```bash
mhm --system install               # 安装系统级 Mihomo 二进制
mhm --system register              # 注册并启用系统 systemd 服务
mhm --system add demo '订阅URL'     # 添加系统级订阅并下载缓存
mhm --system use demo              # 激活系统级订阅，写入系统运行配置
mhm --system start                 # 启动系统级 Mihomo 服务
mhm --system status                # 检查系统级安装和服务状态
mhm --system proxy on              # 当前 shell 使用系统级实例的代理端口
```

`register` 注册服务并启用自动启动，随后执行 `start` 启动。
尚未添加订阅时，注册会生成直连模式的基础配置。
切换订阅会更新运行配置，并尝试重载或重启正在运行的服务。

### 安装与服务管理

```sh
mhm install                       # 安装／更新到最新正式 Release
mhm install latest                # 显式选择最新正式 Release
mhm register                      # 注册并启用当前级别的 systemd 服务
mhm status                        # 查看二进制版本、安装路径和服务状态
mhm start                         # 启动服务
mhm stop                          # 停止服务
mhm restart                       # 重启服务
mhm enable                        # 启用自动启动
mhm disable                       # 禁用自动启动，不停止已运行的服务
mhm logs                          # 显示当前级别服务最近 50 条日志
mhm service start                 # start 的等价写法；其他服务操作也可这样调用
```

`mhm install` 支持追加以 `v` 开头的版本号，安装指定 GitHub Release。
`install` 更新二进制后，可运行 `mhm restart` 让正在运行的服务使用新版本。

用户级服务由用户 systemd 管理器管理。如果需要退出登录后持续运行或开机启动，
可执行 `sudo loginctl enable-linger "$USER"`。用户级服务使用当前用户权限；
需要 TUN 或特权端口时，应根据运行权限选择配置或使用系统级实例。

### 订阅管理

```sh
mhm add demo '订阅URL'             # 添加订阅并立即下载，不自动切换
mhm add backup '另一个订阅URL'     # 添加备用订阅
mhm ls                            # 列出订阅；* 标记当前订阅
mhm use demo                      # 激活 demo；运行中的已注册服务会重载或重启
mhm show                          # 查看当前订阅名称、URL 和缓存文件路径
mhm show backup                   # 查看指定订阅的信息
mhm set-url demo '新的订阅URL'     # 修改订阅地址，不立即下载
mhm update                        # 下载当前订阅并更新运行配置
mhm update backup                 # 更新指定订阅；仅当前订阅会更新运行配置
mhm update --all                  # 更新所有订阅，并应用当前订阅的新配置
mhm del backup                    # 删除备用订阅及缓存；不能删除当前订阅
```

订阅名称只允许字母、数字、点、下划线和短横线。订阅 URL 建议始终加引号。
删除当前订阅前，先用 `mhm use <其他名称>` 切换到另一份订阅。

### 节点与选择组

先启动当前级别的 Mihomo 服务，并确保配置含有 Selector 组。
节点编号以 `mhm node` 的输出为准，组编号以 `mhm node groups` 的输出为准。

```sh
mhm node                          # 列出当前选择组的节点；* 标记当前节点
mhm node current                  # 查看当前选择组及节点
mhm node 3                        # 切换到当前选择组的第 3 个节点
mhm node use '完整节点名'          # 按完整名称切换节点
mhm node groups                   # 列出所有 Selector 组
mhm node group 2                  # 将第 2 个 Selector 组设为操作对象
mhm node group '节点选择'          # 按完整组名选择操作对象
mhm node test                     # 通过本级 Mihomo 代理访问 Google 204 测试地址
mhm node test 'https://example.com/' # 使用指定 URL 测试本级代理
```

### 当前 shell 的代理

```sh
mhm proxy on                      # 设置当前 shell 的 HTTP、HTTPS 和 SOCKS 代理变量
mhm proxy status                  # 查看当前 shell 的代理变量
mhm proxy off                     # 清除当前 shell 的代理变量，不停止 Mihomo
mhm --system proxy on             # 当前 shell 改用系统级实例的代理端口
```

这些设置作用于当前 shell 及其后续启动的进程；其他终端需分别执行。
请先 `source` 安装的脚本，再运行上述命令。`mhm env on/off/status` 是等价写法。

### GitHub 前缀与 GEO 数据

GitHub 代理前缀可以为空：为空时直接连接 GitHub；非空时，Release 元数据、
二进制、GEO、GitHub 托管订阅，以及配置中规则、provider、面板等 GitHub URL
都会应用当前级别的前缀。非空但格式无效的前缀会报错。

```bash
mhm gh-proxy                      # 查看当前级别保存的 GitHub 下载前缀
mhm gh-proxy set 'https://gh-proxy.org/' # 设置并保存 GitHub 下载前缀
mhm gh-proxy off                   # 清空当前级别的前缀，改为直连
mhm gh-proxy set ''                # 与 gh-proxy off 等效
mhm gh-proxy reset                 # 恢复 MIHOMO_GH_PROXY_DEFAULT
mhm geo status                    # 检查 geoip.metadb 和实际下载 URL
mhm geo update                    # 手动下载／更新当前级别的 geoip.metadb
```

未配置时默认使用 `https://gh-proxy.org/`。可在首次 source 前显式设置
`MIHOMO_GH_PROXY_DEFAULT=''`，让默认模式也使用直连；空值不会被默认前缀替换。
选择的代理服务需要支持 GitHub API、Release 和原始文件下载。
订阅重定向会逐步检查并应用当前前缀；Release 和 GEO 使用代理时会拒绝自动
重定向。遇到下载失败时，可更换代理前缀或使用直连。

安装自动选择 x86_64 的 amd64-v1/compatible 文件，以及 arm64、armv7、armv6、
386、riscv64 文件。可用 `MIHOMO_RELEASE_ASSET` 指定发行版中的 `.gz` 文件名。
Release 提供 SHA256 digest 时会验证下载文件；解压和版本检查通过后才覆盖二进制。
更新前会检查安装记录；手动安装的二进制需单独管理。

### 卸载与清理

```bash
mhm --user uninstall               # 停止、禁用并移除服务、二进制和本级数据
mhm --system uninstall             # 清理系统级服务、二进制及本工具管理的数据
mhm --user uninstall --keep-data   # 保留订阅、配置、缓存以便重新安装
```

卸载会检查安装记录并清理所选级别的服务、二进制和管理数据；其他级别可继续使用。
本工具创建的数据目录会一并移除，原有目录中的其他文件会保留；激活订阅前
备份的配置会恢复。手动安装或已被修改的二进制、服务单元会保留。
管理脚本、yq、系统日志和 linger 设置也会保留。`--keep-data` 会保留配置的
管理记录，以便重新安装后仍能在完整卸载时正确清理配置。
如果不再使用 `mhm`，可移除 `.bashrc`／`.zshrc` 中的管理配置块，
删除安装的 `~/.local/share/mihomo-sub.sh` 及不再需要的 yq。

### 配置与依赖

安装、卸载、systemd、节点和 JSON 操作均不依赖 Python。读取 YAML 订阅或已有
YAML 配置时，优先使用 [mikefarah 的原生 yq v4](https://mikefarah.gitbook.io/yq/)
（Go 单文件程序，安装器默认提供）。也可使用 Python 3 + PyYAML 作为备用
读取器。管理安装、服务和 JSON 配置无需 YAML 读取器。

需要禁用 Python 备用读取器时，在加载脚本前设置：

```bash
export MIHOMO_PYTHON_FALLBACK=0     # 禁用可选的 Python YAML 读取器
source ~/.local/share/mihomo-sub.sh # 加载安装后的脚本；自定义路径需替换
```

可用 `MIHOMO_YQ_BIN=/绝对路径/yq` 指定原生 yq。

用户级和系统级实例使用不同的默认目录和端口。用户级目录支持 XDG 环境变量：

| 项目 | 用户级 `--user` 默认值 | 系统级 `--system` 默认值 | 覆盖环境变量 |
| --- | --- | --- | --- |
| 二进制 | `~/.local/bin/mihomo` | `/usr/local/bin/mihomo` | `MIHOMO_BIN` |
| 运行配置文件 | `~/.config/mihomo/config.yaml` | `/etc/mihomo/config.yaml` | `MIHOMO_CONFIG_TARGET` |
| 数据目录 | `~/.config/mihomo/` | `/etc/mihomo/` | `MIHOMO_DATA_DIR`；未设置时取运行配置文件所在目录 |
| 订阅及管理记录 | `~/.config/mihomo-sub/` | `/etc/mihomo-sub/` | `MIHOMO_SUB_HOME` |
| 订阅缓存 | `~/.cache/mihomo-sub/` | `/var/cache/mihomo-sub/` | `MIHOMO_SUB_CACHE` |
| systemd 单元目录 | `~/.config/systemd/user/` | `/etc/systemd/system/` | `MIHOMO_UNIT_DIR` |
| mixed-port | `127.0.0.1:7897` | `127.0.0.1:7898` | `MIHOMO_PROXY_PORT`，仅覆盖端口 |
| Controller | `127.0.0.1:9090` | `127.0.0.1:9091` | `MIHOMO_CONTROLLER` |

### 运行配置与自定义路径

运行配置通过 YAML／JSON 解析后生成，以 JSON 格式写入 `config.yaml`；JSON
是 YAML 的兼容格式，不保留注释和原始排版。执行 `mhm use <名称>`，或更新当前
订阅时，会按下表生成运行配置；本地设置优先于订阅中对应的值。

| 配置项 | 写入运行配置的值／处理方式 | 环境变量与说明 |
| --- | --- | --- |
| `mixed-port` | 用户级 `7897`，系统级 `7898` | `MIHOMO_PROXY_PORT`；必须为 `1` 到 `65535` 的整数 |
| `allow-lan` | 固定为 `false` | 不继承订阅的局域网开放设置 |
| `bind-address` | 固定为 `127.0.0.1` | 混合代理仅监听本机；不能通过 `MIHOMO_PROXY_HOST` 修改 |
| `external-controller` | 用户级 `127.0.0.1:9090`，系统级 `127.0.0.1:9091` | `MIHOMO_CONTROLLER`；同时用于管理命令访问 Controller |
| `secret` | 默认空字符串 | `MIHOMO_CONTROLLER_SECRET`；未设置时也会清空订阅中的密钥 |
| `port`、`socks-port` | 移除 | HTTP 和 SOCKS 统一使用本地 `mixed-port` |
| `redir-port`、`tproxy-port` | 移除 | 不继承订阅的透明代理监听端口 |
| `listeners` | 移除 | 不继承订阅定义的额外监听器 |
| `external-controller-tls` | 移除 | 不继承额外的 HTTPS Controller 监听地址 |
| `external-controller-unix`、`external-controller-pipe` | 移除 | 不继承 Unix socket 或 Windows named pipe Controller |
| `geo-auto-update` | 固定为 `false` | 关闭 Mihomo 自身的 GEO 定时更新；可用 `mhm geo update` 更新 `geoip.metadb` |
| `geo-update-interval` | 移除 | 不继承订阅的 GEO 自动更新间隔 |
| `geox-url.mmdb` | 默认指向 `MetaCubeX/meta-rules-dat` 的 `geoip.metadb` | `MIHOMO_GEO_MMDB_RAW` |
| `geox-url.geoip` | 默认指向同一仓库的 `geoip.dat` | `MIHOMO_GEOIP_RAW` |
| `geox-url.geosite` | 默认指向同一仓库的 `geosite.dat` | `MIHOMO_GEOSITE_RAW` |
| `geox-url.asn` | 默认指向同一仓库的 `GeoLite2-ASN.mmdb` | `MIHOMO_ASN_RAW` |
| URL 字段 | GitHub 地址添加当前下载前缀；其他地址保留 | 包括 `url`、`urls`、`geox-url` 及以 `-url`／`-urls` 结尾的字段；使用已保存的 GitHub 前缀，未保存时取 `MIHOMO_GH_PROXY_DEFAULT`，空前缀表示直连 |
| 其余配置 | 保留订阅中的值 | 例如 `proxies`、`proxy-groups`、`rules`、`dns`、`tun`；provider 中的 URL 仍按上一行处理 |

四个 GEO 默认地址均使用该仓库的 `releases/download/latest/` 资源；设置相应
`*_RAW` 变量可替换原始下载地址，生成运行配置时仍会应用 GitHub 下载前缀。
生成的配置文件权限为 `0600`；配置和管理记录提交失败时会恢复旧配置。

上述路径、端口和 Controller 地址应在首次 `source` 前设置。路径必须为绝对路径；
显式覆盖会应用于两个级别，应为两个实例分别配置路径和端口。
另外，`MIHOMO_SERVICE` 可设置不带 `.service` 后缀的服务名称，默认 `mihomo`；
`MIHOMO_PROXY_HOST` 可设置当前 shell 代理环境变量的目标主机，默认 `127.0.0.1`，
它不会改变 Mihomo 的监听地址。

例如，设置系统级为默认实例，并覆盖端口和 Controller 密钥：

```bash
export MIHOMO_SCOPE=system
export MIHOMO_PROXY_PORT=17898
export MIHOMO_CONTROLLER=127.0.0.1:19091
export MIHOMO_CONTROLLER_SECRET='自行设置的密钥'
source ~/.local/share/mihomo-sub.sh
```

之后 `mhm status` 使用系统级实例，`mhm --user status` 临时选择用户级实例，
但上述显式端口和 Controller 地址仍适用于该用户级命令。更改运行配置相关设置后，
需重新应用订阅；仅加载脚本不会改写已存在的 `config.yaml`。

服务布局参考 [Mihomo 官方 systemd 文档](https://wiki.metacubex.one/startup/service/)。

## 开发测试

开发测试需要 Python 和 PyYAML。测试使用临时目录及模拟下载、服务响应，
不会操作实际服务或访问网络：

```bash
bash -n mihomo-sub.sh
bash -n install.sh
python3 -m unittest discover -s tests -v
```

安装了 zsh 时，测试也会验证实际 zsh 的命令转发和当前会话代理设置；未安装时
跳过这些检查，其余测试仍会验证 zsh 安装选项和配置文件选择。
