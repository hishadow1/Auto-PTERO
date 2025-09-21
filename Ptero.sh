#!/bin/bash
set -e

# ================================
# 🎨 Full Pterodactyl Installer (Fixed PHP 8.2 & Dependencies)
# ================================

# Colors
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"; PURPLE="\e[35m"; RESET="\e[0m"

# Helper functions
info() { echo -e "${CYAN}ℹ️  [INFO]${RESET} $1"; }
ok() { echo -e "${GREEN}✅ [OK]${RESET} $1"; }
warn() { echo -e "${YELLOW}⚠️  [WARN]${RESET} $1"; }
err() { echo -e "${RED}❌ [ERROR]${RESET} $1"; }

# Generate random password
random_pw() { openssl rand -base64 12; }

# Detect public IP
SERVER_IP=$(curl -s ifconfig.me || echo "YOUR_SERVER_IP")
info "Detected server IP: 🌐 $SERVER_IP"

# ------------------------------
# Main Menu
# ------------------------------
while true; do
    echo -e "\n${PURPLE}==============================================${RESET}"
    echo -e "${PURPLE}🚀 Server Installer Menu 🚀${RESET}"
    echo -e "${PURPLE}==============================================${RESET}"
    echo "1️⃣  Install Pterodactyl Panel"
    echo "2️⃣  Install Wings / Daemon (Coming Soon)"
    echo "0️⃣  Exit"
    echo
    read -rp "Enter your choice: " CHOICE

    case "$CHOICE" in
        1)
            PANEL_DIR="/var/www/pterodactyl"
            PANEL_CONF="/etc/nginx/sites-available/pterodactyl.conf"

            read -rp "🛡️  Configure UFW firewall? (y/n): " SETUP_UFW
            read -rp "🔒 Configure Let's Encrypt SSL? (y/n): " SETUP_SSL

            # ------------------------------
            # System Update & Dependencies
            # ------------------------------
            info "🔄 Updating system..."
            apt update -y && apt upgrade -y

            info "📦 Installing base tools..."
            apt install -y software-properties-common curl lsb-release ca-certificates gnupg unzip git composer ufw certbot python3-certbot-nginx

            # Add PHP 8.2 PPA
            info "🧩 Adding PHP 8.2 PPA..."
            add-apt-repository ppa:ondrej/php -y
            apt update -y

            # Install PHP 8.2 packages
            info "📦 Installing PHP 8.2 and required extensions..."
            apt install -y php8.2-cli php8.2-fpm php8.2-gd php8.2-mysql php8.2-pdo \
php8.2-mbstring php8.2-tokenizer php8.2-bcmath php8.2-xml php8.2-curl

            # Install database and cache
            info "📦 Installing MariaDB and Redis..."
            apt install -y mariadb-server mariadb-client redis-server nginx

            # Enable services
            for service in mariadb redis-server nginx php8.2-fpm; do
                systemctl enable $service --now
            done

            # ------------------------------
            # Database Setup
            # ------------------------------
            DB_NAME="panel"
            DB_USER="ptero"
            DB_PASS_FILE="/root/.ptero_db_pass"

            if mysql -u root -e "USE ${DB_NAME};" &>/dev/null; then
                ok "Database '${DB_NAME}' exists, skipping."
                DB_PASS=$(cat $DB_PASS_FILE)
            else
                DB_PASS="$(random_pw)"
                mysql -u root <<MYSQL_SECURE
CREATE DATABASE ${DB_NAME};
CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
MYSQL_SECURE
                echo "$DB_PASS" > $DB_PASS_FILE
                ok "Database '${DB_NAME}' created."
            fi

            # ------------------------------
            # Panel Setup
            # ------------------------------
            if [[ ! -d "$PANEL_DIR" ]]; then
                info "📥 Downloading Pterodactyl panel..."
                mkdir -p "$PANEL_DIR"
                cd "$PANEL_DIR"
                curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
                tar -xzvf panel.tar.gz && rm panel.tar.gz
                cp .env.example .env
            else
                ok "Pterodactyl folder exists, skipping download."
            fi

            cd "$PANEL_DIR"
            sed -i "s/DB_DATABASE=.*/DB_DATABASE=${DB_NAME}/" .env
            sed -i "s/DB_USERNAME=.*/DB_USERNAME=${DB_USER}/" .env
            sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=${DB_PASS}/" .env

            info "🔨 Installing PHP dependencies..."
            composer install --no-dev --optimize-autoloader
            php artisan key:generate --force
            php artisan migrate --seed --force

            # ------------------------------
            # Admin User
            # ------------------------------
            ADMIN_USERNAME="admin"
            ADMIN_EMAIL="admin@gmail.com"
            ADMIN_FIRST="admin"
            ADMIN_LAST="admin"
            ADMIN_PASS_FILE="/root/.ptero_admin_pass"

            if php artisan tinker <<< "App\Models\User::where('email', '${ADMIN_EMAIL}')->exists();" | grep -q 'true'; then
                ok "Admin exists, skipping."
                ADMIN_PASSWORD=$(cat $ADMIN_PASS_FILE)
            else
                ADMIN_PASSWORD="$(random_pw)"
                php artisan p:user:make \
                    --email="${ADMIN_EMAIL}" \
                    --username="${ADMIN_USERNAME}" \
                    --name-first="${ADMIN_FIRST}" \
                    --name-last="${ADMIN_LAST}" \
                    --password="${ADMIN_PASSWORD}" \
                    --admin=1 \
                    --no-interaction
                echo "$ADMIN_PASSWORD" > $ADMIN_PASS_FILE
                ok "Admin user created."
            fi

            # ------------------------------
            # SSL Setup
            # ------------------------------
            mkdir -p /etc/certs
            if [[ ! -f /etc/certs/privkey.pem ]]; then
                info "🔑 Generating self-signed SSL..."
                openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
                    -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" \
                    -keyout /etc/certs/privkey.pem -out /etc/certs/fullchain.pem
                ok "Self-signed SSL created."
            fi

            if [[ "$SETUP_SSL" =~ ^[Yy]$ ]]; then
                read -rp "🔑 Enter domain for SSL: " DOMAIN
                certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL" --redirect || warn "Certbot failed, using self-signed SSL"
                PANEL_URL="https://${DOMAIN}"
            else
                PANEL_URL="https://${SERVER_IP}"
            fi

            # ------------------------------
            # Nginx Setup
            # ------------------------------
            cat > "$PANEL_CONF" <<NGINX
server {
    listen 80;
    server_name _;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name _;

    ssl_certificate /etc/certs/fullchain.pem;
    ssl_certificate_key /etc/certs/privkey.pem;

    root /var/www/pterodactyl/public;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$script_name;
        include fastcgi_params;
    }
}
NGINX

            ln -sf "$PANEL_CONF" /etc/nginx/sites-enabled/
            nginx -t && systemctl reload nginx
            ok "Nginx configured ✅"

            # ------------------------------
            # UFW
            # ------------------------------
            if [[ "$SETUP_UFW" =~ ^[Yy]$ ]]; then
                ufw allow OpenSSH
                ufw allow http
                ufw allow https
                ufw --force enable
                ok "UFW firewall enabled ✅"
            fi

            # ------------------------------
            # Queue Worker
            # ------------------------------
            QUEUE_FILE="/etc/systemd/system/pteroq.service"
            if [[ ! -f "$QUEUE_FILE" ]]; then
                cat > "$QUEUE_FILE" <<'QUEUE'
[Unit]
Description=Pterodactyl Queue Worker
After=network.target

[Service]
User=www-data
Group=www-data
Restart=always
WorkingDirectory=/var/www/pterodactyl
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --sleep=3 --tries=3

[Install]
WantedBy=multi-user.target
QUEUE
                systemctl daemon-reload
                systemctl enable --now pteroq.service
            fi

            # ------------------------------
            # Output Credentials
            # ------------------------------
            echo
            echo -e "${PURPLE}🎉 Pterodactyl Panel Setup Complete!${RESET}"
            echo -e "🌐 Panel URL: ${GREEN}${PANEL_URL}${RESET}"
            echo -e "👤 Admin Username: ${GREEN}${ADMIN_USERNAME}${RESET}"
            echo -e "📧 Admin Email: ${GREEN}${ADMIN_EMAIL}${RESET}"
            echo -e "🔑 Admin Password: ${GREEN}${ADMIN_PASSWORD}${RESET}"
            echo -e "🗄️  Database: ${GREEN}${DB_NAME}${RESET}"
            echo -e "👤 DB User: ${GREEN}${DB_USER}${RESET}"
            echo -e "🔑 DB Password: ${GREEN}${DB_PASS}${RESET}"
            echo
            ;;

        2)
            echo -e "${YELLOW}⚠️  Wings/Daemon installer coming soon!${RESET}"
            ;;

        0)
            echo -e "${CYAN}👋 Exiting installer. Goodbye!${RESET}"
            exit 0
            ;;

        *)
            echo -e "${RED}❌ Invalid option. Please try again.${RESET}"
            ;;
    esac
done
