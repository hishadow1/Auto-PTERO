#!/bin/bash

set -e

######################################################################################
# Auto Pterodactyl Installer - Modified for Shadow                                    #
######################################################################################

# ---------------- Pre-setup SSL cert ---------------- #
mkdir -p /etc/certs
cd /etc/certs
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" \
  -keyout privkey.pem -out fullchain.pem
cd ~

# ----------------------------------------------------- #

fn_exists() { declare -F "$1" >/dev/null; }
if ! fn_exists lib_loaded; then
  source /tmp/lib.sh || source <(curl -sSL "$GITHUB_BASE_URL/$GITHUB_SOURCE"/lib/lib.sh)
  ! fn_exists lib_loaded && echo "* ERROR: Could not load lib script" && exit 1
fi

# ------------------ Variables ----------------- #

# Domain name / IP
FQDN="cold-rabbit-94.telebit.io"

# Default MySQL credentials
MYSQL_DB="panel"
MYSQL_USER="pterodactyl"
MYSQL_PASSWORD="$(gen_passwd 64)"

# Environment
timezone="Europe/Stockholm"

# SSL and Firewall
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

# --------- Main installation functions -------- #

install_composer() {
  output "Installing composer.."
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  success "Composer installed!"
}

ptdl_dl() {
  output "Downloading pterodactyl panel files .. "
  mkdir -p /var/www/pterodactyl
  cd /var/www/pterodactyl || exit

  curl -Lo panel.tar.gz "$PANEL_DL_URL"
  tar -xzvf panel.tar.gz
  chmod -R 755 storage/* bootstrap/cache/

  cp .env.example .env

  success "Downloaded pterodactyl panel files!"
}

install_composer_deps() {
  output "Installing composer dependencies.."
  [ "$OS" == "rocky" ] || [ "$OS" == "almalinux" ] && export PATH=/usr/local/bin:$PATH
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
  success "Installed composer dependencies!"
}

configure() {
  output "Configuring environment.."

  local app_url="https://$FQDN"

  php artisan key:generate --force

  php artisan p:environment:setup \
    --author="$email" \
    --url="$app_url" \
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

  success "Configured environment!"
}

configure_nginx_fallback_ssl() {
  output "Configuring Nginx fallback SSL.."
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
  success "Fallback SSL configured!"
}

# --------------- Main functions --------------- #

perform_install() {
  output "Starting installation.. this might take a while!"
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

  return 0
}

# ------------------- Install ------------------ #

perform_install
