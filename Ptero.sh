#!/usr/bin/env bash

Pterodactyl Auto Installer (Panel only)

Supports Debian 11/12 and Ubuntu 20.04/22.04/24.04

set -euo pipefail IFS=$'\n\t'

Colors for themed output

CSI="\033[" RESET="${CSI}0m" BOLD="${CSI}1m" WHITE="${CSI}97m" CYAN="${CSI}36m" YELLOW="${CSI}33m" GREEN="${CSI}32m" RED="${CSI}31m" BG_BLACK="${CSI}40m"

function banner() { echo -e "${BG_BLACK}${WHITE}${BOLD}\n==============================================\n  PTERODACTYL PANEL AUTO-INSTALLER (DEBIAN/UBUNTU)\n==============================================${RESET}\n" }

function info() { echo -e "${CYAN}[INFO]${RESET} $"; } function warn() { echo -e "${YELLOW}[WARN]${RESET} $"; } function err()  { echo -e "${RED}[ERROR]${RESET} $"; } function ok()   { echo -e "${GREEN}[OK]${RESET} $"; }

Must be root

if [[ $(id -u) -ne 0 ]]; then err "This script must be run as root."; exit 1; fi

banner

Generate default self-signed certs

info "Ensuring /etc/certs exists with self-signed certs..." mkdir -p /etc/certs cd /etc/certs if [[ ! -f privkey.pem || ! -f fullchain.pem ]]; then openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 
-subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" 
-keyout privkey.pem -out fullchain.pem ok "Self-signed certs created." else warn "Self-signed certs already exist." fi cd ~

Detect OS

info "Detecting OS..." . /etc/os-release OS_ID=${ID} OS_VERSION=${VERSION_ID} ok "Detected: ${NAME} ${VERSION_ID}"

PHP heuristic

PHP_VER="8.1" if [[ "$OS_ID" == "ubuntu" ]]; then case "$OS_VERSION" in 20.04|22.04) PHP_VER="8.1" ;; 24.04) PHP_VER="8.2" ;; esac else case "$OS_VERSION" in 11) PHP_VER="8.1" ;; 12) PHP_VER="8.2" ;; esac fi info "PHP version chosen: ${PHP_VER}"

Ask for FQDN

read -rp "Enter the FQDN for your Pterodactyl Panel (e.g. panel.example.com): " FQDN if [[ -z "$FQDN" ]]; then err "FQDN cannot be empty."; exit 1; fi

LE check

LE_NEEDED="no" info "Checking DNS resolution for Let's Encrypt..." RESOLVED_IP=$(getent hosts "$FQDN" | awk '{print $1}' | head -n1 || true) PUBLIC_IP=$(curl -s https://ifconfig.me || true) if [[ -n "$RESOLVED_IP" && -n "$PUBLIC_IP" && "$RESOLVED_IP" == "$PUBLIC_IP" ]]; then read -rp "Domain resolves to this server. Use Let's Encrypt? (y/N): " ans if [[ "$ans" =~ ^[yY]$ ]]; then LE_NEEDED="yes"; fi fi

Update + install deps

export DEBIAN_FRONTEND=noninteractive apt-get update -y && apt-get upgrade -y apt-get install -y software-properties-common curl apt-transport-https ca-certificates gnupg2 lsb-release git unzip tar wget zip build-essential mariadb-server redis-server nginx LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php || true apt-get update -y apt-get install -y php${PHP_VER} php${PHP_VER}-fpm php${PHP_VER}-cli php${PHP_VER}-mbstring php${PHP_VER}-xml php${PHP_VER}-curl php${PHP_VER}-mysql php${PHP_VER}-gd php${PHP_VER}-zip php${PHP_VER}-bcmath php${PHP_VER}-redis

Node + composer

curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - apt-get install -y nodejs EXPECTED_SIG="$(wget -q -O - https://composer.github.io/installer.sig)" php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" php composer-setup.php --install-dir=/usr/local/bin --filename=composer rm composer-setup.php

if [[ "$LE_NEEDED" == "yes" ]]; then apt-get install -y certbot python3-certbot-nginx fi

Panel setup

PANEL_DIR="/var/www/pterodactyl" mkdir -p "$PANEL_DIR" cd "$PANEL_DIR" git clone https://github.com/pterodactyl/panel.git . || true composer install --no-dev --optimize-autoloader --no-interaction cp -n .env.example .env php artisan key:generate --force

DB setup

read -rp "Panel database name [pterodactyl]: " DB_NAME DB_NAME=${DB_NAME:-pterodactyl} read -rp "Panel database user [pterodactyl]: " DB_USER DB_USER=${DB_USER:-pterodactyl} DB_PASS=$(openssl rand -base64 16)

mysql -e "CREATE DATABASE IF NOT EXISTS `${DB_NAME}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';" mysql -e "GRANT ALL ON `${DB_NAME}`.* TO '${DB_USER}'@'localhost';" mysql -e "FLUSH PRIVILEGES;"

sed -i "s|APP_URL=.|APP_URL=https://${FQDN}|" .env sed -i "s|DB_DATABASE=.|DB_DATABASE=${DB_NAME}|" .env sed -i "s|DB_USERNAME=.|DB_USERNAME=${DB_USER}|" .env sed -i "s|DB_PASSWORD=.|DB_PASSWORD=${DB_PASS}|" .env

php artisan migrate --seed --force chown -R www-data:www-data ${PANEL_DIR} chmod -R 755 ${PANEL_DIR}

Nginx

NGINX_CONF="/etc/nginx/sites-available/pterodactyl" cat > ${NGINX_CONF} <<NGINX server { listen 80; server_name ${FQDN};

root /var/www/pterodactyl/public; index index.php;

location / { try_files $uri $uri/ /index.php?$query_string; }

location ~ .php$ { fastcgi_split_path_info ^(.+.php)(/.+)$; fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock; fastcgi_index index.php; include fastcgi_params; fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name; fastcgi_param HTTP_PROXY ""; internal; }

location ~ /.ht { deny all; } } NGINX ln -sf ${NGINX_CONF} /etc/nginx/sites-enabled/pterodactyl nginx -t && systemctl reload nginx

if [[ "$LE_NEEDED" == "yes" ]]; then certbot --nginx -d ${FQDN} --non-interactive --agree-tos -m admin@${FQDN} || warn "Let's Encrypt failed." fi

Admin user

ADMIN_PASS=$(openssl rand -base64 18) php artisan p:user:make --email=admin@gmail.com --username=admin --name="admin" --admin --password="${ADMIN_PASS}" || true

Final summary

SUMMARY_FILE="/root/pterodactyl_credentials.txt" echo "Panel URL: https://${FQDN}" | tee ${SUMMARY_FILE} echo "Admin username: admin" | tee -a ${SUMMARY_FILE} echo "Admin first name: admin" | tee -a ${SUMMARY_FILE} echo "Admin last name: admin" | tee -a ${SUMMARY_FILE} echo "Admin email: admin@gmail.com" | tee -a ${SUMMARY_FILE} echo "Admin password: ${ADMIN_PASS}" | tee -a ${SUMMARY_FILE} echo "Database: ${DB_NAME}" | tee -a ${SUMMARY_FILE} echo "Database user: ${DB_USER}" | tee -a ${SUMMARY_FILE} echo "Database password: ${DB_PASS}" | tee -a ${SUMMARY_FILE} chmod 600 ${SUMMARY_FILE}

ok "Installation finished. Access your panel at: https://${FQDN}" ok "Admin credentials and DB info saved to ${SUMMARY_FILE}"

