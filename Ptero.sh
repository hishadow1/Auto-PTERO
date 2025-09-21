#!/usr/bin/env bash
# ptero_installer.sh
# Interactive Pterodactyl Panel installer with modern black theme UI.
# Supports Debian/Ubuntu. Handles PHP version automatically.

set -euo pipefail
IFS=$'\n\t'

# ---------- Helpers ----------
info()    { printf "\e[1;37m%s\e[0m\n" "$1"; }  # bright white
success() { printf "\e[1;32m%s\e[0m\n" "$1"; }  # green
warn()    { printf "\e[1;33m%s\e[0m\n" "$1"; }  # yellow
err()     { printf "\e[1;31m%s\e[0m\n" "$1"; }  # red

print_header() {
  printf "\n\e[40m\e[1;37m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m\n"
  printf "\e[40m\e[1;37m   🦖  Pterodactyl Quick Installer — Modern Black UI  ⚙️  🔐  🚀\e[0m\n"
  printf "\e[40m\e[1;37m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m\n\n"
}

# ---------- Root Check ----------
if [[ $EUID -ne 0 ]]; then
  err "Please run as root. Use sudo ./ptero_installer.sh"
  exit 1
fi

print_header

echo -e "What would you like to install?\n"
echo -e "  1) 🦖  Install Pterodactyl Panel"
echo -e "  2) ❌  Exit"
read -rp $'\nEnter choice (1 or 2): ' CHOICE

if [[ "$CHOICE" != "1" ]]; then
  info "Exiting. No changes made."
  exit 0
fi

# ---------- Step 0: Certificates ----------
info "Creating /etc/certs and a self-signed certificate..."
mkdir -p /etc/certs
cd /etc/certs
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" \
  -keyout privkey.pem -out fullchain.pem
cd ~
success "Self-signed cert saved at /etc/certs/"

# ---------- Step 1: Disable UFW ----------
info "Disabling UFW..."
if command -v ufw >/dev/null 2>&1; then
  ufw disable || warn "ufw disable failed"
fi

# ---------- Step 2: Ask for FQDN ----------
read -rp $'\nEnter the FQDN (domain) for Pterodactyl (e.g. panel.example.com). Leave blank for localhost: ' PTERO_FQDN
PTERO_FQDN=${PTERO_FQDN:-localhost}

USE_LETSENCRYPT="no"
if [[ "$PTERO_FQDN" != "localhost" && "$PTERO_FQDN" == *.* ]]; then
  read -rp "Detected domain. Use Let's Encrypt for $PTERO_FQDN? (Y/n): " lechoice
  lechoice=${lechoice:-Y}
  [[ "$lechoice" =~ ^([yY]|$) ]] && USE_LETSENCRYPT="yes"
fi

info "FQDN set to: $PTERO_FQDN"
info "Use Let's Encrypt: $USE_LETSENCRYPT"

# ---------- Step 3: Prepare Environment ----------
info "Detecting OS..."
. /etc/os-release
OS_ID=${ID,,}
OS_VERSION=${VERSION_ID:-}
info "Detected: $PRETTY_NAME"

info "Updating package lists..."
apt-get update -y

info "Installing common dependencies..."
DEPS=(curl wget ca-certificates apt-transport-https software-properties-common git unzip tar pwgen openssl)
apt-get install -y "${DEPS[@]}"

# ---------- PHP version selection ----------
PHP_VER="8.1"
if [[ "$OS_ID" == "ubuntu" && "$OS_VERSION" == "22.04" ]]; then
  info "Ubuntu 22.04 detected — using PHP 8.1 from official repos."
  PHP_VER="8.1"
elif [[ "$OS_ID" == "ubuntu" && "$OS_VERSION" == "24.04" ]]; then
  info "Ubuntu 24.04 detected — using PHP 8.3 from official repos."
  PHP_VER="8.3"
else
  info "Adding PPA for PHP (ondrej)..."
  add-apt-repository -y ppa:ondrej/php || warn "PPA add failed"
  apt-get update -y
  PHP_VER="8.1"
fi

info "Installing panel packages..."
apt-get install -y nginx php${PHP_VER}-fpm php${PHP_VER}-cli php${PHP_VER}-mbstring php${PHP_VER}-xml \
php${PHP_VER}-curl php${PHP_VER}-gd php${PHP_VER}-mysql php${PHP_VER}-zip php${PHP_VER}-bcmath php${PHP_VER}-tokenizer \
mariadb-server redis-server unzip git curl composer certbot python3-certbot-nginx

systemctl enable --now nginx redis-server mariadb || true

# ---------- Step 4: MariaDB setup ----------
MYSQL_ROOT_PASS="$(openssl rand -base64 20)"
PTERO_DB_PASS="$(openssl rand -base64 20)"
PTERO_DB_USER="ptero_user"
PTERO_DB_NAME="pterodactyl"

mysql_secure_commands=$(cat <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
FLUSH PRIVILEGES;
CREATE DATABASE IF NOT EXISTS \`${PTERO_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${PTERO_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${PTERO_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${PTERO_DB_NAME}\`.* TO '${PTERO_DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF
)
echo "$mysql_secure_commands" | mysql -u root || echo "$mysql_secure_commands" | sudo mysql

# ---------- Step 5: Admin user ----------
ADMIN_USER="admin"
ADMIN_EMAIL="admin@gmail.com"
ADMIN_PASS="$(openssl rand -base64 16)"

if id -u "$ADMIN_USER" >/dev/null 2>&1; then
  echo "${ADMIN_USER}:${ADMIN_PASS}" | chpasswd
  usermod -c "admin admin, ${ADMIN_EMAIL}" "$ADMIN_USER"
else
  useradd -m -s /bin/bash -c "admin admin, ${ADMIN_EMAIL}" "$ADMIN_USER"
  echo "${ADMIN_USER}:${ADMIN_PASS}" | chpasswd
fi

# ---------- Step 6: Pterodactyl panel ----------
PANEL_DIR="/var/www/pterodactyl"
[ -d "$PANEL_DIR" ] && mv "$PANEL_DIR" "${PANEL_DIR}_backup_$(date +%s)"
mkdir -p "$PANEL_DIR"
chown -R www-data:www-data "$PANEL_DIR"

sudo -u "$ADMIN_USER" composer create-project --no-dev --ignore-platform-reqs pterodactyl/panel "$PANEL_DIR" || \
git clone https://github.com/pterodactyl/panel.git "$PANEL_DIR"

cd "$PANEL_DIR"
chown -R www-data:www-data "$PANEL_DIR"
cp -n .env.example .env
sed -i "s/DB_DATABASE=.*/DB_DATABASE=${PTERO_DB_NAME}/" .env
sed -i "s/DB_USERNAME=.*/DB_USERNAME=${PTERO_DB_USER}/" .env
sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=${PTERO_DB_PASS}/" .env

sudo -u www-data php artisan key:generate || true
sudo -u www-data php artisan migrate --seed --force || true

# ---------- Step 7: Nginx config ----------
NGINX_CONF="/etc/nginx/sites-available/pterodactyl.conf"
cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name ${PTERO_FQDN};

    root ${PANEL_DIR}/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.access.log;
    error_log /var/log/nginx/pterodactyl.error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$realpath_root;
        internal;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/pterodactyl.conf
nginx -t && systemctl reload nginx

# ---------- Step 8: SSL ----------
HTTPS_ENABLED="no"
if [[ "$USE_LETSENCRYPT" == "yes" ]]; then
  if certbot --nginx -d "${PTERO_FQDN}" --non-interactive --agree-tos -m "${ADMIN_EMAIL}" --redirect; then
    HTTPS_ENABLED="yes"
  fi
fi

# ---------- Step 9: Summary ----------
print_header
success "🎉 Installation complete"
echo
echo "🔐 System admin:"
echo "  User:     $ADMIN_USER"
echo "  Email:    $ADMIN_EMAIL"
echo "  Password: $ADMIN_PASS"
echo
echo "🗄️ Database:"
echo "  Name: $PTERO_DB_NAME"
echo "  User: $PTERO_DB_USER"
echo "  Pass: $PTERO_DB_PASS"
echo "  Root: $MYSQL_ROOT_PASS"
echo
PROTO="http"; [[ "$HTTPS_ENABLED" == "yes" ]] && PROTO="https"
echo "🌐 Panel URL: $PROTO://$PTERO_FQDN"
