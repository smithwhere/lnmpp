#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
source ./install.sh

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }
assert_grep() { grep -Fq -- "$1" "$2" || fail "missing '$1' in $2"; }
assert_not_grep() { if grep -Fq -- "$1" "$2"; then fail "unexpected '$1' in $2"; fi; }

os_tmp=$(mktemp -d)
printf 'ID=debian\n' > "$os_tmp/os-release"
printf 'forky/sid\n' > "$os_tmp/debian_version"
systemctl() { return 0; }
OS_RELEASE_FILE=$os_tmp/os-release DEBIAN_VERSION_FILE=$os_tmp/debian_version check_os
printf 'ID=debian\nVERSION_ID=11\n' > "$os_tmp/os-release"
if ( OS_RELEASE_FILE=$os_tmp/os-release DEBIAN_VERSION_FILE=$os_tmp/debian_version check_os ) 2>/dev/null; then
    fail 'accepted Debian 11'
fi
rm -rf "$os_tmp"

parse_domains 'Example.COM\*.example.com'
assert_eq "$PRIMARY_DOMAIN" 'example.com'
assert_eq "$WILDCARD_DOMAIN" '*.example.com'
parse_domains 'example.com'
assert_eq "$WILDCARD_DOMAIN" ''
for bad in 'example.com\\*.example.com' 'example.com\*.other.com' "example.com\\" 'bad/name' '-bad.example'; do
    if parse_domains "$bad" 2>/dev/null; then fail "accepted domain: $bad"; fi
done

for value in 0 90 abc -1; do
    if validate_renew_days "$value" 2>/dev/null; then fail "accepted renewal days: $value"; fi
done
validate_renew_days 70

password=$(random_ten)
[[ ${#password} -eq 10 ]] || fail 'credential is not 10 characters'
[[ "$password" =~ [[:lower:]] ]] || fail 'credential lacks lower case'
[[ "$password" =~ [[:upper:]] ]] || fail 'credential lacks upper case'
[[ "$password" =~ [[:digit:]] ]] || fail 'credential lacks digit'
[[ "$password" =~ [!@#%\^\&*_+-] ]] || fail 'credential lacks special character'

assert_eq "$(sql_escape "a'b\\c")" "a''b\\\\c"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
render_site_config example.com '*.example.com' /var/www/example.com 0 8.3 > "$tmp/http.conf"
assert_grep 'server_name example.com *.example.com;' "$tmp/http.conf"
assert_grep 'root /var/www/example.com;' "$tmp/http.conf"
assert_grep 'php8.3-fpm.sock' "$tmp/http.conf"
assert_not_grep 'listen 443 ssl' "$tmp/http.conf"

render_site_config example.com '' /var/www/example.com 1 8.3 > "$tmp/https.conf"
assert_grep 'listen 443 ssl;' "$tmp/https.conf"
# shellcheck disable=SC2016
assert_grep 'return 301 https://$host$request_uri;' "$tmp/https.conf"
assert_grep 'ssl_certificate /etc/lnmpp/certs/example.com/fullchain.pem;' "$tmp/https.conf"
assert_not_grep '*.example.com' "$tmp/https.conf"

STATE_DIR=$tmp/state
SITES_DIR=$STATE_DIR/sites
CERT_DIR=$STATE_DIR/certs
NGINX_DIR=$tmp/nginx
ACME_HOME=$tmp/acme
mkdir -p "$SITES_DIR" "$CERT_DIR/example.com" "$NGINX_DIR/sites-available" "$NGINX_DIR/sites-enabled" "$ACME_HOME"
acme_fixture=$tmp/acme-fixture
mkdir -p "$acme_fixture/dnsapi"
cat > "$acme_fixture/acme.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $1 == --install ]]
while [[ $# -gt 0 ]]; do
    if [[ $1 == --home ]]; then
        install_home=$2
        break
    fi
    shift
done
mkdir -p "$install_home/dnsapi"
# The upstream installer copies these files relative to its working directory.
cp acme.sh "$install_home/acme.sh"
cp dnsapi/dns_cf.sh "$install_home/dnsapi/dns_cf.sh"
chmod +x "$install_home/acme.sh"
SH
printf 'Cloudflare DNS hook\n' > "$acme_fixture/dnsapi/dns_cf.sh"
git() {
    [[ $1 == clone && $2 == --depth && $3 == 1 && $4 == https://github.com/acmesh-official/acme.sh.git ]] || fail 'unexpected git command'
    mkdir -p "$5/dnsapi"
    cp "$acme_fixture/acme.sh" "$5/acme.sh"
    cp "$acme_fixture/dnsapi/dns_cf.sh" "$5/dnsapi/dns_cf.sh"
}
acme_home_before=$ACME_HOME
ACME_HOME=$tmp/acme-install
ensure_acme
[[ -x $ACME_HOME/acme.sh ]] || fail 'acme.sh was not installed'
assert_eq "$(<"$ACME_HOME/dnsapi/dns_cf.sh")" 'Cloudflare DNS hook'
ACME_HOME=$acme_home_before
unset -f git
nginx() { [[ $1 == -t ]]; }
supervisorctl() { return 1; }
php_version() { printf '8.3'; }
if [[ $(uname -s) == MINGW* ]]; then
    mkdir -p "$SITES_DIR/example.com"
    printf '%s' '*.example.com' > "$SITES_DIR/example.com/wildcard"
    printf '%s' /var/www/example.com > "$SITES_DIR/example.com/webroot"
    printf '0' > "$SITES_DIR/example.com/ssl-enabled"
    write_site_config example.com '*.example.com' /var/www/example.com 0
    printf '1' > "$SITES_DIR/example.com/ssl-enabled"
    printf '70' > "$SITES_DIR/example.com/renew-days"
    printf 'test-token' > "$SITES_DIR/example.com/cf-token"
    printf 'certificate' > "$CERT_DIR/example.com/fullchain.pem"
    printf 'key' > "$CERT_DIR/example.com/key.pem"
else
    add_site 'example.com\*.example.com' "$tmp/web" > "$tmp/add-site.txt"
    assert_eq "$(<"$tmp/add-site.txt")" '网站成功创建完成'
    assert_eq "$(<"$SITES_DIR/example.com/ssl-enabled")" 0
    if ( add_ssl 70 cloudflare example.com test-token ) 2>/dev/null; then
        fail 'accepted certificate without existing wildcard'
    fi
    cat > "$ACME_HOME/acme.sh" <<'SH'
#!/usr/bin/env bash
set -e
if [[ " $* " == *' --install-cert '* ]]; then
    while [[ $# -gt 0 ]]; do
        case $1 in
            --key-file) printf 'key' > "$2"; shift 2 ;;
            --fullchain-file) printf 'certificate' > "$2"; shift 2 ;;
            *) shift ;;
        esac
    done
fi
SH
    chmod +x "$ACME_HOME/acme.sh"
    add_ssl 70 cloudflare 'example.com\*.example.com' test-token > "$tmp/add-ssl.txt"
    assert_eq "$(<"$tmp/add-ssl.txt")" 'ssl证书成功创建完成'
    assert_eq "$(<"$SITES_DIR/example.com/renew-days")" 70
    assert_eq "$(<"$SITES_DIR/example.com/ssl-enabled")" 1
    [[ -L $tmp/web/phpmyadmin ]] || fail 'phpMyAdmin HTTPS link missing'
fi
assert_grep 'server_name example.com *.example.com;' "$NGINX_DIR/sites-available/lnmpp-example.com.conf"
printf '#!/bin/sh\nexit 25\n' > "$ACME_HOME/acme.sh"
chmod +x "$ACME_HOME/acme.sh"

toggle_ssl_one stop example.com
assert_eq "$(<"$SITES_DIR/example.com/ssl-enabled")" 0
assert_not_grep 'listen 443 ssl;' "$NGINX_DIR/sites-available/lnmpp-example.com.conf"
[[ -s $CERT_DIR/example.com/key.pem ]] || fail 'stop removed certificate'
renew_all || fail 'disabled certificate was renewed'

openssl() { if [[ $1 == x509 ]]; then [[ -f $tmp/cert-valid ]]; else command openssl "$@"; fi; }
if ( toggle_ssl_one start example.com ) 2>/dev/null; then
    fail 'enabled an expired certificate after renewal failed'
fi
assert_eq "$(<"$SITES_DIR/example.com/ssl-enabled")" 0
touch "$tmp/cert-valid"
toggle_ssl_one start example.com
assert_eq "$(<"$SITES_DIR/example.com/ssl-enabled")" 1
assert_grep 'listen 443 ssl;' "$NGINX_DIR/sites-available/lnmpp-example.com.conf"

mariadb() {
    if [[ $* == *' -e '* ]]; then
        printf '0\n'
    else
        cat > "$tmp/db.sql"
    fi
}
add_db sample_db sample_user "ab'c\\d" > "$tmp/add-db.txt"
assert_eq "$(<"$tmp/add-db.txt")" '数据库成功创建完成'
# shellcheck disable=SC2016
assert_grep 'CREATE DATABASE `sample_db`' "$tmp/db.sql"
assert_grep "IDENTIFIED BY 'ab''c\\\\d'" "$tmp/db.sql"
# shellcheck disable=SC2016
assert_grep 'GRANT ALL PRIVILEGES ON `sample_db`.*' "$tmp/db.sql"

STATE_DIR=$tmp/pma-state
mkdir -p "$STATE_DIR"
touch "$STATE_DIR/installed"
load_or_create_pma_credentials
assert_eq "$PMA_USERNAME" root
assert_eq "$(sed -n 's/^username=//p' "$STATE_DIR/phpmyadmin-credentials")" root
saved_password=$PMA_PASSWORD
saved_control=$PMA_CONTROL_PASSWORD
load_or_create_pma_credentials
assert_eq "$PMA_USERNAME" root
assert_eq "$PMA_PASSWORD" "$saved_password"
assert_eq "$PMA_CONTROL_PASSWORD" "$saved_control"
view_output=$(view_phpmyadmin_password)
assert_eq "$view_output" "phpMyAdmin密码：$saved_password"
missing_state=$tmp/pma-missing-state
mkdir -p "$missing_state"
touch "$missing_state/installed"
if ( STATE_DIR=$missing_state view_phpmyadmin_password ) >/dev/null 2>&1; then
    fail 'view accepted missing phpMyAdmin credentials'
fi
[[ ! -e $missing_state/phpmyadmin-credentials ]] || fail 'view generated phpMyAdmin credentials'

printf 'All tests passed.\n'
