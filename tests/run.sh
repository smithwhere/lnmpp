#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
source ./install.sh

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }
assert_grep() { grep -Fq -- "$1" "$2" || fail "missing '$1' in $2"; }
assert_not_grep() { if grep -Fq -- "$1" "$2"; then fail "unexpected '$1' in $2"; fi; }

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
username=$(random_ten)
for value in "$password" "$username"; do
    [[ ${#value} -eq 10 ]] || fail 'credential is not 10 characters'
    [[ "$value" =~ [[:lower:]] ]] || fail 'credential lacks lower case'
    [[ "$value" =~ [[:upper:]] ]] || fail 'credential lacks upper case'
    [[ "$value" =~ [[:digit:]] ]] || fail 'credential lacks digit'
    [[ "$value" =~ [!@#%\^\&*_+-] ]] || fail 'credential lacks special character'
done

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
assert_grep 'ssl_certificate /etc/lnmpp/certs/example.com/fullchain.pem;' "$tmp/https.conf"
assert_not_grep '*.example.com' "$tmp/https.conf"

STATE_DIR=$tmp/state
SITES_DIR=$STATE_DIR/sites
CERT_DIR=$STATE_DIR/certs
NGINX_DIR=$tmp/nginx
ACME_HOME=$tmp/acme
mkdir -p "$SITES_DIR" "$CERT_DIR/example.com" "$NGINX_DIR/sites-available" "$NGINX_DIR/sites-enabled" "$ACME_HOME"
nginx() { [[ $1 == -t ]]; }
supervisorctl() { return 1; }
php_version() { printf '8.3'; }
if [[ $(uname -s) == MINGW* ]]; then
    mkdir -p "$SITES_DIR/example.com"
    printf '%s' '*.example.com' > "$SITES_DIR/example.com/wildcard"
    printf '%s' /var/www/example.com > "$SITES_DIR/example.com/webroot"
    printf '0' > "$SITES_DIR/example.com/ssl-enabled"
    write_site_config example.com '*.example.com' /var/www/example.com 0
else
    add_site 'example.com\*.example.com' "$tmp/web" > "$tmp/add-site.txt"
    assert_eq "$(<"$tmp/add-site.txt")" '网站成功创建完成'
    assert_eq "$(<"$SITES_DIR/example.com/ssl-enabled")" 0
fi
assert_grep 'server_name example.com *.example.com;' "$NGINX_DIR/sites-available/lnmpp-example.com.conf"
printf '1' > "$SITES_DIR/example.com/ssl-enabled"
printf '70' > "$SITES_DIR/example.com/renew-days"
printf 'test-token' > "$SITES_DIR/example.com/cf-token"
printf 'certificate' > "$CERT_DIR/example.com/fullchain.pem"
printf 'key' > "$CERT_DIR/example.com/key.pem"
printf '#!/bin/sh\nexit 25\n' > "$ACME_HOME/acme.sh"
chmod +x "$ACME_HOME/acme.sh"

toggle_ssl_one stop example.com
assert_eq "$(<"$SITES_DIR/example.com/ssl-enabled")" 0
assert_not_grep 'listen 443 ssl;' "$NGINX_DIR/sites-available/lnmpp-example.com.conf"
[[ -s $CERT_DIR/example.com/key.pem ]] || fail 'stop removed certificate'
renew_all || fail 'disabled certificate was renewed'

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

printf 'All tests passed.\n'
