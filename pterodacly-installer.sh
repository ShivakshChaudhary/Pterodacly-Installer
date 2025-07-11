#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Pterodactyl Panel Automated Installer                                              #
#                                                                                    #
# This script automates the installation of Pterodactyl Panel with your specified     #
# configurations. Only the FQDN will be prompted, all other settings use defaults.    #
#                                                                                    #
######################################################################################

# ------------------ Initial Setup ----------------- #

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Load libraries
fn_exists() { declare -F "$1" >/dev/null; }
if ! fn_exists lib_loaded; then
    source /tmp/lib.sh || source <(curl -sSL https://raw.githubusercontent.com/pterodactyl-installer/pterodactyl-installer/master/lib/lib.sh)
    ! fn_exists lib_loaded && echo "* ERROR: Could not load lib script" && exit 1
fi

# ------------------ Configuration ----------------- #

# Domain configuration
echo -n "* Enter your FQDN or IP (e.g., panel.example.com): "
read -r FQDN
FQDN="${FQDN:-panel.example.com}"
LOCAL_IP=$(hostname -I | awk '{print $1}')

# Database configuration
MYSQL_DB="panel"
MYSQL_USER="pterodactyl"
MYSQL_PASSWORD="$(gen_passwd 64)"

# Panel configuration
timezone="UTC"
ASSUME_SSL="true"          # Configure for SSL without valid certificate
CONFIGURE_LETSENCRYPT="false"  # Disable Let's Encrypt
CONFIGURE_FIREWALL="false"     # Disable UFW firewall

# Admin user configuration
user_email="admin@${FQDN#www.}"
user_username="admin"
user_firstname="Admin"
user_lastname="User"
user_password="$(gen_passwd 16)"

# ----------------- Installation Functions ---------------- #

install_dependencies() {
    output "Installing dependencies..."
    
    case "$OS" in
        ubuntu|debian)
            # Ubuntu/Debian specific dependencies
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y software-properties-common
            add-apt-repository -y ppa:ondrej/php
            apt-get update
            apt-get install -y php8.3 php8.3-{cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip}
            apt-get install -y mariadb-server nginx tar unzip git redis-server
            ;;
        rocky|almalinux)
            # Rocky/AlmaLinux specific dependencies
            dnf install -y epel-release
            dnf install -y https://rpms.remirepo.net/enterprise/remi-release-${OS_VERSION}.rpm
            dnf module enable -y php:remi-8.3
            dnf install -y php php-{common,fpm,cli,gd,mysqlnd,mbstring,bcmath,xml,curl,zip}
            dnf install -y mariadb-server nginx tar unzip git redis
            ;;
        *)
            error "Unsupported OS"
            exit 1
            ;;
    esac

    # Start and enable services
    systemctl enable --now mariadb
    systemctl enable --now redis
    systemctl enable --now nginx
    systemctl enable --now php8.3-fpm || systemctl enable --now php-fpm

    success "Dependencies installed!"
}

setup_mysql() {
    output "Configuring MySQL..."
    
    # Secure MySQL installation
    mysql_secure_installation <<EOF
y
y
$MYSQL_PASSWORD
$MYSQL_PASSWORD
y
y
y
y
EOF

    # Create database and user
    mysql -e "CREATE DATABASE ${MYSQL_DB};"
    mysql -e "CREATE USER '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_PASSWORD}';"
    mysql -e "GRANT ALL PRIVILEGES ON ${MYSQL_DB}.* TO '${MYSQL_USER}'@'127.0.0.1' WITH GRANT OPTION;"
    mysql -e "FLUSH PRIVILEGES;"

    success "MySQL configured!"
}

install_panel() {
    output "Installing Pterodactyl Panel..."
    
    # Download and extract panel
    mkdir -p /var/www/pterodactyl
    curl -L https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz | tar -xzv -C /var/www/pterodactyl
    chmod -R 755 /var/www/pterodactyl/storage/* /var/www/pterodactyl/bootstrap/cache/

    # Install composer
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
    cd /var/www/pterodactyl && composer install --no-dev --optimize-autoloader

    # Setup environment
    cp .env.example .env
    php artisan key:generate --force

    # Configure panel
    php artisan p:environment:setup \
        --author="$user_email" \
        --url="https://${FQDN}" \
        --timezone="$timezone" \
        --cache=redis \
        --session=redis \
        --queue=redis \
        --redis-host=localhost \
        --redis-port=6379

    php artisan p:environment:database \
        --host=127.0.0.1 \
        --port=3306 \
        --database="$MYSQL_DB" \
        --username="$MYSQL_USER" \
        --password="$MYSQL_PASSWORD"

    # Run migrations and create user
    php artisan migrate --seed --force
    php artisan p:user:make \
        --email="$user_email" \
        --username="$user_username" \
        --name-first="$user_firstname" \
        --name-last="$user_lastname" \
        --password="$user_password" \
        --admin=1

    # Set permissions
    chown -R www-data:www-data /var/www/pterodactyl/* || chown -R nginx:nginx /var/www/pterodactyl/*

    success "Panel installed!"
}

configure_nginx() {
    output "Configuring Nginx..."
    
    # Create nginx configuration
    cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    # Replace the example <domain> with your domain name or IP address
    listen 80;
    server_name ${LOCAL_IP};
    return 301 https://$server_name$request_uri;
}

server {
    # Replace the example <domain> with your domain name or IP address
    listen 443 ssl http2;
    server_name ${LOCAL_IP};

    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    # allow larger file uploads and longer script runtimes
    client_max_body_size 100m;
    client_body_timeout 120s;

    sendfile off;

    # SSL Configuration - Replace the example <domain> with your domain
    ssl_certificate /etc/certs/fullchain.pem;
    ssl_certificate_key /etc/certs/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    # See https://hstspreload.org/ before uncommenting the line below.
    # add_header Strict-Transport-Security "max-age=15768000; preload;";
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

    # Generate self-signed SSL certificates  
    mkdir -p /etc/certs
    cd /etc/certs
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj "/C=NA/ST=NA/L=NA/O=NA/CN=Generic SSL Certificate" -keyout privkey.pem -out fullchain.pem

    # Enable site
    ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    systemctl restart nginx

    success "Nginx configured!"
}

setup_cron() {
    output "Setting up cron job..."
    
    (crontab -l ; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -
    
    success "Cron job set up!"
}

setup_services() {
    output "Configuring services..."
    
    # Create pteroq service
    cat > /etc/systemd/system/pteroq.service <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable --now pteroq.service
    success "Services configured!"
}

# ----------------- Main Installation ---------------- #

main() {
    # Verify FQDN was provided
    if [ -z "$FQDN" ]; then
        error "FQDN cannot be empty"
        exit 1
    fi

    # Start installation
    install_dependencies
    setup_mysql
    install_panel
    configure_nginx
    setup_cron
    setup_services

    # Display installation summary
    echo ""
    success "Pterodactyl Panel has been successfully installed!"
    echo "===================================================="
    echo " Panel URL: https://${FQDN}"
    echo " Admin Email: ${user_email}"
    echo " Admin Password: ${user_password}"
    echo ""
    echo " Database Name: ${MYSQL_DB}"
    echo " Database User: ${MYSQL_USER}"
    echo " Database Password: ${MYSQL_PASSWORD}"
    echo "===================================================="
    warning "Note: The panel is using self-signed SSL certificates."
    warning "You should replace these with proper certificates in production."
}

# Execute main function
main
