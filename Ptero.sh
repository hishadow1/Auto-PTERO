#!/usr/bin/env bash
# ptero_installer.sh
# Interactive Pterodactyl Panel installer with a modern "black theme" UI.
# Supports Debian and Ubuntu (attempts generic recommended steps).
# Creates /etc/certs self-signed cert first, disables ufw, prompts for FQDN,
# attempts Let's Encrypt if appropriate, creates admin user and DB, prints details.
#
# Usage: sudo ./ptero_installer.sh

set -euo pipefail
IFS=$'\n\t'

# ---------- Helpers ----------
info()    { printf "\e[1;37m%s\e[0m\n" "$1"; }  # bright white
success() { printf "\e[1;32m%s\e[0m\n" "$1"; }  # green
warn()    { printf "\e[1;33m%s\e[0m\n" "$1"; }  # yellow
err()     { printf "\e[1;31m%s\e[0m\n" "$1"; }  # red

# Fancy black-theme box header
print_header() {
  printf "\n\e[40m\e[1;37m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m\n"
  printf "\e[40m\e[1;37m   🦖  Pterodactyl Quick Installer — Modern Black UI  ⚙️  🔐  🚀\e[0m\n"
  printf "\e[40m\e[1;37m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m\n\n"
}

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
  err "Please run as root. Use sudo ./ptero_installer.sh"
  exit 1
fi

print_header

# Minimal menu
echo -e "What would you like to install?\n"
echo -e "  1) 🦖  Install Pterodactyl Panel"
echo -e "  2) ❌  Exit"
read -rp $'\nEnter choice (1 or 2): ' CHOICE

if [[ "$CHOICE" != "1" ]]; then
  info "Exiting. No changes made."
  exit 0
fi

# ----------------- Step 0: create /etc/certs and self-signed cert (user requested) -----------------
info "Creating /etc/certs and a self-signed certificate (as requested) — this runs before the installer steps..."
mkdir -p /etc/certs
cd /etc/certs

# Create self-signed cert valid for ~10 years (3650 days)
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" \
  -keyout privkey.pem -out fullchain.pem

cd ~

success "Self-signed cert saved at /etc/certs/fullchain.pem and /etc/certs/privkey.pem"

# ----------------- Step 1: disable UFW -----------------
info "Disabling UFW (setting UFW to no / inactive)..."
if command -v ufw >/dev/null 2>&1; then
  ufw disable || warn "ufw disable returned non-zero; continuing..."
  success "UFW disabled (if installed)."
else
  warn "ufw is not installed on this system; skipping."
fi

# ----------------- Step 2: Ask for FQDN and detect Let's Encrypt need -----------------
read -rp $'\nEnter the FQDN (domain) you will use for Pterodactyl (e.g. panel.example.com). Leave blank for localhost: ' PTERO_FQDN
PTERO_FQDN=${PTERO_FQDN:-localhost}

# Simple heuristic: if FQDN contains at least one dot and is not "localhost", try Let's Encrypt
USE_LETSENCRYPT="no"
if [[ "$PTERO_FQDN" != "localhost" && "$PTERO_FQDN" == *.* ]]; then
  # Ask user whether to attempt Let's Encrypt
  echo
  read -rp "Detected domain-like FQDN. Attempt Let's Encrypt certificate for $PTERO_FQDN? (Y/n): " lechoice
  lechoice=${lechoice:-Y}
  if [[ "$lechoice" =~ ^([yY]|$) ]]; then
    USE_LETSENCRYPT="yes"
  fi
fi

info "FQDN set to: $PTERO_FQDN"
info "Use Let's Encrypt: $USE_LETSENCRYPT"

# ----------------- Step 3: Prepare environment (Debian/Ubuntu detection) -----------------
info "Detecting OS..."
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS_ID=${ID,,}
  OS_VERSION=${VERSION_ID:-}
else
  err "Cannot detect OS. Exiting."
  exit 1
fi

info "Detected: $PRETTY_NAME"

# Update packages
info "Updating package lists..."
apt-get update -y

# Install common dependencies
info "Installing common dependencies..."
DEPS=(curl wget ca-certificates apt-transport-https software-properties-common git unzip tar pwgen openssl)
apt-get install -y "${DEPS[@]}"

# Add PHP repository for newer PHP versions (basic attempt)
info "Adding repository for PHP (if needed)..."
if ! command -v php >/dev/null 2>&1; then
  add-apt-repository -y ppa:ondrej/php || warn "ppa:ondrej/php not available/failed; proceeding without explicit repo"
  apt-get update -y
fi

# Install typical packages for Pterodactyl panel
info "Installing panel packages: nginx, php, redis, mariadb-server, composer, unzip..."
# Choose PHP version; you may change to 8.1 or 8.2 per Pterodactyl requirements
PHP_VER="8.1"

apt-get install -y nginx php${PHP_VER}-fpm php${PHP_VER}-cli php${PHP_VER}-mbstring php${PHP_VER}-xml php${PHP_VER}-curl \
php${PHP_VER}-gd php${PHP_VER}-mysql php${PHP_VER}-zip php${PHP_VER}-bcmath php${PHP_VER}-tokenizer \
mariadb-server redis-server unzip git curl composer certbot python3-certbot-nginx

success "Basic packages installed."

# Start and enable services
systemctl enable --now nginx || warn "nginx enable/start failed; continuing."
systemctl enable --now redis-server || warn "redis enable/start failed; continuing."
systemctl enable --now mariadb || warn "mariadb enable/start failed; continuing."

# ----------------- Step 4: MariaDB setup -----------------
info "Configuring MariaDB (creating database and user for pterodactyl)..."

# Generate strong DB root password and pterodactyl db user password
MYSQL_ROOT_PASS="$(openssl rand -base64 20)"
PTERO_DB_PASS="$(openssl rand -base64 20)"
PTERO_DB_USER="ptero_user"
PTERO_DB_NAME="pterodactyl"

# Set MariaDB root password and auth method; handle auth_socket cases
# Attempt to set a root password and create database/user
mysql_secure_commands=$(cat <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';
FLUSH PRIVILEGES;
CREATE DATABASE IF NOT EXISTS \`${PTERO_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${PTERO_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${PTERO_DB_PASS}';
CREATE USER IF NOT EXISTS '${PTERO_DB_USER}'@'localhost' IDENTIFIED BY '${PTERO_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${PTERO_DB_NAME}\`.* TO '${PTERO_DB_USER}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`${PTERO_DB_NAME}\`.* TO '${PTERO_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
)

# Run SQL commands (may fail if socket auth blocks root; attempt sudo mysql -e fallback)
if mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
  echo "$mysql_secure_commands" | mysql -u root
else
  # Try to run mysql as root via sudo without password (common in Debian/Ubuntu)
  echo "$mysql_secure_commands" | sudo mysql
fi

success "MariaDB configured. Database: ${PTERO_DB_NAME}, DB user: ${PTERO_DB_USER}"

# ----------------- Step 5: Create admin system user -----------------
info "Creating system admin user account 'admin' with email admin@gmail.com..."
ADMIN_USER="admin"
ADMIN_EMAIL="admin@gmail.com"
ADMIN_PASS="$(openssl rand -base64 16)"  # random password for the system user

# Check if user exists
if id -u "$ADMIN_USER" >/dev/null 2>&1; then
  warn "User $ADMIN_USER already exists. Overwriting password and GECOS fields."
  echo "${ADMIN_USER}:${ADMIN_PASS}" | chpasswd
  usermod -c "admin admin, ${ADMIN_EMAIL}" "$ADMIN_USER" || true
else
  useradd -m -s /bin/bash -c "admin admin, ${ADMIN_EMAIL}" "$ADMIN_USER"
  echo "${ADMIN_USER}:${ADMIN_PASS}" | chpasswd
fi
success "System user 'admin' created/updated."

# ----------------- Step 6: Download & configure Pterodactyl panel (skeleton) -----------------
info "Downloading Pterodactyl panel (skeleton) to /var/www/pterodactyl..."
PANEL_DIR="/var/www/pterodactyl"

if [[ -d "$PANEL_DIR" ]]; then
  warn "$PANEL_DIR already exists; moving to ${PANEL_DIR}_backup_$(date +%s)"
  mv "$PANEL_DIR" "${PANEL_DIR}_backup_$(date +%s)"
fi

mkdir -p "$PANEL_DIR"
chown -R www-data:www-data "$PANEL_DIR"

# Download latest panel release (composer create-project approach)
info "Using composer to create project (this may take a while)..."
sudo -u "$ADMIN_USER" composer create-project --no-dev --ignore-platform-reqs pterodactyl/panel "$PANEL_DIR" || {
  warn "composer create-project failed; attempting git clone fallback..."
  git clone https://github.com/pterodactyl/panel.git "$PANEL_DIR"
  cd "$PANEL_DIR"
  sudo -u "$ADMIN_USER" composer install --no-dev --ignore-platform-reqs || warn "composer install fallback failed"
}

# Set permissions (typical)
chown -R www-data:www-data "$PANEL_DIR"
find "$PANEL_DIR" -type f -print0 | xargs -0 chmod 640 || true
find "$PANEL_DIR" -type d -print0 | xargs -0 chmod 750 || true

# Copy example env and set DB credentials
if [[ -f "$PANEL_DIR/.env.example" && ! -f "$PANEL_DIR/.env" ]]; then
  cp "$PANEL_DIR/.env.example" "$PANEL_DIR/.env"
  sed -i "s/DB_DATABASE=.*/DB_DATABASE=${PTERO_DB_NAME}/" "$PANEL_DIR/.env"
  sed -i "s/DB_USERNAME=.*/DB_USERNAME=${PTERO_DB_USER}/" "$PANEL_DIR/.env"
  sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=${PTERO_DB_PASS}/" "$PANEL_DIR/.env"
fi

# Generate application key and migrate (artisan commands)
info "Generating app key and running migrations (artisan)..."
cd "$PANEL_DIR"
sudo -u www-data php artisan key:generate || warn "artisan key:generate failed"
sudo -u www-data php artisan migrate --seed --force || warn "artisan migrate failed; continue if previously run"

# ----------------- Step 7: Nginx site configuration -----------------
info "Creating nginx site configuration for Pterodactyl..."

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

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
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
nginx -t || warn "nginx -t returned non-zero; check configuration"
systemctl reload nginx || warn "nginx reload failed"

# ----------------- Step 8: Obtain Let's Encrypt (if chosen) -----------------
HTTPS_ENABLED="no"
if [[ "$USE_LETSENCRYPT" == "yes" ]]; then
  info "Attempting to obtain Let's Encrypt certificate for $PTERO_FQDN via certbot..."
  if command -v certbot >/dev/null 2>&1; then
    # Try to automatically configure nginx and redirect
    if certbot --nginx -d "${PTERO_FQDN}" --non-interactive --agree-tos -m "${ADMIN_EMAIL}" --redirect; then
      success "Let's Encrypt certificate obtained and configured for ${PTERO_FQDN}"
      HTTPS_ENABLED="yes"
    else
      warn "certbot --nginx failed; will keep using self-signed cert at /etc/certs"
      HTTPS_ENABLED="no"
    fi
  else
    warn "certbot not available; skipping Let's Encrypt."
    HTTPS_ENABLED="no"
  fi
else
  info "User opted out or domain unsuitable for Let's Encrypt. Using self-signed cert created earlier."
  HTTPS_ENABLED="no"
fi

# If no Let's Encrypt, ensure nginx uses the self-signed cert (basic TLS config)
if [[ "$HTTPS_ENABLED" == "no" ]]; then
  info "Configuring nginx to serve TLS with self-signed cert (/etc/certs)..."
  cat > /etc/nginx/snippets/pterodactyl-ssl.conf <<EOF
ssl_certificate /etc/certs/fullchain.pem;
ssl_certificate_key /etc/certs/privkey.pem;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
EOF

  # Modify site to listen on 443 (append basic server block)
  cat > /etc/nginx/sites-available/pterodactyl-ssl.conf <<EOF
server {
    listen 443 ssl http2;
    server_name ${PTERO_FQDN};

    root ${PANEL_DIR}/public;
    index index.php;

    include /etc/nginx/snippets/pterodactyl-ssl.conf;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
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

  ln -sf /etc/nginx/sites-available/pterodactyl-ssl.conf /etc/nginx/sites-enabled/pterodactyl-ssl.conf
  nginx -t || warn "nginx -t failed after adding SSL block"
  systemctl reload nginx || warn "nginx reload failed"
fi

# ----------------- Step 9: Finalize Panel Admin (seeded during migrations in many installs) -----------------
# Pterodactyl admin user creation via CLI is complex & may require artisan commands and queue worker.
# We will output the admin system account and DB credentials for the user to register/create the panel admin.
# (Automating panel admin creation via artisan tinker could be added if desired.)

# ----------------- Step 10: Summary & output credentials -----------------
echo
print_header
success "🎉 Installation attempt completed (some steps may require manual follow-up)."
echo

echo -e "🔐  System admin account created:"
echo -e "    Username: \e[1;36m${ADMIN_USER}\e[0m"
echo -e "    Email:    \e[1;36m${ADMIN_EMAIL}\e[0m"
echo -e "    Password: \e[1;33m${ADMIN_PASS}\e[0m"

echo
echo -e "🗄️  Database credentials (MariaDB):"
echo -e "    DB Name: \e[1;36m${PTERO_DB_NAME}\e[0m"
echo -e "    DB User: \e[1;36m${PTERO_DB_USER}\e[0m"
echo -e "    DB Pass: \e[1;33m${PTERO_DB_PASS}\e[0m"
echo -e "    DB Root: \e[1;33m${MYSQL_ROOT_PASS}\e[0m"

echo
PROTO="http"
if [[ "$HTTPS_ENABLED" == "yes" ]]; then
  PROTO="https"
else
  # If self-signed configured with ssl, still show https
  if [[ -f /etc/certs/fullchain.pem ]]; then
    PROTO="https"
  fi
fi

echo -e "🌐  Pterodactyl Panel URL: \e[1;36m${PROTO}://${PTERO_FQDN}\e[0m"

echo
info "Notes & next steps:"
echo "- Visit the URL above and complete the web-based panel setup."
echo "- If panel admin account not created automatically, create the admin user via the web or artisan commands."
echo "- Check /var/log/nginx/pterodactyl.error.log and /var/log/nginx/pterodactyl.access.log for nginx logs."
echo "- You may want to secure MariaDB root further and tune PHP settings per Pterodactyl docs."

success "✅ Done. If anything failed above you'll see warnings; review them and fix as needed."

echo
printf "\e[40m\e[1;37m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m\n"
printf "\e[40m\e[1;37m   🚀  Enjoy! — Pterodactyl installer finished.  🦖\e[0m\n"
printf "\e[40m\e[1;37m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\e[0m\n"
echo
