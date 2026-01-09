# Alice Sing-box 8-Exit

一键部署 Sing-box 多协议代理脚本，支持 VLESS / Trojan / Shadowsocks，内置 8 个 SOCKS5 出口分流。

## ✨ 功能特性

- 🚀 支持 **VLESS-WS-TLS** / **Trojan-WS-TLS** / **Shadowsocks 2022**
- 🔀 内置 8 个 SOCKS5 出口，自动分流
- 🔐 支持 **自签名证书**（自动生成）或上传自有证书
- 🌐 支持 **多协议共存**（追加模式）
- 📦 支持 IPv6 优先，适配 Cloudflare 代理
- 📋 一键生成 **Base64 订阅链接**
- 🖥️ 兼容 **Debian / Ubuntu / Alpine** 系统

---

## 📥 一键安装

### 🚀 加速源版（推荐国内使用）

```bash
curl -fsSL https://ghfile.geekertao.top/https://raw.githubusercontent.com/0xdabiaoge/Alice-singbox-8-Exit/main/alice-singbox.sh -o /usr/local/bin/alice && chmod +x /usr/local/bin/alice && alice
```

或使用 wget：

```bash
wget -qO /usr/local/bin/alice https://ghfile.geekertao.top/https://raw.githubusercontent.com/0xdabiaoge/Alice-singbox-8-Exit/main/alice-singbox.sh && chmod +x /usr/local/bin/alice && alice
```

### 🌐 直装版（需要能直连 GitHub）

```bash
curl -fsSL https://raw.githubusercontent.com/0xdabiaoge/Alice-singbox-8-Exit/main/alice-singbox.sh -o /usr/local/bin/alice && chmod +x /usr/local/bin/alice && alice
```

或使用 wget：

```bash
wget -qO /usr/local/bin/alice https://raw.githubusercontent.com/0xdabiaoge/Alice-singbox-8-Exit/main/alice-singbox.sh && chmod +x /usr/local/bin/alice && alice
```

---

## 🎯 快捷命令

安装完成后，随时输入以下命令即可打开管理菜单：

```bash
alice
```

---

## 📖 使用说明

### 菜单一览

```
========================================
   Sing-box IPv6 节点管理脚本 v1.0
========================================

1. 安装/更新 Sing-box

--- 节点管理 ---
2. 添加 VLESS-WS-TLS 节点
3. 添加 Trojan-WS-TLS 节点
4. 添加 Shadowsocks 节点
5. 查看当前节点
6. 删除节点

--- 服务管理 ---
7. 启动服务
8. 停止服务
9. 重启服务
10. 查看服务状态
11. 查看日志

--- 导出 ---
12. 导出节点链接

13. 卸载 Sing-box
0. 退出
```

### 证书配置

添加 VLESS / Trojan 节点时，提供两种证书方式：

1. **自签名证书**（默认）：自动生成，有效期 10 年，适合 Cloudflare 代理场景
2. **上传证书**：使用自有 SSL 证书

> 💡 使用自签名证书时，客户端会自动启用 `allowInsecure=true`

### Cloudflare 配置

如果同时部署多个协议并使用同一域名，需要在 Cloudflare **Origin Rules** 中配置路径分流：

| 协议 | 匹配条件 | 回源端口 |
|------|----------|----------|
| VLESS | Host=`your.domain` AND URI Path contains `/vless` | 50000 |
| Trojan | Host=`your.domain` AND URI Path contains `/trojan` | 59999 |

---

## 📝 更新日志

- **v1.0** - 初始版本
  - 支持 VLESS / Trojan / Shadowsocks 协议
  - 8 个 SOCKS5 出口分流
  - 自签名证书支持
  - 多协议共存

---

## 📜 License

MIT License
