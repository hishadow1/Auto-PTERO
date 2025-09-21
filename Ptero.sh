#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# =======================
#   CONFIG
# =======================
PTERO_DIR="/var/www/pterodactyl"
PTERO_REPO="https://github.com/pterodactyl/panel.git"
ADMIN_USERNAME="admin"
ADMIN_EMAIL="admin@gmail.com"
ADMIN_FIRST="admin"
ADMIN_LAST="admin"
CRED_FILE="/root/ptero_credentials.txt"
DB_INFO_FILE="/root/pterodactyl_db_info.txt"
PHP_VERSION="8.1"

# =======================
#   COLORS & UTILS
# =======================
GREEN="\e[1;32m"
RED="\e[1;31m"
YELLOW="\e[1;33m"
BLUE="\e[1;34m"
BOLD="\e[1;1m"
NC="\e[0m"

log() { echo -e "${GREEN}[✔]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err() { echo -e "${RED}[✖]${NC} $*" >&2; }
generate_password() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 14 || echo "Pter0Pass123"; }
get_ip() { curl -s https://ipinfo.io/ip || hostname -I | awk '{print $1}'; }

# =======================
#   PANEL INSTALLATION
# =======================
install_panel() {
  echo -e "\n${BOLD}${BLUE}🚀 Starting Pterodactyl Panel Installation...${NC}\n"
  read -rp "🌐 Enter FQDN for Panel (leave empty to use server IP): " PANEL_FQDN
  SERVER_IP=$(get_ip)
  PANEL_URL=${PANEL_FQDN:-$SERVER_IP}
  log "Panel will be accessible at: $PANEL_URL"

  # Dependencies
  log "Installing dependencies..."
  apt-get update -y && apt-get install -y software-properties-common curl ca-certificates gnupg lsb-release unzip git tar wget build-essential mariadb-server redis-server nginx ufw

  # PHP
  add-apt-repository -y ppa:ondrej/php
  apt-get update -y
  apt-get install -y php${PHP_VERSION} php${PHP_VERSION}-{cli,fpm,gd,mysql,mbstring,bcmath,xml,curl,zip,redis}

  systemctl enable --now php${PHP_VERSION}-fpm mariadb redis-server nginx

  # Composer
  if ! command -v composer >/dev/null; then
    log "Installing Composer..."
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  fi

  # Node & Yarn
  curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
  apt-get install -y nodejs yarn

  # Firewall
  log "Configuring firewall..."
  ufw allow OpenSSH
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable

  # Clone panel
  log "Cloning Pterodactyl Panel..."
  mkdir -p "$PTERO_DIR"
  git clone --depth 1 "$PTERO_REPO" "$PTERO_DIR"
  cd "$PTERO_DIR"
  cp .env.example .env

  # DB setup
  MYSQL_ROOT_PASS=$(generate_password)
  mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}'; FLUSH PRIVILEGES;" || true
  echo "$MYSQL_ROOT_PASS" > /root/.mysql_root_pass

  DB_NAME="pterodactyl"
  DB_USER="pterodactyl"
  DB_PASS=$(generate_password)

  log "Creating database and user..."
  mysql -uroot -p"$MYSQL_ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"
  mysql -uroot -p"$MYSQL_ROOT_PASS" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}'; GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

  echo "DB_USER=${DB_USER}" > "$DB_INFO_FILE"
  echo "DB_PASS=${DB_PASS}" >> "$DB_INFO_FILE"
  chmod 600 "$DB_INFO_FILE"

  sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|" .env
  sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|" .env
  sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env
  sed -i "s|APP_URL=.*|APP_URL=https://${PANEL_URL}|" .env

  # Laravel setup
  log "Setting up Laravel..."
  composer install --no-dev --optimize-autoloader
  php artisan key:generate --force
  php artisan migrate --seed --force

  # Permissions
  chown -R www-data:www-data "$PTERO_DIR"

  # Cron
  (crontab -l -u www-data 2>/dev/null || true; echo "* * * * * php $PTERO_DIR/artisan schedule:run >> /dev/null 2>&1") | crontab -u www-data -

  # Admin user
  ADMIN_PASS=$(generate_password)
  php artisan p:user:make \
    --email="$ADMIN_EMAIL" \
    --username="$ADMIN_USERNAME" \
    --name-first="$ADMIN_FIRST" \
    --name-last="$ADMIN_LAST" \
    --password="$ADMIN_PASS" \
    --admin=1 --no-interaction || true

  # Save credentials
  {
    echo "======================================"
    echo "  Pterodactyl Panel Admin Credentials "
    echo "======================================"
    echo "Username : $ADMIN_USERNAME"
    echo "Email    : $ADMIN_EMAIL"
    echo "Password : $ADMIN_PASS"
    echo "Panel URL: $PANEL_URL"
    echo "======================================"
    echo "Saved on: $(date)"
  } > "$CRED_FILE"
  chmod 600 "$CRED_FILE"

  # Nginx + SSL
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/certs

  if [ -n "${PANEL_FQDN:-}" ]; then
    log "Attempting Let's Encrypt SSL..."
    apt-get install -y certbot python3-certbot-nginx
    if certbot --nginx -d "$PANEL_FQDN" --non-interactive --agree-tos -m "$ADMIN_EMAIL"; then
      log "✅ Let's Encrypt SSL installed."
    else
      warn "LE failed. Using self-signed SSL."
      openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
        -subj "/C=NA/ST=NA/L=NA/O=NA/CN=${PANEL_FQDN}" \
        -keyout /etc/certs/privkey.pem -out /etc/certs/fullchain.pem
    fi
  else
    warn "No FQDN. Using self-signed SSL."
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
      -subj "/C=NA/ST=NA/L=NA/O=NA/CN=${SERVER_IP}" \
      -keyout /etc/certs/privkey.pem -out /etc/certs/fullchain.pem
  fi

  # Nginx config
  cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name ${PANEL_URL};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${PANEL_URL};

    ssl_certificate /etc/certs/fullchain.pem;
    ssl_certificate_key /etc/certs/privkey.pem;

    root ${PTERO_DIR}/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
  nginx -t && systemctl reload nginx

  # Final message
  echo -e "\n${BOLD}${GREEN}✅ Pterodactyl Panel Installed Successfully!${NC}"
  echo -e "${BOLD}Username:${NC} $ADMIN_USERNAME"
  echo -e "${BOLD}Email:   ${NC} $ADMIN_EMAIL"
  echo -e "${BOLD}Password:${NC} $ADMIN_PASS"
  echo -e "${BOLD}Panel:   ${NC} $PANEL_URL"
  echo -e "${BOLD}Saved to:${NC} $CRED_FILE"
  echo -e "======================================\n"
}

# =======================
#   MAIN MENU
# =======================
if [ "$EUID" -ne 0 ]; then
  err "Run as root!"
  exit 1
fi

while true; do
  echo -e "${BOLD}${BLUE}============================================${NC}"
  echo -e "${BOLD}${BLUE}🚀 Pterodactyl Installer${NC}"
  echo -e "${BOLD}${BLUE}============================================${NC}"
  echo -e "1️⃣  Install Pterodactyl Panel"
  echo -e "2️⃣  Quit"
  echo -e "============================================"
  read -rp "Enter choice [1-2]: " CHOICE
  CHOICE=$(echo "$CHOICE" | tr -d '[:space:]')  # remove spaces

  case "$CHOICE" in
    1) install_panel; break ;;
    2) echo -e "${YELLOW}Exiting...${NC}"; exit 0 ;;
    *) err "Invalid choice! Please enter 1 or 2." ;;
  esac
done
