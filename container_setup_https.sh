#!/bin/bash

# Docker Container Installer for Raspberry Pi OS
# Improved Version

# Variables
BACKTITLE="Docker Container Installer - Raspberry Pi OS"
VERSION="1.0.0"
USERNAME=$(logname 2>/dev/null || echo "$SUDO_USER" || echo "$USER")
ARCH=$(uname -m)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LOG_FILE="/tmp/docker-installer.log"
CONFIG_DIR="/home/$USERNAME/.docker-installer"
COMPOSE_DIR="$CONFIG_DIR/compose-files"

# Create necessary directories
mkdir -p "$CONFIG_DIR" "$COMPOSE_DIR"
chown -R "$USERNAME:$USERNAME" "$CONFIG_DIR" 2>/dev/null || true

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Check for sudo/root privileges
check_privileges() {
    if [ "$EUID" -ne 0 ]; then
        if ! command -v sudo &>/dev/null; then
            log "ERROR" "This script requires sudo but it's not installed."
            whiptail --title "Error" --msgbox "This script requires sudo privileges. Please install sudo or run as root." 10 60
            exit 1
        fi
        log "INFO" "Re-running with sudo privileges..."
        exec sudo bash "$0" "$@"
    fi
}

# Check dependencies
check_dependencies() {
    log "INFO" "Checking dependencies..."
    
    local DEPS=("whiptail" "curl" "grep" "awk" "openssl")
    local MISSING=()
    
    for dep in "${DEPS[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            MISSING+=("$dep")
        fi
    done
    
    if [ ${#MISSING[@]} -gt 0 ]; then
        log "INFO" "Installing missing dependencies: ${MISSING[*]}"
        apt update -qq
        apt install -y "${MISSING[@]}"
    fi
}

# Check if Docker is installed
is_docker_installed() {
    if command -v docker &>/dev/null && docker --version &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Check if Docker Compose is installed
is_compose_installed() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to install Docker and Docker Compose
install_docker() {
    if is_docker_installed && is_compose_installed; then
        local docker_version=$(docker --version | cut -d ' ' -f3 | tr -d ',')
        local compose_version=$(docker compose version --short)
        whiptail --title "Docker Check" --msgbox "? Docker ($docker_version) and Docker Compose ($compose_version) are already installed." 10 60
        return 0
    fi
    
    whiptail --title "Docker Installer" --yesno "Docker & Docker Compose will now be installed. This may take a few minutes.\n\nDo you want to continue?" 10 60
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Create a progress gauge
    {
        echo 0
        log "INFO" "Updating package lists..."
        apt-get update -qq
        echo 10
        
        log "INFO" "Installing prerequisites..."
        apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https software-properties-common
        echo 20

        # Let's try the simpler approach first - using the convenience script
        log "INFO" "Installing Docker using convenience script..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        echo 60
        
        log "INFO" "Enabling Docker service..."
        systemctl enable docker
        systemctl start docker
        echo 70
        
        log "INFO" "Adding user to Docker group..."
        usermod -aG docker "$USERNAME"
        echo 80
        
        # Install Docker Compose
        log "INFO" "Installing Docker Compose..."
        if ! apt-get install -y docker-compose-plugin; then
            log "WARNING" "Failed to install docker-compose-plugin, installing docker-compose directly"
            apt-get install -y docker-compose
        fi
        echo 90
        
        # If still not installed, try pip as a fallback
        if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
            log "WARNING" "Trying alternative Docker Compose installation method"
            apt-get install -y python3-pip
            pip3 install docker-compose
            apt install -y docker-compose
        fi
        echo 100
        
    } | whiptail --gauge "Installing Docker and Docker Compose..." 10 70 0
    
    if is_docker_installed && is_compose_installed; then
        whiptail --title "Success!" --msgbox "? Docker and Docker Compose installed successfully!\n\nPlease reboot or re-login to apply group changes." 12 60
        return 0
    else
        whiptail --title "Error" --msgbox "? There was a problem installing Docker. Please check the log file at $LOG_FILE" 10 60
        return 1
    fi
}

# Check if a container is running
is_container_running() {
    local container_name="$1"
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^$container_name$"
    return $?
}

# Check if a container exists (running or stopped)
container_exists() {
    local container_name="$1"
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^$container_name$"
    return $?
}

# Generate a random password
generate_password() {
    local length=${1:-16}
    < /dev/urandom tr -dc 'A-Za-z0-9!#$%&()*+,-./:;<=>?@[\]^_`{|}~' | head -c "$length"
}

# Function to create and configure container compose files
create_compose_file() {
    local container="$1"
    local compose_file="$COMPOSE_DIR/$container.yaml"
    
    case $container in
        portainer)
            cat > "$compose_file" << 'EOF'
version: '3.8'
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - portainer_data:/data
    ports:
      - 9000:9000
    environment:
      - TZ=Etc/UTC

volumes:
  portainer_data:
EOF
            ;;
            
        watchtower)
            cat > "$compose_file" << 'EOF'
version: '3.8'
services:
  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - TZ=Etc/UTC
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_SCHEDULE=0 0 4 * * *
      - WATCHTOWER_NOTIFICATION_REPORT=true
EOF
            ;;
            
        pihole)
            # Generate random password
            local password=$(generate_password 12)
            # Save password to a file
            echo "$password" > "$CONFIG_DIR/pihole_password.txt"
            chown "$USERNAME:$USERNAME" "$CONFIG_DIR/pihole_password.txt" 2>/dev/null || true
            chmod 600 "$CONFIG_DIR/pihole_password.txt"
            
            cat > "$compose_file" << EOF
version: "3.8"

services:
  pihole:
    container_name: pihole
    image: pihole/pihole:latest
    restart: unless-stopped
    environment:
      TZ: "Europe/Istanbul"
      WEBPASSWORD: "change_me_muck"
    volumes:
      - pihole_etc:/etc/pihole/
      - pihole_dnsmasq:/etc/dnsmasq.d/
    dns:
      - 127.0.0.1
      - 1.1.1.1
    ports:
      - "8080:80"        # Pi-hole Web UI
      - "8053:53/tcp"    # DNS over TCP
      - "8053:53/udp"    # DNS over UDP
    cap_add:
      - NET_ADMIN
    networks:
      - pihole_net

volumes:
  pihole_etc:
  pihole_dnsmasq:

networks:
  pihole_net:
EOF
            ;;
            
        vaultwarden)
            cat > "$compose_file" << 'EOF'
version: '3.8'
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    volumes:
      - vaultwarden_data:/data
    ports:
      - "8100:80"
    environment:
      - TZ=Etc/UTC

volumes:
  vaultwarden_data:
EOF
            ;;
            
        passbolt)
            # Create directory for SSL certificates
            local ssl_dir="$COMPOSE_DIR/passbolt-ssl"
            mkdir -p "$ssl_dir"
            
            # Generate SSL certificates
            log "INFO" "Generating SSL certificates for Passbolt..."
            
            # Get server IP
            local server_ip=$(hostname -I | awk '{print $1}')
            
            # Generate certificates
            sudo openssl genrsa -out "$ssl_dir/certificate.key" 2048
            sudo openssl req -new -x509 -key "$ssl_dir/certificate.key" -out "$ssl_dir/certificate.crt" -days 365 -subj "/CN=$server_ip" # add your server ip here if not work
            sudo chmod 644 "$ssl_dir/certificate.crt"
            sudo chmod 600 "$ssl_dir/certificate.key"
            
            # Generate random passwords
            local root_password=$(generate_password 16)
            local db_password=$(generate_password 16)
            
            # Save credentials to a file
            echo "Passbolt Database Root Password: $root_password" > "$CONFIG_DIR/passbolt_credentials.txt"
            echo "Passbolt Database User Password: $db_password" >> "$CONFIG_DIR/passbolt_credentials.txt"
            sudo chown "$USERNAME:$USERNAME" "$CONFIG_DIR/passbolt_credentials.txt" 2>/dev/null || true
            sudo chmod 600 "$CONFIG_DIR/passbolt_credentials.txt"
            
            # Create Docker Compose file
            cat > "$compose_file" << EOF
version: '3.7'

services:
  db:
    image: mariadb:10.5
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: rootpassword
      MYSQL_DATABASE: passbolt
      MYSQL_USER: passbolt
      MYSQL_PASSWORD: passboltpassword
    volumes:
      - database_data:/var/lib/mysql
    networks:
      - passbolt_network
    command: --default-authentication-plugin=mysql_native_password
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p$${MYSQL_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 5

  passbolt:
    image: passbolt/passbolt:latest-ce
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      # Replace with your actual Raspberry Pi's IP address
      APP_FULL_BASE_URL: https://192.168.0.102:443
      DATASOURCES_DEFAULT_HOST: db
      DATASOURCES_DEFAULT_USERNAME: passbolt
      DATASOURCES_DEFAULT_PASSWORD: passboltpassword
      DATASOURCES_DEFAULT_DATABASE: passbolt
      
      # Email settings
      EMAIL_TRANSPORT_DEFAULT_HOST: ${EMAIL_HOST:-localhost}
      EMAIL_TRANSPORT_DEFAULT_PORT: ${EMAIL_PORT:-25}
      EMAIL_TRANSPORT_DEFAULT_FROM: ${EMAIL_FROM:-no-reply@passbolt.local}
      EMAIL_TRANSPORT_DEFAULT_USERNAME: ${EMAIL_USERNAME:-}
      EMAIL_TRANSPORT_DEFAULT_PASSWORD: ${EMAIL_PASSWORD:-}
      EMAIL_TRANSPORT_DEFAULT_TLS: ${EMAIL_TLS:-false}
      
      # HTTPS Configuration
      PASSBOLT_SSL_FORCE: "true"
      PASSBOLT_SSL_KEY_PATH: "/etc/ssl/certs/passbolt/certificate.key"
      PASSBOLT_SSL_CERT_PATH: "/etc/ssl/certs/passbolt/certificate.crt"
      PASSBOLT_SSL_SELF_SIGNED: "true"
    volumes:
      - gpg_keys:/etc/passbolt/gpg
      - jwt_keys:/etc/passbolt/jwt
      - ./ssl:/etc/ssl/certs/passbolt
    ports:
      - "443:443"
      - "80:80"  # Also expose HTTP port for initial redirects
    networks:
      - passbolt_network
    extra_hosts:
      - "host.docker.internal:host-gateway"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/healthcheck/status.json"]
      interval: 10s
      timeout: 5s
      retries: 3

networks:
  passbolt_network:

volumes:
  database_data:
  gpg_keys:
  jwt_keys:
EOF
        
            # Create user registration script
            local register_script="$COMPOSE_DIR/register_passbolt_admin.sh"
            cat > "$register_script" << 'EOF'
#!/bin/bash

# Get the script directory
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# Set admin email (you can change this)
ADMIN_EMAIL="admin@example.com"
ADMIN_FIRST_NAME="Admin"
ADMIN_LAST_NAME="User"

echo "Registering admin user for Passbolt..."
echo "Email: $ADMIN_EMAIL"
echo "Name: $ADMIN_FIRST_NAME $ADMIN_LAST_NAME"

# Execute the registration command
docker-compose -f "$SCRIPT_DIR/passbolt.yaml" exec passbolt \
  su -m -c "/usr/share/php/passbolt/bin/cake passbolt register_user -u $ADMIN_EMAIL -f $ADMIN_FIRST_NAME -l $ADMIN_LAST_NAME -r admin" \
  -s /bin/sh www-data

echo "Done! Check the output above for registration information."
EOF
            chmod +x "$register_script"
            chown "$USERNAME:$USERNAME" "$register_script" 2>/dev/null || true
            ;;
            
        pialert)
            cat > "$compose_file" << 'EOF'
version: '3.8'
services:
  pialert:
    image: jokobsk/pi.alert:latest
    container_name: pialert
    restart: unless-stopped
    network_mode: host
    volumes:
      - pialert_data:/home/pi/pialert/config
      - pialert_db:/home/pi/pialert/db
    environment:
      - TZ=Etc/UTC
      - PIALERT_WEB_PROTECTION=true

volumes:
  pialert_data:
  pialert_db:
EOF
            ;;
            
        unbound)
            cat > "$compose_file" << 'EOF'
version: '3.8'
services:
  unbound:
    image: mvance/unbound:latest
    container_name: unbound
    restart: unless-stopped
    ports:
      - "5335:53/tcp"
      - "5335:53/udp"
    volumes:
      - unbound_data:/opt/unbound/etc/unbound

volumes:
  unbound_data:
EOF
            ;;
            
        grafana)
            cat > "$compose_file" << 'EOF'
version: '3.8'
services:
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    ports:
      - "3000:3000"
    volumes:
      - grafana_data:/var/lib/grafana
    environment:
      - GF_SECURITY_ALLOW_EMBEDDING=true
      - GF_AUTH_ANONYMOUS_ENABLED=false
      - TZ=Etc/UTC

volumes:
  grafana_data:
EOF
            ;;
            
        prometheus)
            # Create prometheus config directory
            mkdir -p "$COMPOSE_DIR/prometheus"
            
            # Create basic prometheus.yml configuration
            cat > "$COMPOSE_DIR/prometheus/prometheus.yml" << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
EOF

            cat > "$compose_file" << 'EOF'
version: '3.8'
services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
    environment:
      - TZ=Etc/UTC

volumes:
  prometheus_data:
EOF
            ;;
            
        hedgedoc)
            # Generate random password for database
            local password=$(generate_password 16)
            # Generate random session secret
            local session_secret=$(generate_password 24)
            # Get the server IP address
            local server_ip=$(hostname -I | awk '{print $1}')
            
            cat > "$compose_file" << EOF
version: '3.8'

services:
  database:
    image: postgres:14-alpine
    container_name: hedgedoc_postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: hedgedoc
      POSTGRES_USER: hedgedoc
      POSTGRES_PASSWORD: supersecret
    volumes:
      - postgres_data:/var/lib/postgresql/data

  hedgedoc:
    image: quay.io/hedgedoc/hedgedoc:latest
    container_name: hedgedoc_app
    restart: unless-stopped
    depends_on:
      - database
    ports:
      - "3001:3000"
    environment:
      CMD_DOMAIN: "192.168.0.102:3001"
      CMD_URL_ADDPORT: "false"
      CMD_PROTOCOL_USESSL: "false"
      CMD_DB_URL: postgres://hedgedoc:supersecret@database:5432/hedgedoc
      CMD_ALLOW_ANONYMOUS: "true"
      CMD_ALLOW_ANONYMOUS_EDITS: "true"
      CMD_SESSION_SECRET: "a_super_secret_session_key"
      CMD_CSP_ENABLE: "false"

volumes:
  postgres_data:

EOF
            
            # Save credentials to a file
            echo "HedgeDoc PostgreSQL Password: $password" > "$CONFIG_DIR/hedgedoc_credentials.txt"
            echo "HedgeDoc Session Secret: $session_secret" >> "$CONFIG_DIR/hedgedoc_credentials.txt"
            chown "$USERNAME:$USERNAME" "$CONFIG_DIR/hedgedoc_credentials.txt" 2>/dev/null || true
            chmod 600 "$CONFIG_DIR/hedgedoc_credentials.txt"
            ;;
    esac
    
    # Set correct permissions
    chown "$USERNAME:$USERNAME" "$compose_file" 2>/dev/null || true
}

# Function to install and configure a container
setup_container() {
    local container="$1"
    local compose_file="$COMPOSE_DIR/$container.yaml"
    
    # Check if container is already running
    if is_container_running "$container"; then
        whiptail --title "Container Active" --msgbox "✅ $container is already running." 10 60
        return 0
    fi
    
    # Create compose file if it doesn't exist
    if [ ! -f "$compose_file" ]; then
        create_compose_file "$container"
    fi
    
    # Check if the compose file was created
    if [ ! -f "$compose_file" ]; then
        whiptail --title "Error" --msgbox "❌ Failed to create compose file for $container" 10 60
        return 1
    fi
    
    # Launch container
    log "INFO" "Starting $container container..."
    
    if cd "$COMPOSE_DIR" && docker compose -f "$container.yaml" up -d; then
        local status_message="✅ $container started successfully!"
        
        # Add container-specific information
        case $container in
            portainer)
                status_message+="\n\nAccess at: http://$(hostname -I | awk '{print $1}'):9000"
                ;;
            pihole)
                local password=$(cat "$CONFIG_DIR/pihole_password.txt" 2>/dev/null || echo "Check log file")
                status_message+="\n\nAccess at: http://$(hostname -I | awk '{print $1}')/admin\nPassword: $password"
                ;;
            vaultwarden)
                status_message+="\n\nAccess at: http://$(hostname -I | awk '{print $1}'):8100"
                ;;
            passbolt)
                status_message+="\n\nAccess at: https://$(hostname -I | awk '{print $1}')"
                status_message+="\n\nCredentials saved to: $CONFIG_DIR/passbolt_credentials.txt"
                
                # Ask if user wants to register admin now
                whiptail --title "Passbolt Admin Setup" --yesno "Do you want to register an admin user for Passbolt now?\n\nNote: Wait about 30 seconds for Passbolt to fully initialize before proceeding." 12 60
                if [ $? -eq 0 ]; then
                    log "INFO" "Running Passbolt admin registration..."
                    bash "$COMPOSE_DIR/register_passbolt_admin.sh"
                    status_message+="\n\nAdmin user registration has been initiated."
                    status_message+="\n\nDefault admin: admin@example.com"
                    status_message+="\nCheck your email for registration instructions."
                else
                    status_message+="\n\nYou can register an admin later with this command:"
                    status_message+="\nbash $COMPOSE_DIR/register_passbolt_admin.sh"
                fi
                ;;
            pialert)
                status_message+="\n\nAccess at: http://$(hostname -I | awk '{print $1}')"
                ;;
            grafana)
                status_message+="\n\nAccess at: http://$(hostname -I | awk '{print $1}'):3000\nDefault login: admin/admin"
                ;;
            prometheus)
                status_message+="\n\nAccess at: http://$(hostname -I | awk '{print $1}'):9090"
                ;;
            hedgedoc)
                status_message+="\n\nAccess at: http://$(hostname -I | awk '{print $1}'):3000"
                status_message+="\n\nCredentials saved to: $CONFIG_DIR/hedgedoc_credentials.txt"
                ;;
        esac
        
        whiptail --title "Container Started" --msgbox "$status_message" 15 60
        return 0
    else
        whiptail --title "Error" --msgbox "❌ Failed to start $container. Please check the log file at $LOG_FILE" 10 60
        return 1
    fi
}

# Function to select and install containers
select_containers() {
    if ! is_docker_installed || ! is_compose_installed; then
        whiptail --title "Docker Required" --msgbox "Docker and Docker Compose must be installed first." 10 60
        return 1
    fi

    local container_options=(
        "portainer"   "Portainer - Docker Web UI" OFF
        "watchtower"  "Watchtower - Auto-update containers" OFF
        "pialert"     "Pi.Alert - Detect unknown devices" OFF
        "pihole"      "Pi-hole - Network ad blocker" OFF
        "vaultwarden" "Vaultwarden - Bitwarden server" OFF
        "passbolt"    "Passbolt - Open source password manager" OFF
        "unbound"     "Unbound - DNS resolver" OFF
        "grafana"     "Grafana - Dashboards & Visualization" OFF
        "prometheus"  "Prometheus - Monitoring & Alerts" OFF
        "hedgedoc"    "HedgeDoc - Collaborative Markdown editor" OFF
    )
    
    # Check which containers are already running and mark them
    for i in {0..18..2}; do
        if [ $i -lt ${#container_options[@]} ]; then
            if is_container_running "${container_options[$i]}"; then
                container_options[$((i+2))]=ON
            fi
        fi
    done

    local SELECTED=$(whiptail --title "Container Setup" \
    --backtitle "$BACKTITLE" \
    --checklist "Select containers to install and run:" 20 70 12 \
    "${container_options[@]}" \
    3>&1 1>&2 2>&3)
    
    # User pressed Cancel
    if [ $? -ne 0 ]; then
        return 0
    fi
    
    # Process selected containers
    for container in $SELECTED; do
        # Remove quotes
        container=$(echo "$container" | tr -d '"')
        setup_container "$container"
    done
    
    whiptail --title "Installation Complete" --msgbox "🎉 Container setup completed!" 10 60
}

# Function to manage existing containers
manage_containers() {
    if ! is_docker_installed; then
        whiptail --title "Docker Required" --msgbox "Docker must be installed first." 10 60
        return 1
    fi
    
    # Check if any containers exist
    local container_count=$(docker ps -a --format '{{.Names}}' 2>/dev/null | wc -l)
    
    if [ "$container_count" -eq 0 ]; then
        whiptail --title "No Containers" --msgbox "No containers found. Please install some containers first." 10 60
        return 0
    fi
    
    # Build the container list
    local containers=$(docker ps -a --format '{{.Names}}|{{.Status}}|{{.Image}}')
    local container_options=()
    
    while IFS='|' read -r name status image; do
        if [[ "$status" == *"Up"* ]]; then
            status="🟢 Running"
        else
            status="🔴 Stopped"
        fi
        container_options+=("$name" "$status - $image" OFF)
    done <<< "$containers"
    
    local SELECTED=$(whiptail --title "Container Management" \
    --backtitle "$BACKTITLE" \
    --checklist "Select containers to manage:" 20 76 12 \
    "${container_options[@]}" \
    3>&1 1>&2 2>&3)
    
    # User pressed Cancel
    if [ $? -ne 0 ]; then
        return 0
    fi
    
    # Remove quotes
    SELECTED=$(echo "$SELECTED" | tr -d '"')
    
    if [ -z "$SELECTED" ]; then
        return 0
    fi
    
    # Show action menu for selected containers
    local ACTION=$(whiptail --title "Container Actions" \
    --backtitle "$BACKTITLE" \
    --menu "Choose an action for selected containers:" 15 60 6 \
    "1" "Start containers" \
    "2" "Stop containers" \
    "3" "Restart containers" \
    "4" "Remove containers" \
    "5" "View logs" \
    3>&1 1>&2 2>&3)
    
    # User pressed Cancel
    if [ $? -ne 0 ]; then
        return 0
    fi
    
    case $ACTION in
        1) # Start
            for container in $SELECTED; do
                log "INFO" "Starting container: $container"
                docker start "$container"
            done
            whiptail --title "Success" --msgbox "✅ Selected containers started." 10 60
            ;;
        2) # Stop
            for container in $SELECTED; do
                log "INFO" "Stopping container: $container"
                docker stop "$container"
            done
            whiptail --title "Success" --msgbox "✅ Selected containers stopped." 10 60
            ;;
        3) # Restart
            for container in $SELECTED; do
                log "INFO" "Restarting container: $container"
                docker restart "$container"
            done
            whiptail --title "Success" --msgbox "✅ Selected containers restarted." 10 60
            ;;
        4) # Remove
            whiptail --title "Confirm Removal" --yesno "⚠️ Are you sure you want to remove the selected containers?\nThis will delete all container data unless stored in persistent volumes." 10 60
            if [ $? -eq 0 ]; then
                for container in $SELECTED; do
                    log "INFO" "Removing container: $container"
                    docker stop "$container" 2>/dev/null
                    docker rm "$container"
                done
                whiptail --title "Success" --msgbox "✅ Selected containers removed." 10 60
            fi
            ;;
        5) # View logs
            if [ $(echo "$SELECTED" | wc -w) -eq 1 ]; then
                # Only one container selected, show logs
                local loglines=$(whiptail --inputbox "Enter number of log lines to show:" 10 60 "100" 3>&1 1>&2 2>&3)
                if [ $? -eq 0 ]; then
                    docker logs --tail "$loglines" "$SELECTED" | less
                fi
            else
                whiptail --title "Error" --msgbox "❌ Please select only one container for viewing logs." 10 60
            fi
            ;;
    esac
}

# Function to show system information
show_system_info() {
    local info=""
    
    # Raspberry Pi model
    if [ -f /proc/device-tree/model ]; then
        local model=$(cat /proc/device-tree/model)
        info+="Model: $model\n"
    fi
    
    # OS info
    if [ -f /etc/os-release ]; then
        local os_name=$(source /etc/os-release && echo "$PRETTY_NAME")
        info+="OS: $os_name\n"
    fi
    
    # Kernel
    local kernel=$(uname -srm)
    info+="Kernel: $kernel\n"
    
    # CPU info
    local cpu_info=$(grep "model name" /proc/cpuinfo | head -1 | cut -d':' -f2 | sed 's/^ *//')
    [ -z "$cpu_info" ] && cpu_info=$(grep "Processor" /proc/cpuinfo | head -1 | cut -d':' -f2 | sed 's/^ *//')
    info+="CPU: $cpu_info\n"
    
    # CPU cores
    local cpu_cores=$(grep -c processor /proc/cpuinfo)
    info+="CPU Cores: $cpu_cores\n"
    
    # Memory
    local mem_total=$(free -h | awk '/^Mem:/ {print $2}')
    local mem_used=$(free -h | awk '/^Mem:/ {print $3}')
    info+="Memory: $mem_used / $mem_total\n"
    
    # Disk space
    local disk_info=$(df -h / | awk 'NR==2 {printf "%s / %s (Used: %s)\n", $3, $2, $5}')
    info+="Disk Space: $disk_info\n"
    
    # IP addresses
    local ip_info=$(hostname -I)
    info+="IP Addresses: $ip_info\n"
    
    # Docker info
    if command -v docker &>/dev/null; then
        local docker_version=$(docker --version | cut -d ' ' -f3 | tr -d ',')
        info+="\nDocker Version: $docker_version\n"
        
        if command -v docker &>/dev/null && docker compose version &>/dev/null; then
            local compose_version=$(docker compose version --short)
            info+="Docker Compose Version: $compose_version\n"
        fi
        
        # Count containers
        local running_containers=$(docker ps -q | wc -l)
        local total_containers=$(docker ps -a -q | wc -l)
        info+="Containers: $running_containers running, $total_containers total\n"
        
        # List volumes
        local volume_count=$(docker volume ls -q | wc -l)
        info+="Volumes: $volume_count\n"
        
        # Docker disk usage
        if type docker &>/dev/null && docker system df &>/dev/null; then
            local docker_size=$(docker system df | grep -E '^(Images|Containers|Local Volumes)' | awk '{sum+=$4} END {print sum}')
            info+="Docker Storage: ~${docker_size}GB\n"
        fi
    else
        info+="\nDocker: Not installed\n"
    fi
    
    whiptail --title "System Information" --scrolltext --msgbox "$info" 20 70
}

# Function: Display About Information
show_about() {
    local info="Docker Container Installer for Raspberry Pi OS v$VERSION\n\n"
    info+="This script simplifies the installation and management of Docker and Docker Compose on Raspberry Pi, "
    info+="along with popular containerized applications.\n\n"
    info+="Features:\n"
    info+="- One-click Docker and Docker Compose installation\n"
    info+="- Easy setup of popular containers\n"
    info+="- Container management\n"
    info+="- System information display\n\n"
    info+="Log file location: $LOG_FILE\n"
    info+="Configuration directory: $CONFIG_DIR\n"
    
    whiptail --title "About" --msgbox "$info" 20 70
}

# Main menu function
main_menu() {
    while true; do
        local docker_status="❌ Not installed"
        if is_docker_installed; then
            if is_compose_installed; then
                docker_status="✅ Installed"
            else
                docker_status="⚠️ Docker installed, Compose missing"
            fi
        fi
        
        local CHOICE=$(whiptail --title "Main Menu" \
        --backtitle "$BACKTITLE v$VERSION" \
        --menu "Welcome! Docker Status: $docker_status" 18 60 10 \
        "1" "Install Docker & Docker Compose" \
        "2" "Select & Install Containers" \
        "3" "Manage Running Containers" \
        "4" "System Information" \
        "5" "About" \
        "6" "Exit" \
        3>&1 1>&2 2>&3)
        
        # User pressed Cancel or ESC
        if [ $? -ne 0 ]; then
            echo "👋 Exiting."
            exit 0
        fi
        
        case $CHOICE in
            1)
                check_privileges
                install_docker
                ;;
            2)
                select_containers
                ;;
            3)
                manage_containers
                ;;
            4)
                show_system_info
                ;;
            5)
                show_about
                ;;
            6)
                log "INFO" "User exited script"
                echo "👋 Thank you for using Docker Container Installer!"
                exit 0
                ;;
            *)
                log "ERROR" "Invalid menu choice"
                ;;
        esac
    done
}

# Main execution
log "INFO" "Script started"
check_dependencies
main_menu
