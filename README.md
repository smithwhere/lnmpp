# LNMPP

面向 Debian 12/13/14（包括当前的 Debian 14 testing）和 Ubuntu 22.04/24.04/26.04 的 LNMPP 安装与站点管理脚本。首次安装会配置 Nginx、MariaDB、PHP-FPM、phpMyAdmin、Supervisor 和 vsftpd。需要 root 权限及 systemd；请在新服务器上运行。


一键命令：
```bash
wget -O install.sh https://raw.githubusercontent.com/smithwhere/lnmpp/refs/heads/main/install.sh && bash install.sh
```

```bash
git clone https://github.com/smithwhere/lnmpp.git
cd lnmpp
sudo bash install.sh
```

安装完成后，终端会显示 `LNMPP安装成功。`、随机生成的 phpMyAdmin 用户名及密码（各 10 位，均含大小写字母、数字和特殊字符）。凭据另保存在仅 root 可读的 `/etc/lnmpp/phpmyadmin-credentials`。phpMyAdmin 位于 `http://服务器IP/phpmyadmin/`，随机账号具有数据库管理权限；也可以使用 `root` 和输出的同一密码登录。默认允许任意 IP 访问 Web 登录；可用下述命令停用远程访问。MariaDB 默认仍只监听本机，脚本没有开放数据库 TCP 远程连接。

**安全提示：** 初装后的 phpMyAdmin 是公开 HTTP 页面，网络中途可观察登录凭据。由于安装时尚无域名证书，请先通过 SSH 隧道访问，或在可信网络内完成网站和证书设置；不要在不可信网络中直接输入 root 密码。Supervisor 的 HTTP 控制接口同样不加密，且使用固定账号密码，公开到互联网会带来严重风险；请优先通过防火墙或云安全组限制来源 IP，并考虑使用 SSH 隧道。安装中断后重试会复用已保存的数据库凭据。

```bash
sudo bash install.sh stop phpmyadmin
sudo bash install.sh start phpmyadmin
```

`stop` 会让外部 IP 访问 LNMPP 管理的默认站点及网站的 `/phpmyadmin` 路径时收到 403；服务器本机的 `127.0.0.1` 和 `::1` 仍可访问，网站其他路径不受影响。`start` 恢复外部访问。命令不会删除账号或数据库，重复执行也有效。已有安装可先在仓库运行 `git pull`，再执行上述命令；切换时会重新生成脚本管理的 Nginx 站点配置，不会修改其他站点配置。

Supervisor 在 `/etc/supervisor/supervisord.conf` 的 `[inet_http_server]` 段配置 `port=*:8000`、`username=admin`、`password=password`，监听所有网卡。Nginx、MariaDB、PHP-FPM 分别以 `nginx`、`mariadb`、`php-fpm` 进程名由 Supervisor 接管。服务器防火墙和云安全组允许 TCP 8000 后，可打开 `http://服务器IP:8000/`。更安全的访问方式是限制公网来源 IP，或不开放公网 8000 端口并使用 SSH 转发：

```bash
ssh -L 8000:127.0.0.1:8000 root@服务器IP
```

然后在本机打开 `http://127.0.0.1:8000/`。已有安装仅执行 `git pull` 不会修改正在运行的 Supervisor 配置；请在服务器上编辑 `/etc/supervisor/supervisord.conf`，把 `[inet_http_server]` 段的 `port` 改为 `*:8000`，再执行 `sudo systemctl restart supervisor`。重启会短暂中断其托管的进程。

## 网站

```bash
sudo bash install.sh add 'example.com\*.example.com' /var/www/example.com
sudo bash install.sh add example.com /var/www/example.com
```

反斜杠 `\` 是普通域名和泛域名的分隔符；请用单引号包裹带泛域名的参数。泛域名必须是同一主域的 `*.example.com`。成功后输出 `网站成功创建完成`。脚本创建网站目录及 Nginx 站点配置；域名的 DNS 解析需要自行设置。

## 数据库

```bash
sudo bash install.sh add db dbname username 'password'
```

用户名仅供本机连接，成功后输出 `数据库成功创建完成`。含 shell 特殊字符的密码请加引号。

## SSL

先添加网站，再添加证书。使用 Cloudflare DNS API Token 完成 DNS 验证；Token 需要对应区域的 DNS 编辑权限。

```bash
sudo bash install.sh add ssl 70 cloudflare 'example.com\*.example.com' 'CLOUDFLARE_TOKEN'
sudo bash install.sh add ssl 70 cloudflare example.com 'CLOUDFLARE_TOKEN'
```

`70` 表示距离到期不足 70 天时续期，可改为 1–89。成功后输出 `ssl证书成功创建完成`。脚本每天检查一次已启用站点的证书。启用 SSL 的网站会将 HTTP 重定向到 HTTPS，并可通过 `https://example.com/phpmyadmin/` 安全登录。Token 保存在仅 root 可读的 `/etc/lnmpp/sites/<域名>/cf-token`。签发依赖域名解析、Cloudflare API 和 Let's Encrypt 可用。

```bash
sudo bash install.sh stop ssl example.com
sudo bash install.sh start ssl example.com
sudo bash install.sh stop ssl
sudo bash install.sh start ssl
```

省略域名会处理脚本管理的全部 SSL 站点。停用关闭对应 HTTPS 配置并跳过续期，不删除证书；启用恢复 HTTPS 配置和每日续期。

## FTP

```bash
sudo bash install.sh add ftp username 'password'
```

FTP 用户默认绑定 `/var/www/html`；成功后输出 `ftp成功创建完成`。vsftpd 使用 21 端口及被动端口 40000–40100，需按需放行防火墙。服务器要求显式 FTPS 加密登录和数据连接，只允许脚本创建的 FTP 用户登录。安装时生成自签名 FTPS 证书；首次连接时请核对并信任该证书。

## 检查

```bash
sudo supervisorctl -c /etc/supervisor/supervisord.conf status
sudo nginx -t
sudo systemctl status lnmpp-ssl-renew.timer
```

开发检查：`bash -n install.sh tests/run.sh && shellcheck -x install.sh tests/run.sh && bash tests/run.sh`。CI 在六个目标发行版容器中运行语法、ShellCheck 和行为测试，并在临时 Ubuntu 24.04 主机上执行实际安装及网站、数据库、FTP 命令；其它发行版的完整安装和依赖真实 DNS 的签发仍需在目标服务器验证。日志消息没有 `[lnmpp]` 前缀。
