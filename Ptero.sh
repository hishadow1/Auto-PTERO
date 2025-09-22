#!/usr/bin/env bash
# Pterodactyl Installer - Debian 10/11/12 + Ubuntu 20.04/22.04/24.04
set -euo pipefail
IFS=$'\n\t'

# ---------- UI ----------
info()    { printf "\e[1;37m%s\e[0m\n" "$1"; }
success() { printf "\e[1;32m%s\e[0m\n" "$1"; }
warn()    { printf "\e[1;33m%s\e[0m\n" "$1"; }
err()     { printf "\e[1;31m%s\e[0m\n" "$1"; }

header() {
  printf "\n\e[40m\e[1;37m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m\n"
  printf "\e[40m\e[1;37m   🦖  Pterodactyl Quick Installer — Modern Black UI\e[0m\n"
  printf "\e[40m\e[1;37m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m\n\n"
}

if [[ $EUID -ne 0 ]]; then
  err "Run as root (sudo ./install.sh)"
  exit 1
fi

header

echo "  1) 🦖  Install Pterodactyl Panel"
echo "  2) ❌  Exit"
read -rp $'\nEnter choice (1 or 2): ' CHOICE
[[ "$CHOICE" != "1" ]] && exit 0

# ---------- Detect OS ----------
. /etc/os-release
OS=$ID
VER=$VERSION_ID
info "Detected OS: $PRETTY_NAME"

# ---------- Certs ----------
mkdir -p /etc/certs
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL" \
  -keyout /etc/certs/privkey.pem -out /etc/certs/fullchain.pem
success "Self-signed SSL ready."

# ---------- Disable UFW ----------
command -v ufw >/dev/null && ufw disable || true

# ---------- Ask FQDN ----------
read -rp $'\nEnter FQDN (domain) for panel [default: localhost]: ' PTERO_FQDN
PTERO_FQDN=${PTERO_FQDN:-localhost}
USE_LETSENCRYPT="no"
if [[ "$PTERO_FQDN" != "localhost" && "$PTERO_FQDN" == *.* ]]; then
  read -rp "Use Let's Encrypt SSL? (Y/n): " LE
  [[ "${LE:-Y}" =~ ^[Yy]$ ]] && USE_LETSENCRYPT="yes"
fi

# ---------- Update base ----------
apt-get update -y
apt-get install -y curl wget ca-certificates apt-transport-https software-properties-common git unzip tar pwgen lsb-release gnupg openssl

# ---------- PHP logic ----------
PHP_VER=""
if [[ "$OS" == "ubuntu" ]]; then
  case "$VER" in
    "20.04") PHP_VER="8.1"; add-apt-repository -y ppa:ondrej/php ;;
    "22.04") PHP_VER="8.1" ;;
    "24.04") PHP_VER="8.3" ;;
    *) PHP_VER="8.1"; add-apt-repository -y ppa:ondrej/php ;;
  esac
elif [[ "$OS" == "debian" ]]; then
  echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/sury-php.list
  wget -qO - https://packages.sury.org/php/apt.gpg | apt-key add -
  case "$VER" in
    "10") PHP_VER="8.0" ;;  # Buster
    "11") PHP_VER="8.1" ;;  # Bullseye
    "12") PHP_VER="8.2" ;;  # Bookworm
    *)    PHP_VER="8.1" ;;
  esac
fi

apt-get update -y
apt-get install -y nginx mariadb-server redis-server composer certbot python3-certbot-nginx \
  php${PHP_VER}-fpm php${PHP_VER}-cli php${PHP_VER}-mbstring php${PHP_VER}-xml \
  php${PHP_VER}-curl php${PHP_VER}-gd php${PHP_VER}-mysql php${PHP_VER}-zip php${PHP_VER}-bcmath

systemctl enable --now nginx mariadb redis-server

# ---------- Database ----------
MYSQL_ROOT_PASS=$(openssl rand -base64 20)
PTERO_DB_PASS=$(openssl rand -base64 20)
mysql -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
CREATE DATABASE IF NOT EXISTS pterodactyl;
CREATE USER IF NOT EXISTS 'ptero_user'@'127.0.0.1' IDENTIFIED BY '${PTERO_DB_PASS}';
GRANT ALL PRIVILEGES ON pterodactyl.* TO 'ptero_user'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

# ---------- Admin user ----------
ADMIN_USER="admin"
ADMIN_EMAIL="admin@gmail.com"
ADMIN_PASS=$(openssl rand -base64 16)
id -u $ADMIN_USER &>/dev/null || useradd -m -s /bin/bash $ADMIN_USER
echo "${ADMIN_USER}:${ADMIN_PASS}" | chpasswd

# ---------- Panel ----------
PANEL_DIR="/var/www/pterodactyl"
[ -d "$PANEL_DIR" ] && mv "$PANEL_DIR" "${PANEL_DIR}_$(date +%s)"
composer create-project --no-dev pterodactyl/panel "$PANEL_DIR" || git clone https://github.com/pterodactyl/panel.git "$PANEL_DIR"
cd "$PANEL_DIR"
cp -n .env.example .env
sed -i "s/DB_DATABASE=.*/DB_DATABASE=pterodactyl/" .env
sed -i "s/DB_USERNAME=.*/DB_USERNAME=ptero_user/" .env
sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$PTERO_DB_PASS/" .env
php artisan key:generate --force
php artisan migrate --seed --force
chown -R www-data:www-data "$PANEL_DIR"

# ---------- Nginx ----------
cat >/etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name ${PTERO_FQDN};
    root ${PANEL_DIR}/public;
    index index.php;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
    }
    location ~ /\.ht { deny all; }
}
EOF
ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# ---------- SSL ----------
HTTPS="http"
if [[ "$USE_LETSENCRYPT" == "yes" ]]; then
  if certbot --nginx -d "$PTERO_FQDN" -m "$ADMIN_EMAIL" --agree-tos --non-interactive --redirect; then
    HTTPS="https"
  fi
fi

# ---------- Summary ----------
header
success "🎉 Installation complete"
echo "🔐 Admin User: $ADMIN_USER / $ADMIN_PASS"
echo "📧 Email: $ADMIN_EMAIL"
echo "🗄️ DB: pterodactyl / ptero_user / $PTERO_DB_PASS"
echo "🗄️ MySQL root: $MYSQL_ROOT_PASS"
echo "🌐 URL: $HTTPS://$PTERO_FQDN"
