# nat_forward

一个面向 Linux 服务器的 NAT 端口转发管理脚本，适合游戏联机、UDP 转发、临时端口映射等场景。

脚本通过内核 NAT 能力配置 `DNAT + MASQUERADE`，优先使用 `nftables`，不可用时回退到 `iptables`，并支持：

- 交互式添加、删除、查看转发规则
- TCP、UDP、TCP+UDP 三种协议模式
- 基于 `tc flower/police` 的上下行限速
- 按上行、下行、总流量自动停用规则
- 规则导出 / 导入
- 开机自动恢复规则
- 定时检查流量阈值并自动禁用超限规则

## 适用环境

- Debian / Ubuntu 或其他基于 `apt` 的发行版
- `systemd`
- root 权限
- 内核支持 `nftables` 或 `iptables`
- 需要时可安装 `iproute2`（用于 `tc` 限速）

脚本会在运行过程中按需自动安装依赖，包括：

- `nftables`
- `iptables`
- `iproute2`
- `procps`

## 重要说明

这个脚本的目标是“尽量开放型 NAT / best-effort Full Cone NAT”方向的实现，但不保证在所有网络环境下都会被严格判定为 Full Cone NAT。

实际 NAT 类型还会受到这些因素影响：

- 运营商是否存在 CGNAT
- 上级路由器或云厂商网络策略
- 安全组 / ACL
- `rp_filter`
- 内核与驱动能力
- NAT 测试平台的判定标准

如果你的公网出口本身不具备可达性，单纯做端口转发也无法解决。

## 快速开始

给脚本执行权限并直接运行：

```bash
chmod +x nat_forward.sh
sudo ./nat_forward.sh
```

首次进入后，脚本会显示交互菜单，你可以按提示：

1. 添加转发规则
2. 删除转发规则
3. 查看当前规则
4. 查看当前 NAT / 转发状态
5. 导出规则
6. 导入规则
7. 卸载全部规则和持久化配置
8. 退出

当你第一次添加规则或导入规则时，脚本会自动：

- 创建持久化目录 `/etc/game-nat-forward`
- 开启 `net.ipv4.ip_forward=1`
- 安装 systemd 服务和定时器
- 将当前脚本复制到 `/usr/local/sbin/game_nat_forward.sh`

## 规则说明

每条规则包含这些字段：

- 协议模式：`tcp`、`udp`、`tcp+udp`
- 外部端口：入口监听端口
- 目标 IP：内网服务器地址
- 目标端口：内网服务端口
- 出口网卡：如 `eth0`
- 上行限速：单位 `kbit/s`，`0` 表示不限速
- 下行限速：单位 `kbit/s`，`0` 表示不限速
- 上行累计流量限制：单位字节，`0` 表示不限制
- 下行累计流量限制：单位字节，`0` 表示不限制
- 最大累计流量限制：单位字节，`0` 表示不启用
- 最大累计流量判定模式：`none`、`either`、`up`、`down`、`sum`

当规则达到流量阈值后，定时检查任务会自动把该规则标记为禁用，并重新下发 NAT 规则。

## 后端与实现方式

NAT 后端选择逻辑：

- 优先使用 `nftables`
- 如果 `nftables` 不可用，则回退到 `iptables`
- 已选择的后端会持久化保存，避免每次切换

规则下发方式：

- `PREROUTING` 上做 `DNAT`
- `POSTROUTING` 上做 `MASQUERADE`
- `FORWARD` 链放行对应流量
- 限速使用 `tc flower + police`

## 常用命令

交互模式：

```bash
sudo ./nat_forward.sh
```

查看规则：

```bash
sudo ./nat_forward.sh --show-rules
```

查看状态：

```bash
sudo ./nat_forward.sh --status
```

导出规则：

```bash
sudo ./nat_forward.sh --export
```

导入规则：

```bash
sudo ./nat_forward.sh --import
```

卸载全部规则和持久化配置：

```bash
sudo ./nat_forward.sh --uninstall
```

下面两个参数通常由 systemd 内部调用：

```bash
sudo ./nat_forward.sh --restore
sudo ./nat_forward.sh --check-limits
```

## 导出 / 导入

导出文件会带有头信息，正文格式为：

```text
id|protocol_mode|external_port|target_ip|target_port|iface|up_rate_kbit|down_rate_kbit|up_total_limit_bytes|down_total_limit_bytes|max_total_limit_bytes|max_total_mode|disabled_reason
```

导入支持两种模式：

- `merge`：合并导入，跳过重复规则
- `replace`：用导入文件替换现有规则

## 持久化文件

脚本会使用以下文件：

- `/etc/game-nat-forward/rules.db`
- `/etc/game-nat-forward/stats.db`
- `/etc/game-nat-forward/tc_state.db`
- `/etc/game-nat-forward/backend.conf`
- `/etc/game-nat-forward/nftables-game-nat.nft`
- `/etc/sysctl.d/99-game-nat-forward.conf`
- `/usr/local/sbin/game_nat_forward.sh`

以及这些 systemd 单元：

- `game_nat_forward.service`
- `game_nat_forward_check.service`
- `game_nat_forward_check.timer`

## 限制与注意事项

- 当前实现依赖 `apt-get`，不适合直接在 CentOS、Alpine 等环境使用
- 必须以 root 身份运行
- IPv4 转发会被启用
- 限速是 best-effort，不代表精确整形
- 删除脚本创建的持久化配置时，不会强制回退当前运行中的 `net.ipv4.ip_forward`
- 如果出口网络本身有上游 NAT 或策略限制，端口映射效果会受到影响

## 仓库内容

- `nat_forward.sh`：主脚本

如果你准备把它用于长期运行的生产环境，建议先在测试机验证：

- 转发是否生效
- NAT 类型是否满足预期
- 限速是否符合业务需求
- 流量累计停用逻辑是否符合你的场景

## 流量限制说明

- 上行限速：单位 `kbit/s`，`0` 表示不限速
- 下行限速：单位 `kbit/s`，`0` 表示不限速
- 上行累计流量限制：单位字节，`0` 表示不限制，按上行累计计算，满足条件后暂停转发
- 下行累计流量限制：单位字节，`0` 表示不限制，按下行累计计算，满足条件后暂停转发
- 最大累计流量限制：单位字节，`0` 表示不启用，按上下双向 `sum` 累计计算，满足条件后暂停转发
- 累计流量输入支持直接写 `100G`，脚本会自动换算为字节后保存

## License

MIT，详见 `LICENSE`。
