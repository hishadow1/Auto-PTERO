#!/bin/bash

Pterodactyl Auto Installer Script (Panel Only)

Supports Debian 11/12, Ubuntu 20.04/22.04/24.04

Modern black theme UI with interactive menu

set -e

Colors for UI

BLACK_BG='\033[40m' WHITE_TXT='\033[97m' GREEN='\033[0;32m' RED='\033[0;31m' NC='\033[0m'

UI Header

echo -e "${BLACK_BG}${WHITE_TXT}============================================${NC}" echo -e "${BLACK_BG}${WHITE_TXT}   Pterodactyl Panel Auto Installer Script   ${NC}" echo -e "${BLACK_BG}${WHITE_TXT}============================================${NC}\n"

Menu

echo -e "${GREEN}What would you like to install?${NC}" echo "1) Pterodactyl Panel" echo "2) Exit" read -rp "Enter choice [1-2]: " choice

if [ "$choice" != "1" ]; then echo -e "${RED}Exiting...${NC}" exit 1 fi

Pre-script SSL cert

echo -e "${GREEN}Generating generic SSL certificate...${NC}" mkdir -p /etc/certs cd /etc/certs if [ ! -f privkey.pem ]; then openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 
-subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" 
-keyout privkey.pem -out fullchain.pem fi cd

Detect OS

. /etc/os-release OS=$ID VERSION_ID=$VERSION_ID

Update system

echo -e "${GREEN}Updating system...${NC}" apt update -y && apt upgrade -y

Install dependencies

echo -e "${GREEN}Installing dependencies...${NC}" apt install -y curl software-properties-common apt-transport-https ca-certificates gnupg lsb-release unzip mariadb-server redis-server ufw certbot python3-certbot-nginx git

Disable UFW

echo -e "${GREEN}Disabling UFW...${NC}" ufw disable || true

Install PHP

LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php apt update -y apt install -y php8.1 php8.1-cli php8.1-gd php8.1-mysql php8.1-pdo php8.1-mbstring php8.1-bcmath php8.1-xml php8.1-curl php8.1-zip composer

Setup database

echo -e "${GREEN}Setting up MariaDB...${NC}" DB_NAME="panel" DB_USER="pterodactyl" DB_PASS=$(openssl rand -base64 16)

mysql -u root <<MYSQL CREATE DATABASE ${DB_NAME}; CREATE USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}'; GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1' WITH GRANT OPTION; FLUSH PRIVILEGES; MYSQL

Setup panel directory

mkdir -p /var/www/pterodactyl cd /var/www/pterodactyl curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz tar -xzvf panel.tar.gz chmod -R 755 storage/* bootstrap/cache/

Install dependencies

composer install --no-dev --optimize-autoloader

Generate env file

cp .env.example .env php artisan key:generate --force

Ask for FQDN

read -rp "Enter your FQDN (panel domain): " FQDN

Configure .env

sed -i "s|APP_URL=.|APP_URL=https://${FQDN}|" .env sed -i "s|DB_DATABASE=.|DB_DATABASE=${DB_NAME}|" .env sed -i "s|DB_USERNAME=.|DB_USERNAME=${DB_USER}|" .env sed -i "s|DB_PASSWORD=.|DB_PASSWORD=${DB_PASS}|" .env

Run migrations

php artisan migrate --seed --force

Create admin user

ADMIN_PASS=$(openssl rand -base64 12) echo -e "${GREEN}Creating admin user...${NC}" php artisan p:user:make 
--email=admin@gmail.com 
--username=admin 
--name-first=admin 
--name-last=admin 
--password="${ADMIN_PASS}" 
--admin=1

Setup nginx

apt install -y nginx cat > /etc/nginx/sites-available/pterodactyl.conf <<EOL server { listen 80; server_name ${FQDN};

root /var/www/pterodactyl/public;
index index.php;

location / {
    try_files \$uri \$uri/ /index.php?\$query_string;
}

location ~ \.php\$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    include fastcgi_params;
}

location ~ /\.(?!well-known).* {
    deny all;
}

} EOL

ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/ nginx -t && systemctl restart nginx

Setup SSL

SERVER_IP=$(curl -s ifconfig.me) DOMAIN_IP=$(dig +short ${FQDN} | tail -n1)

if [ "$SERVER_IP" == "$DOMAIN_IP" ]; then echo -e "${GREEN}Setting up Let's Encrypt SSL...${NC}" certbot --nginx -d ${FQDN} --non-interactive --agree-tos -m admin@gmail.com || true else echo -e "${RED}Domain does not resolve to server IP, using self-signed cert.${NC}" fi

Restart services

systemctl restart nginx php8.1-fpm redis-server mariadb

Save credentials

CRED_FILE="/root/pterodactyl_credentials.txt" cat > $CRED_FILE <<EOF Pterodactyl Panel Installation Complete

URL: https://${FQDN}

Admin User Details:

Username: admin First Name: admin Last Name: admin Email: admin@gmail.com Password: ${ADMIN_PASS}

Database Credentials:

DB Name: ${DB_NAME} DB User: ${DB_USER} DB Pass: ${DB_PASS} EOF chmod 600 $CRED_FILE

Final Output

echo -e "\n${GREEN}==========================================${NC}" echo -e "${GREEN} Pterodactyl Panel Installed Successfully ${NC}" echo -e "${GREEN}==========================================${NC}" echo -e "Panel URL: https://${FQDN}" echo -e "Admin Email: admin@gmail.com" echo -e "Admin Username: admin" echo -e "Admin First Name: admin" echo -e "Admin Last Name: admin" echo -e "Admin Password: ${ADMIN_PASS}" echo -e "DB Name: ${DB_NAME}" echo -e "DB User: ${DB_USER}" echo -e "DB Pass: ${DB_PASS}" echo -e "Credentials saved to: ${CRED_FILE}"

