# P2 — 出口透明转发接线 Implementation Plan

> **⚠️ 部分作废(2026-06-27:出口仅直出)。** 本计划里的 `pxout` 打 mark / `ip rule` / `table 100` / apply-exit / set-exit / exit 服务**已全部移除**;`setup-egress.sh`→`setup-firewall.sh`(仅建用户 + DoT-only 入站 + 装代理服务),`test_egress_policy.sh`→`test_proxy_policy.sh`。被代理流量经 sniproxy/quic-proxy 后直接走网关默认路由。**以 DESIGN.md §8 为准。** 下文保留作历史记录。

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development / executing-plans. Checkbox steps.
> **Execution note (this run):** Dev box has no Python/Go/Linux — authored and committed but NOT executed. Linux verification is a pending gate (see tests/integration-smoke.md P2 section).

**Goal:** 把现有 sniproxy(TCP 80/443)+ quic-proxy(UDP/QUIC 443)+ pxout 打 mark + 策略路由 table 100 这套出口透明转发接到 P1 的 smartdns 上,实现"被墙/国外域名 → smartdns 返回网关 IP → 客户端连网关 → sniproxy/quic-proxy 读 SNI → 经 pxout 打 mark → table 100 → 出口"。

**Architecture:** 复用旧实现的出口方案,做两处 new-5gpn 适配:(1) sniproxy/quic-proxy 的 SNI 解析器 **hardcode 22.22.22.22**(防回环,绝不指向本机 smartdns);(2) 入站防火墙只开 22/853(DoT-only),不再开公网 53。出口默认 `local`(table 100 空 → 直出);真实隧道(WireGuard/sing-box)留给 P3。

**Tech Stack:** sniproxy(dlundquist,源码编译)、Go 标准库(quic-proxy)、nftables、iproute2、systemd。

## Global Constraints

- 目录根:`new-5gpn/`。沿用 [DESIGN.md](DESIGN.md) 与 P1 的常量:`EXIT_USER=pxout`、`EXIT_MARK=0x1`、`EXIT_TABLE=100`。
- **防回环(硬约束)**:sniproxy `resolver` 与 quic-proxy `-resolver` 默认值都必须是 `22.22.22.22`,**绝不能是 `127.0.0.1` / `[::1]` / 本机 smartdns 的 853/5353**。
- **DoT-only 入站**:nft `input` 链只放行 TCP `{22, 853}`(+ 将来 API 端口)与来自 `172.22.0.0/16` 的 `{80,443}`、`udp 443`;**不得出现 `udp dport 53 accept` 或 `tcp dport 53` 的公网放行**。
- 出口 mark 链逐字复用旧语义:`ip daddr {私网/环回} return`、`th dport 53 return`、`meta skuid "pxout" meta mark set 0x1`。
- IPv4-only:sniproxy `mode ipv4_only`;quic-proxy 只选 IPv4 后端。
- Linux 行末 LF(已由 new-5gpn/.gitattributes 保证)。

## File Structure

```
new-5gpn/
  etc/
    sniproxy.conf                 # resolver=22.22.22.22, user pxout, 通配兜底
    systemd/
      sniproxy.service
      quic-proxy.service
      proxy-gateway-exit.service  # oneshot: 开机重放当前出口
  src/
    quic-proxy.go                 # 复用 + 新增 -resolver(默认22.22.22.22)
  scripts/
    setup-egress.sh               # 建 pxout、写 nft、装 apply-exit、ip rule、装服务
    apply-exit.sh                 # 读 current-exit:local→flush table100;否则 default dev pgw-<exit>
    set-exit.sh                   # 写 current-exit 状态 + 重放(P2 仅支持 local)
  tests/
    test_egress_policy.sh         # 防回环/DoT-only/mark 语义 断言
```

---

### Task 1: sniproxy.conf(解析器 hardcode 22.22.22.22)

**Files:** Create `new-5gpn/etc/sniproxy.conf`；Test `new-5gpn/tests/test_egress_policy.sh`

- [ ] **Step 1: 写 policy 测试(失败)** — 见下方 test_egress_policy.sh 第一段断言(sniproxy resolver=22.22.22.22 且非 127.0.0.1、user pxout、listener 80/443、通配表)。
- [ ] **Step 2: 写 sniproxy.conf**(内容见下)。
- [ ] **Step 3: 跑 `bash tests/test_egress_policy.sh`**,Linux 上应 PASS(本机不跑)。
- [ ] **Step 4: Commit** `feat(new-5gpn): sniproxy.conf with hardcoded 22.22.22.22 resolver`。

`new-5gpn/etc/sniproxy.conf`:
```nginx
# new-5gpn sniproxy — TCP SNI transparent proxy (HTTP 80 / TLS 443), no TLS decrypt.
# Loop-avoidance: resolver is HARDCODED to 22.22.22.22 — must never be this box's
# smartdns (which rewrites foreign domains to the gateway IP -> infinite loop).
user pxout
pidfile /var/run/sniproxy.pid

resolver {
    nameserver 22.22.22.22
    mode ipv4_only
}

error_log {
    syslog daemon
    priority notice
}

listener 0.0.0.0:80  { protocol http; table http_hosts }
listener 0.0.0.0:443 { protocol tls;  table tls_hosts  }

# Wildcard: forward any hostname to itself; the funnel decision is made upstream
# by smartdns (only gateway-IP'd domains ever reach here).
table http_hosts { .* *:80 }
table tls_hosts  { .* *:443 }
```

---

### Task 2: quic-proxy.go(新增 -resolver,默认 22.22.22.22)

**Files:** Create `new-5gpn/src/quic-proxy.go`(复用旧文件,改解析路径)；Modify `tests/test_egress_policy.sh`

复用 [../quic-proxy.go](../quic-proxy.go) 全部内容,仅三处改动:
1. import 增加 `"context"`。
2. 新增 flag:`resolverAddr = flag.String("resolver", "22.22.22.22:53", "Upstream DNS for SNI; MUST NOT be this gateway's smartdns")`。
3. 新增包级 `var dnsResolver *net.Resolver`;在 `main()` `flag.Parse()` 之后构造:
```go
	dnsResolver = &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			d := net.Dialer{Timeout: 5 * time.Second}
			return d.DialContext(ctx, "udp", *resolverAddr)
		},
	}
```
4. `handleNewSession` 中把 `net.LookupIP(sni)` 替换为(其余不变):
```go
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	ips, err := dnsResolver.LookupIP(ctx, "ip4", sni)
	cancel()
```

- [ ] Step 1: 追加 policy 断言:`grep -q 'resolver".*22.22.22.22:53'` 默认值存在,且文件不含 `LookupIP(sni)` 裸调用。
- [ ] Step 2: 写 `new-5gpn/src/quic-proxy.go`(完整内容,见仓库实现)。
- [ ] Step 3: `go vet`/`go build` 在 Linux 上验证(本机无 Go,不跑)。
- [ ] Step 4: Commit `feat(new-5gpn): quic-proxy with hardcoded 22.22.22.22 resolver (loop-avoidance)`。

---

### Task 3: 出口接线(pxout / nft / ip rule / table 100 / apply-exit)

**Files:** Create `scripts/setup-egress.sh`、`scripts/apply-exit.sh`、`scripts/set-exit.sh`、`etc/systemd/proxy-gateway-exit.service`；Modify `tests/test_egress_policy.sh`

- apply-exit.sh:`ip rule add fwmark 0x1 table 100`;`current-exit`=local→`ip route flush table 100`;否则起 `pgw-<exit>`(wg-quick/singbox,P3 提供)并 `ip route replace default dev pgw-<exit> table 100`。
- setup-egress.sh:建 pxout 用户;写 `/etc/nftables.conf`(DoT-only 入站 + pgw_exit mark 链);安装 apply-exit.sh 到 /usr/local/bin;装 proxy-gateway-exit.service;`current-exit` 默认 local。
- set-exit.sh:写 `current-exit` 后调用 apply-exit.sh(P2 仅校验 local;未知名字交 P3)。

- [ ] Step 1: 追加 policy 断言:nft 文本含 `meta skuid "pxout" meta mark set 0x1`、`th dport 53 return`、私网 `return`;input 链含 `tcp dport { 22, 853 }`;**不含** `udp dport 53 accept`、不含 `:53 ` 公网放行。apply-exit 含 `ip rule add fwmark 0x1 table 100` 与 `ip route flush table 100`。
- [ ] Step 2: 写三个脚本 + service(内容见仓库实现)。
- [ ] Step 3: Linux 上 `bash setup-egress.sh` 干跑(本机不跑)。
- [ ] Step 4: Commit `feat(new-5gpn): egress wiring (pxout mark + ip rule table 100 + apply-exit), DoT-only inbound`。

---

### Task 4: systemd 单元(sniproxy / quic-proxy)

**Files:** Create `etc/systemd/sniproxy.service`、`etc/systemd/quic-proxy.service`

- sniproxy.service:`ExecStart=/usr/local/sbin/sniproxy -c /etc/sniproxy.conf -f`,`User=root`(绑低端口后按 conf 降权 pxout),`ExecReload=/bin/kill -HUP $MAINPID`。
- quic-proxy.service:`ExecStart=<bin>/quic-proxy -l :443 -resolver 22.22.22.22:53`,`User=pxout`,`After=network-online.target`。

- [ ] Step 1: policy 断言:quic-proxy.service 的 ExecStart 含 `-resolver 22.22.22.22:53` 且 `User=pxout`;sniproxy.service 含 `-c /etc/sniproxy.conf`。
- [ ] Step 2: 写两个 unit。
- [ ] Step 3: Commit `feat(new-5gpn): systemd units for sniproxy + quic-proxy`。

---

### Task 5: P2 集成冒烟(追加到 integration-smoke.md)

- [ ] 端到端:客户端 DoT 查一个国外域名 → smartdns 返回网关 IP → 浏览器/curl 该域名 → sniproxy 命中 → 经 22.22.22.22 解析真实 IP → pxout 出站(table 100=local 直出)→ 站点可达。
- [ ] QUIC:`curl --http3` 该域名,quic-proxy 命中、可达。
- [ ] 防回环:制造一个"国外"域名,确认 sniproxy/quic-proxy 不会把流量又送回网关 853/自身(日志无自环)。
- [ ] Commit `test(new-5gpn): P2 end-to-end smoke checklist`。

## Self-Review
- 防回环:sniproxy resolver + quic-proxy -resolver 双双 hardcode 22.22.22.22 ✓(Task1/2 + policy 断言)。
- DoT-only 入站:nft input 不开公网 53 ✓(Task3 断言)。
- mark 语义逐字复用 ✓(Task3)。出口默认 local 直出、隧道留 P3 ✓。
- 未执行声明:全程标注 Linux 验证待办 ✓。
