#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STATE_DIR=/etc/lnmpp
SITES_DIR=$STATE_DIR/sites
CERT_DIR=$STATE_DIR/certs
SUPERVISOR_CONF=/etc/supervisor/supervisord.conf
NGINX_DIR=${LNMPP_NGINX_DIR:-/etc/nginx}
ACME_HOME=/opt/lnmpp/acme
SCRIPT_PATH=/usr/local/lib/lnmpp/install.sh

die() { printf '%s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die '请使用 root 执行。'; }

usage() {
    cat <<'EOF'
用法:
  bash install.sh
  bash install.sh add 'example.com\*.example.com' /var/www/example.com
  bash install.sh add example.com /var/www/example.com
  bash install.sh add db dbname username password
  bash install.sh add ssl 70 cloudflare 'example.com\*.example.com' token
  bash install.sh add ftp username password
  bash install.sh stop ssl [example.com]
  bash install.sh start ssl [example.com]
  bash install.sh stop phpmyadmin
  bash install.sh start phpmyadmin
EOF
}

check_os() {
    local os_file=${OS_RELEASE_FILE:-/etc/os-release} version debian_file=${DEBIAN_VERSION_FILE:-/etc/debian_version}
    [[ -r $os_file ]] || die '无法读取系统版本。'
    # shellcheck disable=SC1090
    source "$os_file"
    version=${VERSION_ID:-}
    if [[ ${ID:-} == debian && -z $version && -r $debian_file ]]; then
        case $(<"$debian_file") in
            forky|forky/sid) version=14 ;;
        esac
    fi
    case "${ID:-}:$version" in
        debian:12|debian:13|debian:14|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) ;;
        *) die "不支持的系统：${ID:-unknown} ${VERSION_ID:-unknown}" ;;
    esac
    command -v systemctl >/dev/null || die '需要 systemd。'
}

valid_domain() {
    local label='[a-z0-9]([a-z0-9-]*[a-z0-9])?'
    [[ ${#1} -le 253 && $1 =~ ^${label}(\.${label})+$ ]]
}

parse_domains() {
    local spec=${1,,} tail
    PRIMARY_DOMAIN=
    WILDCARD_DOMAIN=
    if [[ $spec == *\\* ]]; then
        PRIMARY_DOMAIN=${spec%%\\*}
        tail=${spec#*\\}
        [[ -n $tail && $tail != *\\* ]] || return 1
        WILDCARD_DOMAIN=$tail
    else
        PRIMARY_DOMAIN=$spec
    fi
    valid_domain "$PRIMARY_DOMAIN" || return 1
    if [[ -n $WILDCARD_DOMAIN ]]; then
        [[ $WILDCARD_DOMAIN == "*.$PRIMARY_DOMAIN" ]] || return 1
    fi
}

validate_renew_days() {
    [[ $1 =~ ^[0-9]+$ && $1 -ge 1 && $1 -le 89 ]]
}

valid_identifier() { [[ ${#1} -le 64 && $1 =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; }
valid_ftp_user() { [[ ${#1} -le 32 && $1 =~ ^[a-z_][a-z0-9_-]*$ ]]; }
valid_webroot() { [[ $1 =~ ^/[a-zA-Z0-9_./-]+$ && $1 != / && $1 != *'/../'* && $1 != */.. ]]; }

sql_escape() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\'/\'\'}
    printf '%s' "$value"
}

random_ten() {
    python3 - <<'PY'
import secrets
import string
alphabet = string.ascii_lowercase + string.ascii_uppercase + string.digits + '!@#%^&*_-'
chars = [secrets.choice(string.ascii_lowercase), secrets.choice(string.ascii_uppercase),
         secrets.choice(string.digits), secrets.choice('!@#%^&*_-')]
chars += [secrets.choice(alphabet) for _ in range(6)]
secrets.SystemRandom().shuffle(chars)
print(''.join(chars))
PY
}

php_version() {
    php -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;'
}

pma_access_file() { printf '%s/conf.d/lnmpp-phpmyadmin-access.conf' "$NGINX_DIR"; }

render_pma_access_config() {
    local mode=$1
    cat <<'EOF'
geo $lnmpp_pma_remote {
    default 1;
    127.0.0.1 0;
    ::1 0;
}
map "$lnmpp_pma_remote:$uri" $lnmpp_pma_denied {
    default 0;
EOF
    if [[ $mode == stop ]]; then
        cat <<'EOF'
    ~^1:/phpmyadmin(?:/|$) 1;
EOF
    fi
    printf '}\n'
}

ensure_pma_access_config() {
    local temp pma_conf
    pma_conf=$(pma_access_file)
    [[ -f $pma_conf ]] && return 0
    install -d -m 755 "$NGINX_DIR/conf.d"
    temp=$(mktemp "$NGINX_DIR/conf.d/.lnmpp-pma.XXXXXX")
    render_pma_access_config stop > "$temp"
    install -m 644 "$temp" "$pma_conf"
    rm -f "$temp"
}

render_site_config() {
    local domain=$1 wildcard=$2 webroot=$3 ssl=$4 version=$5
    local server_names=$domain
    [[ -z $wildcard ]] || server_names+=" $wildcard"
    if [[ $ssl == 1 ]]; then
        cat <<EOF
server {
    listen 80;
    server_name $server_names;
    if (\$lnmpp_pma_denied) { return 403; }
    return 301 https://\$host\$request_uri;
}
EOF
    fi
    cat <<EOF
server {
EOF
    if [[ $ssl == 1 ]]; then
        cat <<EOF
    listen 443 ssl;
    ssl_certificate $CERT_DIR/$domain/fullchain.pem;
    ssl_certificate_key $CERT_DIR/$domain/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
EOF
    else
        cat <<EOF
    listen 80;
EOF
    fi
    cat <<EOF
    server_name $server_names;
    root $webroot;
    index index.php index.html;
    if (\$lnmpp_pma_denied) { return 403; }
EOF
    cat <<EOF
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \\.php\$ {
        try_files \$uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:/run/php/php$version-fpm.sock;
    }
    location ~ /\\. { deny all; }
}
EOF
}

site_file() { printf '%s/sites-available/lnmpp-%s.conf' "$NGINX_DIR" "$1"; }
site_state() { printf '%s/%s' "$SITES_DIR" "$1"; }

read_site() {
    local domain=$1 dir
    dir=$(site_state "$domain")
    [[ -d $dir ]] || die "网站不存在：$domain"
    SITE_WILDCARD=$(<"$dir/wildcard")
    SITE_WEBROOT=$(<"$dir/webroot")
    SITE_SSL=$(<"$dir/ssl-enabled")
}

write_site_config() {
    local domain=$1 wildcard=$2 webroot=$3 ssl=$4 path temp backup='' link
    ensure_pma_access_config
    path=$(site_file "$domain")
    link=$NGINX_DIR/sites-enabled/lnmpp-$domain.conf
    temp=$(mktemp "$NGINX_DIR/sites-available/.lnmpp.XXXXXX")
    render_site_config "$domain" "$wildcard" "$webroot" "$ssl" "$(php_version)" > "$temp"
    if [[ -f $path ]]; then
        backup=$(mktemp "$NGINX_DIR/sites-available/.lnmpp-backup.XXXXXX")
        cp -p "$path" "$backup"
    fi
    install -m 644 "$temp" "$path"
    rm -f "$temp"
    [[ -e $link || -L $link ]] || ln -s "$path" "$link"
    if ! nginx -t; then
        if [[ -n $backup ]]; then
            cp -p "$backup" "$path"
        else
            rm -f "$link" "$path"
        fi
        [[ -z $backup ]] || rm -f "$backup"
        die 'Nginx 配置验证失败，已恢复原配置。'
    fi
    [[ -z $backup ]] || rm -f "$backup"
    if supervisorctl -c "$SUPERVISOR_CONF" status nginx 2>/dev/null | grep -q RUNNING; then
        supervisorctl -c "$SUPERVISOR_CONF" signal HUP nginx >/dev/null
    fi
}

add_site() {
    local spec=$1 webroot=$2 dir
    parse_domains "$spec" || die '域名格式无效；泛域名请用单个反斜杠分隔。'
    valid_webroot "$webroot" || die '网站路径必须是安全的绝对路径。'
    dir=$(site_state "$PRIMARY_DOMAIN")
    [[ ! -e $dir ]] || die "网站已存在：$PRIMARY_DOMAIN"
    install -d -m 755 "$webroot"
    write_site_config "$PRIMARY_DOMAIN" "$WILDCARD_DOMAIN" "$webroot" 0
    install -d -m 700 "$dir"
    printf '%s' "$WILDCARD_DOMAIN" > "$dir/wildcard"
    printf '%s' "$webroot" > "$dir/webroot"
    printf '0' > "$dir/ssl-enabled"
    say '网站成功创建完成'
}

add_db() {
    local db=$1 username=$2 password=$3 escaped
    valid_identifier "$db" || die '数据库名无效。'
    valid_identifier "$username" || die '数据库用户名无效。'
    [[ -n $password && $password != *$'\n'* && $password != *$'\r'* ]] || die '数据库密码无效。'
    if [[ $(mariadb --batch --skip-column-names -e "SELECT COUNT(*) FROM mysql.user WHERE User='$(sql_escape "$username")' AND Host='localhost'") != 0 ]]; then
        die '数据库用户已存在。'
    fi
    if [[ $(mariadb --batch --skip-column-names -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$(sql_escape "$db")'") != 0 ]]; then
        die '数据库已存在。'
    fi
    escaped=$(sql_escape "$password")
    mariadb <<SQL
CREATE DATABASE \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$username'@'localhost' IDENTIFIED BY '$escaped';
GRANT ALL PRIVILEGES ON \`$db\`.* TO '$username'@'localhost';
SQL
    say '数据库成功创建完成'
}

add_ftp() {
    local username=$1 password=$2
    valid_ftp_user "$username" || die 'FTP 用户名无效。'
    [[ -n $password && $password != *$'\n'* && $password != *$'\r'* && $password != *:* ]] || die 'FTP 密码无效。'
    id "$username" >/dev/null 2>&1 && die 'FTP 用户已存在。'
    useradd -M -d /var/www/html -s /usr/sbin/nologin -G www-data "$username"
    if ! printf '%s:%s\n' "$username" "$password" | chpasswd; then
        userdel "$username"
        die '设置 FTP 密码失败。'
    fi
    printf '%s\n' "$username" >> "$STATE_DIR/ftp-users"
    say 'ftp成功创建完成'
}

ensure_acme() {
    local tmp
    [[ -x $ACME_HOME/acme.sh ]] && return 0
    tmp=$(mktemp -d)
    git clone --depth 1 https://github.com/acmesh-official/acme.sh.git "$tmp/source"
    (cd "$tmp/source" && bash ./acme.sh --install --home "$ACME_HOME" --config-home "$ACME_HOME" --nocron)
    rm -rf -- "$tmp"
    [[ -x $ACME_HOME/acme.sh ]] || die '安装 acme.sh 失败。'
}

add_ssl() {
    local days=$1 provider=$2 spec=$3 token=$4 domain dir pma_link
    validate_renew_days "$days" || die '续期阈值必须是 1 到 89 天。'
    [[ $provider == cloudflare ]] || die '当前仅支持 cloudflare。'
    [[ -n $token && $token != *$'\n'* && $token != *$'\r'* ]] || die 'Cloudflare Token 无效。'
    parse_domains "$spec" || die 'SSL 域名格式无效。'
    domain=$PRIMARY_DOMAIN
    dir=$(site_state "$domain")
    [[ -d $dir ]] || die '请先用 add 创建网站。'
    read_site "$domain"
    [[ $SITE_SSL == 0 ]] || die '该站点已启用 SSL。'
    [[ -z $SITE_WILDCARD || $SITE_WILDCARD == "$WILDCARD_DOMAIN" ]] || \
        die '网站包含泛域名，SSL 证书也必须包含相同泛域名。'
    pma_link=$SITE_WEBROOT/phpmyadmin
    if [[ -e $pma_link || -L $pma_link ]]; then
        [[ -L $pma_link && $(readlink "$pma_link") == /usr/share/phpmyadmin ]] || \
            die '网站目录中已有 phpmyadmin 路径，无法提供 HTTPS phpMyAdmin。'
    fi
    ensure_acme
    install -d -m 700 "$CERT_DIR/$domain"
    local -a names=(-d "$domain")
    [[ -z $WILDCARD_DOMAIN ]] || names+=(-d "$WILDCARD_DOMAIN")
    CF_Token=$token "$ACME_HOME/acme.sh" --issue --server letsencrypt --dns dns_cf --days "-$days" "${names[@]}"
    "$ACME_HOME/acme.sh" --install-cert --server letsencrypt -d "$domain" \
        --key-file "$CERT_DIR/$domain/key.pem" \
        --fullchain-file "$CERT_DIR/$domain/fullchain.pem"
    chmod 600 "$CERT_DIR/$domain/key.pem"
    [[ -L $pma_link ]] || ln -s /usr/share/phpmyadmin "$pma_link"
    write_site_config "$domain" "$WILDCARD_DOMAIN" "$SITE_WEBROOT" 1
    printf '%s' "$WILDCARD_DOMAIN" > "$dir/wildcard"
    printf '%s' "$days" > "$dir/renew-days"
    printf '%s' "$token" > "$dir/cf-token"
    printf '1' > "$dir/ssl-enabled"
    chmod 600 "$dir"/*
    say 'ssl证书成功创建完成'
}

toggle_ssl_one() {
    local mode=$1 domain=$2 dir target token
    valid_domain "$domain" || die '域名格式无效。'
    read_site "$domain"
    dir=$(site_state "$domain")
    [[ -f $dir/renew-days && -f $dir/cf-token ]] || die "站点没有脚本管理的证书：$domain"
    if [[ $mode == start ]]; then
        [[ -s $CERT_DIR/$domain/fullchain.pem && -s $CERT_DIR/$domain/key.pem ]] || die "证书文件缺失：$domain"
        if ! openssl x509 -in "$CERT_DIR/$domain/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1; then
            token=$(<"$dir/cf-token")
            CF_Token=$token "$ACME_HOME/acme.sh" --renew --force --server letsencrypt -d "$domain" || \
                die "证书已过期且续期失败：$domain"
            openssl x509 -in "$CERT_DIR/$domain/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1 || \
                die "续期后证书仍不可用：$domain"
        fi
        target=1
    else
        target=0
    fi
    [[ $SITE_SSL != "$target" ]] || return 0
    write_site_config "$domain" "$SITE_WILDCARD" "$SITE_WEBROOT" "$target"
    printf '%s' "$target" > "$dir/ssl-enabled"
}

toggle_ssl() {
    local mode=$1 domain=${2:-} dir count=0
    if [[ -n $domain ]]; then
        toggle_ssl_one "$mode" "${domain,,}"
    else
        for dir in "$SITES_DIR"/*; do
            [[ -d $dir && -f $dir/renew-days ]] || continue
            toggle_ssl_one "$mode" "${dir##*/}"
            count=$((count + 1))
        done
        say "已处理 $count 个 SSL 站点。"
    fi
}

renew_all() {
    local dir domain token status=0
    [[ -x $ACME_HOME/acme.sh ]] || return 0
    for dir in "$SITES_DIR"/*; do
        [[ -d $dir && -f $dir/ssl-enabled && -f $dir/cf-token ]] || continue
        [[ $(<"$dir/ssl-enabled") == 1 ]] || continue
        domain=${dir##*/}
        token=$(<"$dir/cf-token")
        if CF_Token=$token "$ACME_HOME/acme.sh" --renew --server letsencrypt -d "$domain"; then
            supervisorctl -c "$SUPERVISOR_CONF" signal HUP nginx >/dev/null
        else
            # acme.sh returns 2 when a certificate is not yet due for renewal.
            local result=$?
            if [[ $result -ne 2 ]]; then
                printf '证书续期失败：%s\n' "$domain" >&2
                status=1
            fi
        fi
    done
    return "$status"
}

configure_supervisor() {
    install -d -m 755 /var/log/supervisor
    python3 - "$SUPERVISOR_CONF" <<'PY'
from pathlib import Path
import re
import sys
path = Path(sys.argv[1])
data = path.read_text()
section = '[inet_http_server]\nport=*:8000\nusername=admin\npassword=password\n'
pattern = r'(?ms)^\[inet_http_server\][^\[]*(?=^\[|\Z)'
if re.search(pattern, data):
    data = re.sub(pattern, section, data, count=1)
else:
    data += '\n' + section
if '[include]' not in data:
    data += '\n[include]\nfiles = /etc/supervisor/conf.d/*.conf\n'
path.write_text(data)
PY
    chmod 600 "$SUPERVISOR_CONF"
    local version
    version=$(php_version)
    cat > /etc/supervisor/conf.d/lnmpp.conf <<EOF
[program:nginx]
command=/usr/sbin/nginx -g 'daemon off;'
autostart=true
autorestart=true
priority=20
stdout_logfile=/var/log/supervisor/nginx.log
stderr_logfile=/var/log/supervisor/nginx-error.log

[program:mariadb]
command=/usr/sbin/mariadbd --user=mysql --console
autostart=true
autorestart=true
priority=10
stdout_logfile=/var/log/supervisor/mariadb.log
stderr_logfile=/var/log/supervisor/mariadb-error.log

[program:php-fpm]
command=/usr/sbin/php-fpm$version -F
autostart=true
autorestart=true
priority=15
stdout_logfile=/var/log/supervisor/php-fpm.log
stderr_logfile=/var/log/supervisor/php-fpm-error.log
EOF
    chmod 644 /etc/supervisor/conf.d/lnmpp.conf
    printf 'd /run/mysqld 0755 mysql mysql -\n' > /etc/tmpfiles.d/lnmpp-mariadb.conf
    printf 'd /run/php 0755 root root -\n' > /etc/tmpfiles.d/lnmpp-php.conf
    systemd-tmpfiles --create /etc/tmpfiles.d/lnmpp-mariadb.conf
    systemd-tmpfiles --create /etc/tmpfiles.d/lnmpp-php.conf
}

configure_nginx_default() {
    local default=/etc/nginx/sites-enabled/default
    ensure_pma_access_config
    install -d -m 755 /var/www/html
    if [[ -e $default || -L $default ]]; then
        [[ -L $default && $(readlink "$default") == /etc/nginx/sites-available/default ]] || \
            die '已有自定义 Nginx 默认站点，请先手动迁移。'
        rm -f "$default"
    fi
    render_site_config _ '' /var/www/html 0 "$(php_version)" > /etc/nginx/sites-available/lnmpp-default.conf
    chmod 644 /etc/nginx/sites-available/lnmpp-default.conf
    ln -sfn /etc/nginx/sites-available/lnmpp-default.conf /etc/nginx/sites-enabled/lnmpp-default.conf
    if [[ -e /var/www/html/phpmyadmin && ! -L /var/www/html/phpmyadmin ]]; then
        die '/var/www/html/phpmyadmin 已存在，无法创建链接。'
    fi
    ln -sfn /usr/share/phpmyadmin /var/www/html/phpmyadmin
    nginx -t
}

toggle_phpmyadmin_remote() {
    local mode=$1 tmp dir domain i failed=0
    local -a paths=("$(pma_access_file)" "$NGINX_DIR/sites-available/lnmpp-default.conf")
    [[ -f ${paths[1]} ]] || die 'LNMPP 默认站点配置不存在。'
    for dir in "$SITES_DIR"/*; do
        [[ -d $dir ]] || continue
        domain=${dir##*/}
        [[ -f $(site_file "$domain") ]] || die "网站配置不存在：$domain"
        paths+=("$(site_file "$domain")")
    done
    install -d -m 755 "$NGINX_DIR/conf.d"
    tmp=$(mktemp -d "$STATE_DIR/.pma-toggle.XXXXXX")
    render_pma_access_config "$mode" > "$tmp/new-0"
    render_site_config _ '' /var/www/html 0 "$(php_version)" > "$tmp/new-1"
    i=2
    for dir in "$SITES_DIR"/*; do
        [[ -d $dir ]] || continue
        domain=${dir##*/}
        read_site "$domain"
        render_site_config "$domain" "$SITE_WILDCARD" "$SITE_WEBROOT" "$SITE_SSL" "$(php_version)" > "$tmp/new-$i"
        i=$((i + 1))
    done
    for ((i=0; i<${#paths[@]}; i++)); do
        [[ ! -f ${paths[i]} ]] || cp -p "${paths[i]}" "$tmp/old-$i"
    done
    for ((i=0; i<${#paths[@]}; i++)); do
        if ! install -m 644 "$tmp/new-$i" "${paths[i]}"; then
            failed=1
            break
        fi
    done
    if ((failed == 0)) && ! nginx -t; then failed=1; fi
    if ((failed == 0)) && ! supervisorctl -c "$SUPERVISOR_CONF" signal HUP nginx >/dev/null; then failed=1; fi
    if ((failed != 0)); then
        for ((i=0; i<${#paths[@]}; i++)); do
            if [[ -f $tmp/old-$i ]]; then
                cp -p "$tmp/old-$i" "${paths[i]}"
            else
                rm -f "${paths[i]}"
            fi
        done
        rm -rf -- "$tmp"
        die 'Nginx 配置切换失败，已恢复原配置。'
    fi
    rm -rf -- "$tmp"
    if [[ $mode == stop ]]; then
        say 'phpMyAdmin远程访问已停用。'
    else
        say 'phpMyAdmin远程访问已启用。'
    fi
}

configure_ftp() {
    install -d -m 700 "$STATE_DIR/ftp"
    touch "$STATE_DIR/ftp-users"
    chmod 600 "$STATE_DIR/ftp-users"
    if [[ ! -s $STATE_DIR/ftp/cert.pem || ! -s $STATE_DIR/ftp/key.pem ]]; then
        openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
            -subj '/CN=lnmpp-ftp' \
            -keyout "$STATE_DIR/ftp/key.pem" -out "$STATE_DIR/ftp/cert.pem" >/dev/null 2>&1
        chmod 600 "$STATE_DIR/ftp/key.pem"
    fi
    if [[ -e /etc/vsftpd.conf && ! -e /etc/vsftpd.conf.lnmpp-original ]]; then
        cp -p /etc/vsftpd.conf /etc/vsftpd.conf.lnmpp-original
    fi
    cat > /etc/vsftpd.conf <<'EOF'
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=002
chroot_local_user=YES
allow_writeable_chroot=YES
local_root=/var/www/html
pam_service_name=vsftpd
userlist_enable=YES
userlist_deny=NO
userlist_file=/etc/lnmpp/ftp-users
ssl_enable=YES
force_local_logins_ssl=YES
force_local_data_ssl=YES
ssl_sslv2=NO
ssl_sslv3=NO
ssl_tlsv1=NO
ssl_ciphers=HIGH
rsa_cert_file=/etc/lnmpp/ftp/cert.pem
rsa_private_key_file=/etc/lnmpp/ftp/key.pem
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
EOF
    if ! grep -Fxq /usr/sbin/nologin /etc/shells; then
        printf '/usr/sbin/nologin\n' >> /etc/shells
    fi
    install -d -o root -g www-data -m 2775 /var/www/html
    systemctl enable --now vsftpd
    systemctl restart vsftpd
}

load_or_create_pma_credentials() {
    local credentials temp
    credentials=$STATE_DIR/phpmyadmin-credentials
    PMA_USERNAME=root
    if [[ -s $credentials ]]; then
        PMA_PASSWORD=$(sed -n 's/^password=//p' "$credentials")
        PMA_CONTROL_USER=$(sed -n 's/^controluser=//p' "$credentials")
        PMA_CONTROL_PASSWORD=$(sed -n 's/^controlpass=//p' "$credentials")
        PMA_SECRET=$(sed -n 's/^blowfish_secret=//p' "$credentials")
        [[ -n $PMA_PASSWORD && -n $PMA_CONTROL_USER && -n $PMA_CONTROL_PASSWORD && -n $PMA_SECRET ]] || \
            die '已有凭据文件不完整，停止安装以免更改数据库账号。'
    else
        PMA_PASSWORD=$(random_ten)
        PMA_CONTROL_USER=lnmpp_$(openssl rand -hex 4)
        PMA_CONTROL_PASSWORD=$(openssl rand -hex 24)
        PMA_SECRET=$(openssl rand -hex 32)
        temp=$(mktemp "$STATE_DIR/.credentials.XXXXXX")
        printf 'username=%s\npassword=%s\nroot_password=%s\ncontroluser=%s\ncontrolpass=%s\nblowfish_secret=%s\n' \
            "$PMA_USERNAME" "$PMA_PASSWORD" "$PMA_PASSWORD" "$PMA_CONTROL_USER" "$PMA_CONTROL_PASSWORD" "$PMA_SECRET" > "$temp"
        chmod 600 "$temp"
        mv "$temp" "$credentials"
    fi
}

configure_phpmyadmin() {
    local password controluser controlpass sql_file secret
    load_or_create_pma_credentials
    password=$PMA_PASSWORD
    controluser=$PMA_CONTROL_USER
    controlpass=$PMA_CONTROL_PASSWORD
    secret=$PMA_SECRET
    mariadb <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('$(sql_escape "$password")');
CREATE DATABASE IF NOT EXISTS phpmyadmin CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$controluser'@'localhost' IDENTIFIED BY '$controlpass';
ALTER USER '$controluser'@'localhost' IDENTIFIED BY '$controlpass';
GRANT SELECT, INSERT, UPDATE, DELETE ON phpmyadmin.* TO '$controluser'@'localhost';
SQL
    sql_file=$(dpkg -L phpmyadmin | grep '/create_tables.sql$' | head -n 1)
    [[ -n $sql_file && -f $sql_file ]] || die '找不到 phpMyAdmin 高级功能 SQL 文件。'
    mariadb phpmyadmin < "$sql_file"
    MYSQL_PWD=$controlpass mariadb --user="$controluser" --protocol=socket \
        --batch --skip-column-names -e 'SELECT COUNT(*) FROM phpmyadmin.pma__bookmark' >/dev/null || \
        die 'phpMyAdmin 高级功能账号检查失败。'
    MYSQL_PWD=$password runuser -u www-data -- mariadb --user=root --protocol=socket \
        --batch --skip-column-names -e 'SELECT 1' >/dev/null || \
        die 'phpMyAdmin root 密码登录检查失败。'
    install -d -m 755 /etc/phpmyadmin/conf.d
    cat > /etc/phpmyadmin/conf.d/lnmpp.php <<EOF
<?php
\$cfg['blowfish_secret'] = '$secret';
\$cfg['Servers'][\$i]['host'] = 'localhost';
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['AllowRoot'] = true;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['Servers'][\$i]['pmadb'] = 'phpmyadmin';
\$cfg['Servers'][\$i]['controluser'] = '$controluser';
\$cfg['Servers'][\$i]['controlpass'] = '$controlpass';
\$cfg['Servers'][\$i]['bookmarktable'] = 'pma__bookmark';
\$cfg['Servers'][\$i]['relation'] = 'pma__relation';
\$cfg['Servers'][\$i]['table_info'] = 'pma__table_info';
\$cfg['Servers'][\$i]['table_coords'] = 'pma__table_coords';
\$cfg['Servers'][\$i]['pdf_pages'] = 'pma__pdf_pages';
\$cfg['Servers'][\$i]['column_info'] = 'pma__column_info';
\$cfg['Servers'][\$i]['history'] = 'pma__history';
\$cfg['Servers'][\$i]['table_uiprefs'] = 'pma__table_uiprefs';
\$cfg['Servers'][\$i]['tracking'] = 'pma__tracking';
\$cfg['Servers'][\$i]['userconfig'] = 'pma__userconfig';
\$cfg['Servers'][\$i]['recent'] = 'pma__recent';
\$cfg['Servers'][\$i]['favorite'] = 'pma__favorite';
\$cfg['Servers'][\$i]['users'] = 'pma__users';
\$cfg['Servers'][\$i]['usergroups'] = 'pma__usergroups';
\$cfg['Servers'][\$i]['navigationhiding'] = 'pma__navigationhiding';
\$cfg['Servers'][\$i]['savedsearches'] = 'pma__savedsearches';
\$cfg['Servers'][\$i]['central_columns'] = 'pma__central_columns';
\$cfg['Servers'][\$i]['designer_settings'] = 'pma__designer_settings';
\$cfg['Servers'][\$i]['export_templates'] = 'pma__export_templates';
EOF
    chown root:www-data /etc/phpmyadmin/conf.d/lnmpp.php
    chmod 640 /etc/phpmyadmin/conf.d/lnmpp.php
    PMA_PASSWORD=$password
}

install_renew_timer() {
    install -d -m 755 /usr/local/lib/lnmpp
    install -m 755 "${BASH_SOURCE[0]}" "$SCRIPT_PATH"
    cat > /etc/systemd/system/lnmpp-ssl-renew.service <<EOF
[Unit]
Description=Renew LNMPP SSL certificates
[Service]
Type=oneshot
ExecStart=/usr/bin/bash $SCRIPT_PATH renew-all
EOF
    cat > /etc/systemd/system/lnmpp-ssl-renew.timer <<'EOF'
[Unit]
Description=Run LNMPP certificate renewal daily
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now lnmpp-ssl-renew.timer
}

install_stack() {
    check_os
    [[ ! -f $STATE_DIR/installed ]] || die 'LNMPP 已安装。'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    if [[ ${ID:-} == ubuntu ]] && ! apt-cache show phpmyadmin >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends software-properties-common
        add-apt-repository -y universe
        apt-get update
    fi
    printf 'phpmyadmin phpmyadmin/dbconfig-install boolean false\n' | debconf-set-selections
    printf 'phpmyadmin phpmyadmin/reconfigure-webserver multiselect\n' | debconf-set-selections
    apt-get install -y --no-install-recommends \
        nginx mariadb-server php-fpm php-cli php-mysql php-mbstring php-xml \
        php-curl php-zip php-gd phpmyadmin supervisor vsftpd git curl openssl python3
    local version
    version=$(php_version)
    local unit
    for unit in nginx mariadb "php$version-fpm" mariadb.socket; do
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
    done
    systemctl mask mariadb.socket >/dev/null 2>&1 || true
    if systemctl is-active --quiet mariadb.socket; then
        die 'MariaDB socket 单元仍在运行，无法交给 Supervisor 接管。'
    fi
    install -d -m 700 "$STATE_DIR" "$SITES_DIR" "$CERT_DIR"
    configure_supervisor
    configure_nginx_default
    systemctl enable --now supervisor
    systemctl restart supervisor
    local program attempt
    for program in nginx mariadb php-fpm; do
        for ((attempt=0; attempt<15; attempt++)); do
            if supervisorctl -c "$SUPERVISOR_CONF" status "$program" 2>/dev/null | grep -q RUNNING; then
                break
            fi
            sleep 1
        done
        supervisorctl -c "$SUPERVISOR_CONF" status "$program" | grep -q RUNNING || die "$program 未正常运行。"
    done
    configure_phpmyadmin
    configure_ftp
    install_renew_timer
    php -l /etc/phpmyadmin/conf.d/lnmpp.php >/dev/null
    curl -fsS -o /dev/null http://127.0.0.1/phpmyadmin/ || die 'phpMyAdmin HTTP 检查失败。'
    touch "$STATE_DIR/installed"
    chmod 600 "$STATE_DIR/installed"
    say 'LNMPP安装成功。'
    say "phpMyAdmin用户名：$PMA_USERNAME"
    say "phpMyAdmin密码：$PMA_PASSWORD"
    say 'phpMyAdmin地址：http://服务器IP/phpmyadmin/'
    say 'Supervisor HTTP：http://服务器IP:8000/（admin / password）'
}

main() {
    local command=${1:-install}
    if [[ $command == help || $command == --help || $command == -h ]]; then usage; return 0; fi
    require_root
    case $command in
        install)
            [[ $# -le 1 ]] || { usage; return 2; }
            install_stack
            ;;
        add)
            [[ -f $STATE_DIR/installed ]] || die '请先安装 LNMPP。'
            case ${2:-} in
                db) [[ $# -eq 5 ]] || { usage; return 2; }; add_db "$3" "$4" "$5" ;;
                ssl) [[ $# -eq 6 ]] || { usage; return 2; }; add_ssl "$3" "$4" "$5" "$6" ;;
                ftp) [[ $# -eq 4 ]] || { usage; return 2; }; add_ftp "$3" "$4" ;;
                *) [[ $# -eq 3 ]] || { usage; return 2; }; add_site "$2" "$3" ;;
            esac
            ;;
        stop|start)
            [[ -f $STATE_DIR/installed ]] || die '请先安装 LNMPP。'
            case ${2:-} in
                ssl)
                    [[ $# -le 3 ]] || { usage; return 2; }
                    toggle_ssl "$command" "${3:-}"
                    ;;
                phpmyadmin)
                    [[ $# -eq 2 ]] || { usage; return 2; }
                    toggle_phpmyadmin_remote "$command"
                    ;;
                *) usage; return 2 ;;
            esac
            ;;
        renew-all)
            [[ $# -eq 1 ]] || { usage; return 2; }
            renew_all
            ;;
        *) usage; return 2 ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
