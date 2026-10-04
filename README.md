# Mihomo Manager

`mihomo-sub.sh` 管理 Linux 上的 Mihomo 安装、systemd 服务、订阅、节点和当前
shell 的代理设置。默认操作用户级实例；命令前加 `--system` 操作系统级实例。

需要 Bash 4.2+、jq 1.6+、wget、curl、coreutils、gzip 和 systemd。非 root
用户执行系统级写入时需要 sudo；用户级操作不会使用 sudo。

安装、卸载、systemd、节点和 JSON 操作均不依赖 Python。读取 YAML 订阅或已有
YAML 配置时，优先使用 [mikefarah 的原生 yq v4](https://mikefarah.gitbook.io/yq/)
（Go 单文件程序），不是 Python 版同名 `yq`。也兼容 Python 3 + PyYAML
作为可选备用读取器；没有这两个读取器时，仍可使用 JSON 配置和管理安装／服务。

完全禁止 Python 备用读取时，在 source 前设置：

```bash
export MIHOMO_PYTHON_FALLBACK=0
source ./mihomo-sub.sh
```

可用 `MIHOMO_YQ_BIN=/绝对路径/yq` 指定原生 yq。

默认目录和端口按级别分开，用户级配置、缓存和单元目录尊重 XDG 设置：

| 项目 | 用户级 `--user` | 系统级 `--system` |
| --- | --- | --- |
| 二进制 | `~/.local/bin/mihomo` | `/usr/local/bin/mihomo` |
| 运行配置和数据 | `~/.config/mihomo/` | `/etc/mihomo/` |
| 订阅及管理记录 | `~/.config/mihomo-sub/` | `/etc/mihomo-sub/` |
| 订阅缓存 | `~/.cache/mihomo-sub/` | `/var/cache/mihomo-sub/` |
| systemd 单元 | `~/.config/systemd/user/mihomo.service` | `/etc/systemd/system/mihomo.service` |
| mixed-port | `127.0.0.1:7897` | `127.0.0.1:7898` |
| Controller | `127.0.0.1:9090` | `127.0.0.1:9091` |

安装用户级实例：

```bash
source ./mihomo-sub.sh
mhm --user gh-proxy set 'https://v6.gh-proxy.org/'
mhm --user install                 # 最新正式 Release，也可指定 v版本号
mhm --user register                # 注册并启用 systemctl --user 服务
mhm add demo '订阅URL'
mhm use demo
mhm start
mhm status
mhm node
mhm proxy on
```

安装系统级实例：

```bash
mhm --system gh-proxy set 'https://v6.gh-proxy.org/'
mhm --system install
mhm --system register              # 注册并启用系统 systemd 服务
mhm --system add demo '订阅URL'
mhm --system use demo
mhm --system start
mhm --system status
```

`register` 启用自动启动，但不立即启动服务；没有配置时生成使用 DIRECT 的基础配置。
`use` 会热重载或重启已注册的服务。其他服务命令包括 `stop`、`restart`、`enable`、
`disable`、`logs`，也可写成 `mhm service start`。`status` 显示二进制版本、
路径、服务加载状态、运行状态和自动启动状态；检查状态不会创建数据目录。

用户级服务由用户 systemd 管理器管理。如果需要退出登录后持续运行或开机启动，
可自行执行 `sudo loginctl enable-linger "$USER"`；脚本不会修改 linger 设置。
用户级进程使用当前用户权限，使用 TUN 或特权端口时应选择合适的权限配置或系统级实例。

GitHub 代理前缀可以为空：为空时直接连接 GitHub；非空时，Release 元数据、
二进制、GEO、GitHub 托管订阅，以及配置中规则、provider、面板等 GitHub URL
都会应用当前级别的前缀。非空但格式无效的前缀会报错。

```bash
mhm gh-proxy off                   # 清空当前级别的前缀，改为直连
mhm gh-proxy set ''                # 同上
mhm gh-proxy set 'https://v6.gh-proxy.org/'
mhm gh-proxy reset                 # 恢复 MIHOMO_GH_PROXY_DEFAULT
```

未配置时默认使用 `https://v6.gh-proxy.org/`。可在首次 source 前显式设置
`MIHOMO_GH_PROXY_DEFAULT=''`，让默认模式也使用直连；空值不会被默认前缀替换。
Release 和 GEO 在直连模式下允许 CDN 重定向；非空前缀下禁止自动重定向，
防止代理把客户端重定向回 GitHub。已经应用当前前缀的 URL 不会重复添加。
订阅下载逐跳处理重定向，每跳都会检查 GitHub 域名并应用前缀，最多跟随 10 次。
`MIHOMO_VALIDATE=1` 的完整校验也使用生成后的配置，遵守同一前缀设置。
如果前缀不支持代理 GitHub API，安装会失败，需要更换前缀。

安装自动选择 x86_64 的 amd64-v1/compatible 文件，以及 arm64、armv7、armv6、
386、riscv64 文件。可用 `MIHOMO_RELEASE_ASSET` 指定发行版中的 `.gz` 文件名。
Release 提供 SHA256 digest 时会验证下载文件；解压和版本检查通过后才覆盖二进制。
已有二进制必须匹配本工具的安装记录，外部安装不会被覆盖。

卸载当前级别：

```bash
mhm --user uninstall               # 停止、禁用并移除服务、二进制和本级数据
mhm --system uninstall
mhm --user uninstall --keep-data   # 保留订阅、配置、缓存以便重新安装
```

卸载验证安装记录与文件 SHA256，保留外部安装或被外部修改的二进制／单元。
脚本创建的独立数据目录带有 `.mihomo-manager` 标记，完整清理时会删除这些目录。
对于预先存在的目录，只清理本工具的已知文件并保留其他内容；激活订阅前备份的原配置
会恢复。其他级别的实例、共享 systemd journal、linger 和 shell 启动文件不会被修改。
若手动把脚本加入了 `.bashrc`，卸载后可自行移除对应的 `source` 行。

运行配置通过 YAML／JSON 解析后生成，以 JSON 格式写入 `config.yaml`；JSON
是 YAML 的兼容格式。会保留订阅配置数据，但不保留注释和原始排版。
本机端口、Controller、密钥及 GEO 下载设置覆盖订阅提供的同名设置。
生成的配置文件权限为 `0600`。

可在首次 `source` 前通过 `MIHOMO_SCOPE=user|system` 设置默认级别，通过
`MIHOMO_BIN`、`MIHOMO_UNIT_DIR`、`MIHOMO_SUB_HOME`、`MIHOMO_SUB_CACHE`、
`MIHOMO_CONFIG_TARGET`、`MIHOMO_DATA_DIR`、`MIHOMO_PROXY_PORT`、`MIHOMO_CONTROLLER`
覆盖默认值。路径必须为绝对路径；显式覆盖会应用于两个级别，应为两个实例分别配置
路径和端口。临时 `--system` 调用不会改变已 source 的 shell 的默认级别。

服务布局参考 [Mihomo 官方 systemd 文档](https://wiki.metacubex.one/startup/service/)。

开发测试使用 Python 和 PyYAML；这不是运行脚本的必要依赖。
运行隔离回归检查（不访问网络或操作实际服务）：

```bash
bash -n mihomo-sub.sh
python3 -m unittest discover -s tests -v
```
