#!/bin/bash
set -e

######################################################################################
# Auto Pterodactyl Installer - Self-contained (no lib.sh)                            #
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

# --------- Functions -------- #

dep_install() {
  output "Installing dependencies..."
  apt update -y
  apt install -y software-properties-common curl wget unzip git lsb-release ca-certificates apt-transport-https gnupg
  LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
  apt update -y
  apt install -y php8.1 php8.1-cli php8.1-gd php8.1-mysql php8.1-pdo php8.1-mbstring php8.1-bcmath php8.1-xml php8.1-fpm php8.1-curl \
                 mariadb-server redis-server nginx certbot python3-certbot-nginx
  systemctl enable --now mariadb redis-server php8.1-fpm
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
  chmod -R 755 storage/* bootstrap/cache/
  cp .env.example .env
  success "Panel files downloaded!"
}

install_composer_deps() {
  output "Installing composer dependencies..."
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
  success "Composer dependencies installed!"
}

create_db_user() {
  output "Creating MySQL user..."
  mysql -u root -e "CREATE USER IF NOT EXISTS '$1'@'127.0.0.1' IDENTIFIED BY '$2';"
  success "MySQL user created!"
}

create_db() {
  output "Creating MySQL database..."
  mysql -u root -e "CREATE DATABASE IF NOT EXISTS $1;"
  mysql -u root -e "GRANT ALL PRIVILEGES ON $1.* TO '$2'@'127.0.0.1'; FLUSH PRIVILEGES;"
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
  chmod -R 755 /var/www/pterodactyl/storage /var/www/pterodactyl/bootstrap/cache
  success "Permissions set!"
}

insert_cronjob() {
  (crontab -l 2>/dev/null; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -
  success "Cronjob added!"
}

install_pteroq() {
  cat > /etc/systemd/system/pteroq.service <<EOF
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

  systemctl enable --now pteroq
  success "pteroq service installed!"
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
  systemctl restart nginx
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
}

perform_install
