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
#   UTILS
# =======================
log() { echo -e "\e[92m[INFO]\e[0m $*"; }
err() { echo -e "\e[91m[ERROR]\e[0m $*" >&2; }
generate_password() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 14 || echo "Pter0Pass123"; }
get_ip() { curl -s https://ipinfo.io/ip || hostname -I | awk '{print $1}'; }

# =======================
#   PANEL INSTALLATION
# =======================
install_panel() {
  log "=== Installing Pterodactyl Panel ==="
  read -rp "Enter FQDN for Panel (leave empty to use server IP): " PANEL_FQDN
  SERVER_IP=$(get_ip)

  # Basic deps
  apt-get update -y && apt-get install -y \
    software-properties-common curl ca-certificates gnupg lsb-release unzip git tar wget build-essential mariadb-server redis-server nginx ufw whiptail

  # PHP
  add-apt-repository -y ppa:ondrej/php
  apt-get update -y
  apt-get install -y php${PHP_VERSION} php${PHP_VERSION}-{cli,fpm,gd,mysql,mbstring,bcmath,xml,curl,zip,redis}

  systemctl enable --now php${PHP_VERSION}-fpm mariadb redis-server nginx

  # Composer
  if ! command -v composer >/dev/null; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  fi

  # Node & Yarn
  curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
  apt-get install -y nodejs yarn

  # Firewall
  ufw allow OpenSSH
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable

  # Clone panel
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

  mysql -uroot -p"$MYSQL_ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"
  mysql -uroot -p"$MYSQL_ROOT_PASS" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}'; GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

  echo "DB_USER=${DB_USER}" > "$DB_INFO_FILE"
  echo "DB_PASS=${DB_PASS}" >> "$DB_INFO_FILE"
  chmod 600 "$DB_INFO_FILE"

  sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|" .env
  sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|" .env
  sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env
  if [ -n "${PANEL_FQDN:-}" ]; then
    sed -i "s|APP_URL=.*|APP_URL=https://${PANEL_FQDN}|" .env
    PANEL_URL="https://${PANEL_FQDN}"
  else
    sed -i "s|APP_URL=.*|APP_URL=https://${SERVER_IP}|" .env
    PANEL_URL="https://${SERVER_IP}"
  fi

  # Laravel setup
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

  # Save credentials to file
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

  # =======================
  #   Nginx + SSL
  # =======================
  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/certs

  if [ -n "${PANEL_FQDN:-}" ]; then
    log "Attempting Let's Encrypt SSL setup..."
    apt-get install -y certbot python3-certbot-nginx
    if certbot --nginx -d "$PANEL_FQDN" --non-interactive --agree-tos -m "$ADMIN_EMAIL"; then
      log "Let's Encrypt SSL installed successfully."
    else
      log "Let's Encrypt failed. Falling back to self-signed SSL."
      openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
        -subj "/C=NA/ST=NA/L=NA/O=NA/CN=${PANEL_FQDN}" \
        -keyout /etc/certs/privkey.pem -out /etc/certs/fullchain.pem

      cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name ${PANEL_FQDN};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${PANEL_FQDN};

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
    fi
  else
    log "No FQDN provided. Setting up self-signed SSL."
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
      -subj "/C=NA/ST=NA/L=NA/O=NA/CN=${SERVER_IP}" \
      -keyout /etc/certs/privkey.pem -out /etc/certs/fullchain.pem

    cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name ${SERVER_IP};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${SERVER_IP};

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
  fi

  ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
  nginx -t && systemctl reload nginx

  # Final box
  whiptail --title "✅ Pterodactyl Installed" \
    --msgbox "Panel installed successfully!\n\nUsername: $ADMIN_USERNAME\nEmail: $ADMIN_EMAIL\nPassword: $ADMIN_PASS\nURL: $PANEL_URL\n\n💾 Saved to: $CRED_FILE" 18 70
}

# =======================
#   MAIN
# =======================
if [ "$EUID" -ne 0 ]; then
  err "Run as root"
  exit 1
fi

apt-get update -y && apt-get install -y whiptail

CHOICE=$(whiptail --title "🚀 Pterodactyl Installer" \
  --menu "Choose what to install:" 15 60 4 \
  "1" "Install Pterodactyl Panel" \
  "2" "Quit" \
  3>&1 1>&2 2>&3)

case $CHOICE in
  1) install_panel ;;
  2) exit 0 ;;
esac
