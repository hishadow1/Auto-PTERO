#!/bin/bash

# Modern Black Theme UI Color Definitions (optimized for dark terminals)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'  # No Color

# Function to print styled header
print_header() {
    clear
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║${WHITE}                        Pterodactyl Panel Installer                  ${CYAN}${BOLD}║${NC}"
    echo -e "${CYAN}${BOLD}║${WHITE}                             Black Theme UI                           ${CYAN}${BOLD}║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Function to print info message
print_info() {
    echo -e "${BLUE}${BOLD}[INFO]${NC} $1"
}

# Function to print success message
print_success() {
    echo -e "${GREEN}${BOLD}[SUCCESS]${NC} $1"
}

# Function to print warning message
print_warning() {
    echo -e "${YELLOW}${BOLD}[WARNING]${NC} $1"
}

# Function to print error message and exit if critical
print_error() {
    echo -e "${RED}${BOLD}[ERROR]${NC} $1"
    if [[ "$1" == *"Exiting"* ]]; then
        exit 1
    fi
}

# Function to generate random password (32 chars alphanumeric)
generate_password() {
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1
}

# Function to detect OS and version
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="${ID,,}"  # Lowercase
        VER="$VERSION_ID"
        CODENAME="$VERSION_CODENAME"
    elif command -v lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        VER=$(lsb_release -sr)
        CODENAME=$(lsb_release -sc)
    else
        print_error "Cannot detect OS. Supported: Ubuntu and Debian only. Exiting."
    fi

    if [[ "$OS" != "ubuntu" && "$OS" != "debian" ]]; then
        print_error "Unsupported OS: $OS. Supported: Ubuntu and Debian only. Exiting."
    fi

    print_info "Detected OS: $OS $VER ($CODENAME)"
}

# Function to update system packages
update_system() {
    print_info "Updating package lists and upgrading system..."
    apt update -y && apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    print_success "System updated successfully."
}

# Function to install OS-specific dependencies
install_dependencies() {
    print_info "Installing required dependencies..."

    # Install common tools
    apt install -y software-properties-common curl wget git unzip lsb-release gnupg2 ca-certificates apt-transport-https

    # Add PHP repository (ondrej/sury for Ubuntu, sury for Debian)
    if [[ "$OS" == "ubuntu" ]]; then
        add-apt-repository ppa:ondrej/php -y
    else  # Debian
        curl -sSL https://packages.sury.org/php/apt.gpg | apt-key add -
        echo "deb https://packages.sury.org/php/ $CODENAME main" > /etc/apt/sources.list.d/php.list
    fi
    apt update

    # Install Docker GPG key and repo
    curl -fsSL https://download.docker.com/linux/"$OS"/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$OS $CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update

    # Install core packages: Docker, MariaDB, Redis, Nginx, PHP 8.1, Composer
    apt install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
        mariadb-server \
        redis-server \
        nginx-full \
        php8.1 php8.1-cli php8.1-fpm php8.1-mysql php8.1-zip php8.1-gd php8.1-mbstring php8.1-curl php8.1-xml php8.1-bcmath php8.1-redis \
        composer

    # Start and enable services
    systemctl start docker mariadb redis-server nginx php8.1-fpm
    systemctl enable docker mariadb redis-server nginx php8.1-fpm

    # Add user to docker group
    usermod -aG docker www-data

    print_success "Dependencies installed successfully."
}

# Function to secure MariaDB
secure_mariadb() {
    print_info "Securing MariaDB installation..."
    mysql_secure_installation <<EOF

y
y
y
y
y
EOF
    print_success "MariaDB secured."
}

# Function to create Pterodactyl database and user
create_database() {
    local db_pass=$1
    print_info "Creating Pterodactyl database and user..."
    mysql -u root -e "CREATE DATABASE IF NOT EXISTS pterodactyl; CREATE USER IF NOT EXISTS 'pterodactyl'@'localhost' IDENTIFIED BY '$db_pass'; GRANT ALL PRIVILEGES ON pterodactyl.* TO 'pterodactyl'@'localhost'; FLUSH PRIVILEGES;"
    print_success "Database 'pterodactyl' created with user 'pterodactyl'."
}

# Function to create self-signed certificate (as per request, executed before main script)
create_self_signed_cert() {
    print_info "Creating self-signed SSL certificate..."
    mkdir -p /etc/certs
    cd /etc/certs
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" -keyout privkey.pem -out fullchain.pem
    cd /
    print_success "Self-signed certificate created in /etc/certs/."
}

# Function to disable UFW (as per request)
disable_ufw() {
    print_info "Disabling UFW firewall..."
    if command -v ufw >/dev/null 2>&1; then
        ufw disable
        print_success "UFW disabled."
    else
        print_warning "UFW not installed, skipping."
    fi
}

# Function to setup Let's Encrypt if FQDN is valid domain
setup_lets_encrypt() {
    local fqdn=$1
    print_info "Setting up Let's Encrypt SSL for $fqdn..."
    apt install -y certbot python3-certbot-nginx
    certbot --nginx -d "$fqdn" --non-interactive --agree-tos --email admin@gmail.com --redirect --hsts --staple-ocsp
    print_success "Let's Encrypt certificate installed and configured for $fqdn."
}

# Function to configure Nginx for self-signed cert
configure_nginx_self_signed() {
    local fqdn=$1
    print_info "Configuring Nginx with self-signed SSL for $fqdn..."
    
    # Remove default site
    rm -f /etc/nginx/sites-enabled/default
    
    # Create Pterodactyl site config
    cat > /etc/nginx/sites-available/pterodactyl <<EOF
server {
    listen 80;
    server_name $fqdn;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $fqdn;

    root /var/www/pterodactyl/public;
    index index.php index.html;

    ssl_certificate /etc/certs/fullchain.pem;
    ssl_certificate_key /etc/certs/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;

    client_max_body_size 100M;
    fastcgi_buffers 8 16k;
    fastcgi_buffer_size 32k;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

    # Enable site
    ln -sf /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/
    
    # Test and reload Nginx
    if nginx -t; then
        systemctl reload nginx
        print_success "Nginx configured with self-signed SSL."
    else
        print_error "Nginx configuration test failed. Exiting."
    fi
}

# Function to install Pterodactyl Panel
install_pterodactyl() {
    local fqdn=$1
    local use_lets_encrypt=$2

    print_info "Starting Pterodactyl Panel installation..."

    # Generate passwords
    DB_PASS=$(generate_password)
    ADMIN_PASS=$(generate_password)

    # Create database
    create_database "$DB_PASS"

    # Download and extract Pterodactyl Panel
    cd /var/www
    wget -O panel.tar.gz "https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz"
    tar -xzf panel.tar.gz
    chown -R www-data:www-data /var/www/pterodactyl/
    chmod -R 755 /var/www/pterodactyl/
    rm panel.tar.gz

    # Install Composer dependencies
    cd /var/www/pterodactyl
    composer install --no-dev --optimize-autoloader --no-interaction

    # Set permissions
    chmod -R 755 storage/ bootstrap/cache

    # Copy and configure environment
    cp .env.example .env
    php artisan key:generate --force

    # Setup environment (app URL, cache, queue, debug, DB pass)
    php artisan p:environment:setup <<EOF
$fqdn
1
1
0
$DB_PASS
EOF

    # Run migrations and seed
    php artisan migrate --seed --force

    # Create admin user
    php artisan p:user:make <<EOF
admin
admin
admin
admin@gmail.com
EOF

    # Set random password for admin (using tinker for proper hashing)
    php artisan tinker --execute="
\$user = App\\Models\\User ::where('email', 'admin@gmail.com')->first();
\$user->password = Illuminate\\Support\\Facades\\Hash::make('$ADMIN_PASS');
\$user->save();
echo 'Admin password updated.';
"

    # Final permissions
    chown -R www-data:www-data /var/www/pterodactyl/
    chmod -R 755 /var/www/pterodactyl/storage /var/www/pterodactyl/bootstrap/cache

    # Configure SSL based on choice
    if [[ "$use_lets_encrypt" == "yes" ]]; then
        setup_lets_encrypt "$fqdn"
    else
        configure_nginx_self_signed "$fqdn"
    fi

    print_success "Pterodactyl Panel installation completed!"

    # Show user details
    echo ""
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}${BOLD}Installation Summary:${NC}"
    echo -e "${WHITE}Admin Username: admin${NC}"
    echo -e "${WHITE}Admin First Name: admin${NC}"
    echo -e "${WHITE}Admin Last Name: admin${NC}"
    echo -e "${WHITE}Admin Email: admin@gmail.com${NC}"
    echo -e "${WHITE}Admin Password: $ADMIN_PASS${NC}"
    echo -e "${WHITE}Panel URL: https://$fqdn${NC}"
    echo -e "${WHITE}Database: pterodactyl (user: pterodactyl, pass: $DB_PASS)${NC}"
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    print_info "Access the panel at https://$fqdn and login with the admin credentials above."
    print_warning "For production, change the admin email and consider securing further."
}

# Function to show main menu
show_menu() {
    print_header
    echo -e "${PURPLE}${BOLD}What would you like to install?${NC}"
    echo ""
    echo "1) Pterodactyl Panel"
    echo "2) Exit"
    echo ""
    read -p "Enter your choice (1-2): " choice
}

# Main execution
main() {
    # Initial setup as per request (before main script logic)
    create_self_signed_cert
    disable_ufw

    # Detect OS and proceed
    detect_os
    update_system
    install_dependencies
    secure_mariadb

    # Show menu
    show_menu

    case "$choice" in
        1)
            echo ""
            read -p "Enter your FQDN (e.g., panel.example.com): " fqdn
            if [[ -z "$fqdn" ]]; then
                print_error "FQDN is required. Exiting."
                return
            fi

            # Detect if Let's Encrypt is needed (valid domain, not IP or localhost)
            if [[ "$fqdn" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] && [[ "$fqdn" != "localhost" ]] && ! [[ "$fqdn" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                use_lets_encrypt="yes"
                print_info "Valid domain detected. Using Let's Encrypt SSL."
            else
                use_lets_encrypt="no"
                print_warning "FQDN appears to be localhost/IP. Using self-signed SSL."
            fi

            install_pterodactyl "$fqdn" "$use_lets_encrypt"
            ;;
        2)
            print_info "Exiting installer."
            exit 0
            ;;
        *)
            print_error "Invalid choice. Exiting."
            exit 1
            ;;
    esac
}

# Run the script
main "$@"
