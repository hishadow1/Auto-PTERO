#!/bin/bash
set -euo pipefail

######################################################################################
# Auto Pterodactyl Installer - Self-contained (no lib.sh)
# - Preserves original behaviour
# - Adds systemd detection and fallbacks for systemd-less containers (SSHx, etc.)
# - Adds some missing php deps commonly required
######################################################################################

# ---------------- Pre-setup SSL cert ---------------- #
mkdir -p /etc/certs
cd /etc/certs
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" \
  -keyout privkey.pem -out fullchain.pem
cd ~

# --------------- Basic helper functions --------------- #
output() { echo -e "\033[1;36m[INFO]\033[0m $1"; }
success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; }
gen_passwd() { < /dev/urandom tr -dc A-Za-z0-9 | head -c"${1:-32}"; echo; }

# ---------- Add: service starter that detects systemd ---------- #
start_service() {
  local svc="$1"
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    output "Starting & enabling ${svc} via systemctl"
    # try enable+start; if fails, try start
    systemctl enable --now "$svc" 2>/dev/null || systemctl start "$svc" 2>/dev/null || true
  else
    output "systemd not detected — attempting to start ${svc} via service (non-persistent)"
    # best-effort: service start (some minimal containers have it)
    service "$svc" start 2>/dev/null || {
      # try calling the daemon directly for common services
      case "$svc" in
        php8.1-fpm) if command -v php-fpm8.1 >/dev/null 2>&1; then php-fpm8.1 --nodaemonize >/dev/null 2>&1 & fi ;;
        redis-server) if command -v redis-server >/dev/null 2>&1; then redis-server /etc/redis/redis.conf >/dev/null 2>&1 & fi ;;
        mariadb|mysql) if command -v mysqld >/dev/null 2>&1; then mysqld_safe >/dev/null 2>&1 & fi ;;
        nginx) if command -v nginx >/dev/null 2>&1; then nginx >/dev/null 2>&1 || true; fi ;;
      esac
    }
  fi
}

# ---------- Small status helper ----------
check_running() {
  local svc_name="$1"
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl is-active --quiet "$svc_name" && return 0 || return 1
  else
    # naive check: look for common process names
    case "$svc_name" in
      php8.1-fpm) pgrep -f "php-fpm: master" >/dev/null 2>&1 && return 0 || pgrep -f "php8.1-fpm" >/dev/null 2>&1 && return 0 || return 1 ;;
      redis-server) pgrep -f redis-server >/dev/null 2>&1 && return 0 || return 1 ;;
      mariadb|mysql) pgrep -f mysqld >/dev/null 2>&1 && return 0 || return 1 ;;
      nginx) pgrep -f nginx >/dev/null 2>&1 && return 0 || return 1 ;;
      *) return 1 ;;
    esac
  fi
}

# ------------------ Variables ----------------- #

FQDN="cold-rabbit-94.telebit.io"

# MySQL
MYSQL_DB="panel"
MYSQL_USER="pterodactyl"
MYSQL_PASSWORD="$(gen_passwd 64)"

# Environment
timezone="Europe/Stockholm"

# SSL + Firewall
ASSUME_SSL="true"
CONFIGURE_LETSENCRYPT="true"
CONFIGURE_FIREWALL="false"

# Admin User
email="admin@gmail.com"
user_email="admin@gmail.com"
user_username="admin"
user_firstname="admin"
user_lastname="admin"
user_password="admin"

# Panel download URL (latest)
PANEL_DL_URL="https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz"

# --------- Functions (unchanged names, improved internals) -------- #

dep_install() {
  output "Installing dependencies..."
  apt update -y
  apt install -y software-properties-common curl wget unzip git lsb-release ca-certificates apt-transport-https gnupg
  LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php || true
  apt update -y
  # added php8.1-zip and php8.1-intl as they are commonly required
  apt install -y php8.1 php8.1-cli php8.1-gd php8.1-mysql php8.1-pdo php8.1-mbstring php8.1-bcmath php8.1-xml php8.1-fpm php8.1-curl php8.1-zip php8.1-intl \
                 mariadb-server redis-server nginx certbot python3-certbot-nginx unzip
  # start services using start_service() (works in systemd and non-systemd)
  start_service mariadb
  start_service redis-server
  start_service php8.1-fpm
  start_service nginx
  success "Dependencies installed!"
}

install_composer() {
  output "Installing composer..."
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  success "Composer installed!"
}

ptdl_dl() {
  output "Downloading Pterodactyl panel..."
  mkdir -p /var/www/pterodactyl
  cd /var/www/pterodactyl
  curl -Lo panel.tar.gz "$PANEL_DL_URL"
  tar -xzvf panel.tar.gz
  # fix: chmod the folders, not glob children which may not exist yet
  chmod -R 755 storage bootstrap/cache || true
  cp .env.example .env || true
  success "Panel files downloaded!"
}

install_composer_deps() {
  output "Installing composer dependencies..."
  cd /var/www/pterodactyl
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
  success "Composer dependencies installed!"
}

create_db_user() {
  output "Creating MySQL user..."
  # Using `mysql -e` as root with unix_socket auth; assume root allowed without password
  mysql -u root -e "CREATE USER IF NOT EXISTS '$1'@'127.0.0.1' IDENTIFIED BY '$2';" || true
  success "MySQL user created!"
}

create_db() {
  output "Creating MySQL database..."
  mysql -u root -e "CREATE DATABASE IF NOT EXISTS $1;" || true
  mysql -u root -e "GRANT ALL PRIVILEGES ON $1.* TO '$2'@'127.0.0.1'; FLUSH PRIVILEGES;" || true
  success "Database created!"
}

configure() {
  output "Configuring panel..."
  cd /var/www/pterodactyl

  php artisan key:generate --force

  php artisan p:environment:setup \
    --author="$email" \
    --url="https://$FQDN" \
    --timezone="$timezone" \
    --cache="redis" \
    --session="redis" \
    --queue="redis" \
    --redis-host="localhost" \
    --redis-pass="null" \
    --redis-port="6379" \
    --settings-ui=true \
    --telemetry=true

  php artisan p:environment:database \
    --host="127.0.0.1" \
    --port="3306" \
    --database="$MYSQL_DB" \
    --username="$MYSQL_USER" \
    --password="$MYSQL_PASSWORD"

  php artisan migrate --seed --force

  php artisan p:user:make \
    --email="$user_email" \
    --username="$user_username" \
    --name-first="$user_firstname" \
    --name-last="$user_lastname" \
    --password="$user_password" \
    --admin=1

  success "Panel configured!"
}

set_folder_permissions() {
  chown -R www-data:www-data /var/www/pterodactyl
  chmod -R 755 /var/www/pterodactyl/storage /var/www/pterodactyl/bootstrap/cache || true
  success "Permissions set!"
}

insert_cronjob() {
  (crontab -l 2>/dev/null; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -
  success "Cronjob added!"
}

install_pteroq() {
  # If systemd exists, install a systemd service (your original behavior).
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    output "Installing pteroq systemd service"
    cat > /etc/systemd/system/pteroq.service <<'EOF'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || true
    start_service pteroq || true
    success "pteroq systemd service installed!"
  else
    # Non-systemd fallback: create a simple runner script and launch it in background (non-persistent)
    output "Systemd not found — creating background pteroq runner (non-persistent)"
    cat > /usr/local/bin/pteroq-run <<'EOF'
#!/bin/bash
cd /var/www/pterodactyl
exec /usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
EOF
    chmod +x /usr/local/bin/pteroq-run
    # Try nohup to run it in background now (best-effort)
    nohup /usr/local/bin/pteroq-run >/var/log/pteroq.log 2>&1 & disown || true
    # Add an @reboot cron entry (may not work in some container providers)
    (crontab -l 2>/dev/null; echo "@reboot /usr/local/bin/pteroq-run >> /var/log/pteroq.log 2>&1") | crontab - || true
    success "pteroq runner created and started (non-persistent)."
  fi
}

configure_nginx_fallback_ssl() {
  output "Configuring Nginx with fallback SSL..."
  cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name $FQDN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $FQDN;

    root /var/www/pterodactyl/public;
    index index.php;

    ssl_certificate     /etc/certs/fullchain.pem;
    ssl_certificate_key /etc/certs/privkey.pem;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
  # reload/restart nginx via start_service() or fallback
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl restart nginx || nginx -s reload || true
  else
    service nginx restart 2>/dev/null || nginx -s reload || true
  fi
  success "Nginx configured!"
}

# --------------- Main --------------- #

perform_install() {
  output "Starting installation..."
  dep_install
  install_composer
  ptdl_dl
  install_composer_deps
  create_db_user "$MYSQL_USER" "$MYSQL_PASSWORD"
  create_db "$MYSQL_DB" "$MYSQL_USER"
  configure
  set_folder_permissions
  insert_cronjob
  install_pteroq
  configure_nginx_fallback_ssl
  certbot --nginx --non-interactive --agree-tos --redirect --email "$email" -d "$FQDN" || true

  echo -e "\n==============================================="
  echo -e " ✅ Pterodactyl Panel Installed Successfully!"
  echo -e " 🌐 URL: https://$FQDN"
  echo -e " 👤 Username: $user_username"
  echo -e " 📧 Email: $user_email"
  echo -e " 🔑 Password: $user_password"
  echo -e " 📊 Telemetry: ENABLED"
  echo -e " 🔐 SSL certs: /etc/certs/ (fallback) + Let's Encrypt (if successful)"
  echo -e "===============================================\n"

  # Post-install checks and helpful hints:
  echo -e "[INFO] Checking critical services..."
  for svc in mariadb redis-server php8.1-fpm nginx; do
    if check_running "$svc"; then
      echo -e "  - $svc: running"
    else
      echo -e "  - $svc: NOT running (try: start_service $svc or run 'service $svc start')"
    fi
  done

  # Note about systemd-less environment:
  if ! (command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]); then
    echo -e "\n[NOTICE] Your environment appears to NOT have systemd."
    echo -e "  * Services were started with best-effort fallbacks (service/nohup)."
    echo -e "  * These fallbacks may NOT persist across reboots. For production, use a VPS with systemd."
    echo -e "  * If you get 502 Bad Gateway, ensure php-fpm is running (try: service php8.1-fpm start).\n"
  fi
}

perform_install
