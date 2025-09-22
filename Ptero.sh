#!/bin/bash

# Installer Script for Draco and Skyport Panels
# Author: Shadow / Fixed by ChatGPT

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo -e "${GREEN}======================================${NC}"
echo -e "${CYAN}   Auto Installer for Pterodactyl     ${NC}"
echo -e "${GREEN}======================================${NC}"

# ----------------------------
# Update System
# ----------------------------
echo -e "${CYAN}Updating system...${NC}"
apt update -y && apt upgrade -y

# ----------------------------
# Install Dependencies
# ----------------------------
echo -e "${CYAN}Installing dependencies...${NC}"
apt install -y curl unzip git software-properties-common \
redis-server mariadb-server nginx tar \
composer nodejs npm certbot python3-certbot-nginx

# ----------------------------
# Install PHP 8.2
# ----------------------------
echo -e "${CYAN}Installing PHP 8.2...${NC}"
apt remove -y php8.0* php8.1* > /dev/null 2>&1 || true
add-apt-repository -y ppa:ondrej/php
apt update -y
apt install -y php8.2 php8.2-cli php8.2-common php8.2-mysql \
php8.2-gd php8.2-mbstring php8.2-bcmath php8.2-xml php8.2-curl php8.2-zip

# ----------------------------
# Start services (no systemd)
# ----------------------------
echo -e "${CYAN}Starting services...${NC}"
service mariadb start || service mysql start
service redis-server start
service php8.2-fpm start
service nginx start

# ----------------------------
# Database setup
# ----------------------------
echo -e "${CYAN}Securing MariaDB...${NC}"
mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'password';
FLUSH PRIVILEGES;
EOF

# ----------------------------
# Install Pterodactyl Panel
# ----------------------------
echo -e "${CYAN}Installing Pterodactyl Panel...${NC}"
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl

curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/

# ----------------------------
# Composer Setup
# ----------------------------
echo -e "${CYAN}Installing Composer dependencies...${NC}"
composer install --no-dev --optimize-autoloader

# ----------------------------
# Laravel Setup
# ----------------------------
cp .env.example .env
php artisan key:generate --force

# ----------------------------
# Database Migrations
# ----------------------------
php artisan migrate --seed --force

# ----------------------------
# Nginx Config
# ----------------------------
echo -e "${CYAN}Configuring Nginx...${NC}"
cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name _;
    root /var/www/pterodactyl/public;

    index index.php index.html;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
service nginx reload

# ----------------------------
# Done
# ----------------------------
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN} Installation complete!${NC}"
echo -e "${YELLOW} Visit your server’s IP in the browser.${NC}"
echo -e "${GREEN}======================================${NC}"
