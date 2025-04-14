#!/bin/bash

# Function to print section headers
print_section() {
    echo ""
    echo "=== $1 ==="
    echo ""
}

# Function to print before/after comparison
print_comparison() {
    local param=$1
    local before=$2
    local after=$3
    local unit=$4
    
    printf "%-30s %-15s %-15s\n" "Parameter" "Before" "After"
    printf "%-30s %-15s %-15s\n" "$param" "$before$unit" "$after$unit"
    echo ""
}

# Function to detect OS type
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        OS_VERSION=$VERSION_ID
    elif [ -f /etc/redhat-release ]; then
        OS=$(cat /etc/redhat-release | awk '{print $1}')
        OS_VERSION=$(cat /etc/redhat-release | awk '{print $4}' | cut -d'.' -f1)
    else
        OS=$(uname -s)
        OS_VERSION=$(uname -r)
    fi
    echo "Detected OS: $OS $OS_VERSION"
}

# Function to detect MongoDB version
detect_mongodb_version() {
    if command -v mongod &> /dev/null; then
        MONGODB_VERSION_STRING=$(mongod --version | grep "db version" | awk '{print $3}')
        MONGODB_VERSION=${MONGODB_VERSION_STRING//v/}
        MONGODB_MAJOR_VERSION=$(echo $MONGODB_VERSION | cut -d'.' -f1)
        echo "Detected MongoDB version: $MONGODB_VERSION_STRING"
    else
        echo "MongoDB is not installed or not in PATH"
        exit 1
    fi
}

# Function to get MongoDB dbPath from config file
get_mongodb_dbpath() {
    local config_file="/etc/mongod.conf"
    
    if [ ! -f "$config_file" ]; then
        echo "MongoDB config file $config_file not found"
        return 1
    fi

    # Try YAML format
    if grep -q "storage:" "$config_file" && grep -q "dbPath:" "$config_file"; then
        DB_PATH=$(awk '/storage:/{flag=1} flag && /dbPath:/{print $2; exit}' "$config_file" | tr -d '"' | tr -d "'")
    # Try legacy format
    else
        DB_PATH=$(grep -E '^dbpath\s*=' "$config_file" | awk -F'=' '{print $2}' | tr -d ' ' | tr -d '"' | tr -d "'")
    fi

    if [ -z "$DB_PATH" ]; then
        DB_PATH="/var/lib/mongodb"
    fi

    DB_PATH=$(readlink -f "$DB_PATH")
    echo "Detected MongoDB dbPath: $DB_PATH"
}

# Function to get current THP status
get_current_thp_status() {
    thp_path=$1
    if [ -f "$thp_path/enabled" ]; then
        cat "$thp_path/enabled" | tr -d '[]'
    else
        echo "unknown"
    fi
}

# Function to get current readahead value
get_current_readahead() {
    local device=$1
    if [ -b "$device" ]; then
        blockdev --getra "$device"
    else
        echo "N/A"
    fi
}

# Function to set readahead value with comparison
set_readahead_for_path() {
    local target_path=$1
    local desired_readahead=32  # 32 sectors (16KB effective)
    
    local mount_point=$(df --output=target "$target_path" | tail -n1)
    local device=$(df --output=source "$target_path" | tail -n1)
    
    if [ -z "$device" ]; then
        echo "Could not determine device for path $target_path"
        return 1
    fi

    print_section "Readahead Configuration"
    echo "Target Path: $target_path"
    echo "Mount Point: $mount_point"
    echo "Device: $device"

    local current_readahead=$(get_current_readahead "$device")
    echo "Current readahead: $current_readahead sectors"
    
    blockdev --setra $desired_readahead "$device"
    local new_readahead=$(get_current_readahead "$device")
    
    print_comparison "Readahead (sectors)" "$current_readahead" "$new_readahead"
    
    # Make persistent
    if [ -f /etc/rc.local ]; then
        if ! grep -q "blockdev --setra $desired_readahead $device" /etc/rc.local; then
            sed -i "/^exit 0/i blockdev --setra $desired_readahead $device" /etc/rc.local
        fi
    else
        echo "#!/bin/sh -e" > /etc/rc.local
        echo "blockdev --setra $desired_readahead $device" >> /etc/rc.local
        echo "exit 0" >> /etc/rc.local
        chmod +x /etc/rc.local
    fi
}

# Function to get current kernel parameter
get_kernel_param() {
    local param=$1
    sysctl -n "$param" 2>/dev/null || echo "N/A"
}

# Function to set kernel parameter with comparison
set_kernel_param() {
    local param=$1
    local value=$2
    local config_file=$3
    
    print_section "Configuring $param"
    
    local current_value=$(get_kernel_param "$param")
    echo "Current $param: $current_value"
    
    # Add to config file
    if ! grep -q "^$param" "$config_file"; then
        echo "$param=$value" >> "$config_file"
        echo "Added to $config_file"
    else
        sed -i "s/^$param=.*/$param=$value/" "$config_file"
        echo "Updated in $config_file"
    fi
    
    # Apply immediately
    sysctl -w "$param=$value" >/dev/null
    local new_value=$(get_kernel_param "$param")
    
    print_comparison "$param" "$current_value" "$new_value"
}

# Function to configure THP with comparison
configure_thp() {
    local thp_path=$1
    local recommendation=$2
    
    print_section "Transparent Huge Pages (THP)"
    
    local current_thp=$(get_current_thp_status "$thp_path")
    echo "Current THP status: $current_thp"
    
    echo "$recommendation" > "$thp_path/enabled"
    echo "$recommendation" > "$thp_path/defrag"
    
    local new_thp=$(get_current_thp_status "$thp_path")
    print_comparison "THP Status" "$current_thp" "$new_thp"
    
    # Make persistent
    if [ -f /etc/rc.local ]; then
        if ! grep -q "echo $recommendation > $thp_path/enabled" /etc/rc.local; then
            sed -i "/^exit 0/i echo $recommendation > $thp_path/enabled" /etc/rc.local
            sed -i "/^exit 0/i echo $recommendation > $thp_path/defrag" /etc/rc.local
        fi
    else
        echo "#!/bin/sh -e" > /etc/rc.local
        echo "echo $recommendation > $thp_path/enabled" >> /etc/rc.local
        echo "echo $recommendation > $thp_path/defrag" >> /etc/rc.local
        echo "exit 0" >> /etc/rc.local
        chmod +x /etc/rc.local
    fi
}

# Main script starts here
print_section "System Detection"
detect_os
detect_mongodb_version
get_mongodb_dbpath

# Determine THP recommendation (version-dependent)
if [ "$MONGODB_MAJOR_VERSION" -ge 8 ]; then
    THP_RECOMMENDATION="always"
    echo "MongoDB 8.0+: THP enabled is recommended"
else
    THP_RECOMMENDATION="never"
    echo "MongoDB <8.0: THP disabled is recommended"
fi

# Find THP path
thp_path=""
if [ -d "/sys/kernel/mm/redhat_transparent_hugepage" ]; then
    thp_path="/sys/kernel/mm/redhat_transparent_hugepage"
elif [ -d "/sys/kernel/mm/transparent_hugepage" ]; then
    thp_path="/sys/kernel/mm/transparent_hugepage"
else
    echo "THP path not found on this system."
    exit 1
fi

# Show summary
print_section "Planned Changes"
echo "OS Type: $OS $OS_VERSION"
echo "MongoDB Version: $MONGODB_VERSION_STRING"
echo "THP Setting: $THP_RECOMMENDATION"
echo "Readahead: Will be set to 32 sectors (16KB effective) for MongoDB data directory"
echo "Other kernel parameters will be optimized"

read -p "Do you want to proceed with these changes? (yes/no) " confirm
if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
    echo "Aborting script execution."
    exit 0
fi

# Configure THP (version-dependent)
configure_thp "$thp_path" "$THP_RECOMMENDATION"

# Always set readahead (version-independent)
set_readahead_for_path "$DB_PATH"

# Configure kernel parameters
set_kernel_param "vm.dirty_ratio" 15 "/etc/sysctl.conf"
set_kernel_param "vm.dirty_background_ratio" 5 "/etc/sysctl.conf"
set_kernel_param "vm.swappiness" 1 "/etc/sysctl.conf"
set_kernel_param "kernel.pid_max" 128000 "/etc/sysctl.conf"
set_kernel_param "kernel.threads-max" 128000 "/etc/sysctl.conf"
set_kernel_param "vm.max_map_count" 1024000 "/etc/sysctl.conf"

# Apply all sysctl changes
sysctl -p > /dev/null

# Configure MongoDB service limits
read -p "Do you want to configure overrides for 'mongod' or 'mongos' service? " service_name
service_name=$(echo "$service_name" | tr '[:upper:]' '[:lower:]')

service_override_path=""
if [ "$service_name" == "mongod" ]; then
    service_override_path="/etc/systemd/system/mongod.service.d/override.conf"
elif [ "$service_name" == "mongos" ]; then
    service_override_path="/etc/systemd/system/mongos.service.d/override.conf"
else
    echo "Invalid service name."
    exit 1
fi

# Create service directory if needed
service_directory=$(dirname "$service_override_path")
if [ ! -d "$service_directory" ]; then
    mkdir -p "$service_directory"
fi

# Configure service limits
print_section "Service Limits Configuration"
echo "Configuring $service_name service limits..."

override_content="[Service]
LimitFSIZE=infinity
LimitCPU=infinity
LimitAS=infinity
LimitMEMLOCK=infinity
LimitNOFILE=64000
LimitNPROC=64000"

if [ ! -f "$service_override_path" ] || ! echo "$override_content" | diff - "$service_override_path" >/dev/null; then
    echo "$override_content" > "$service_override_path"
    systemctl daemon-reload
    echo "Service limits updated."
else
    echo "Service limits already configured."
fi

print_section "All Configurations Completed"
echo "All optimizations have been applied successfully!"
echo "Please restart MongoDB for all changes to take effect."
