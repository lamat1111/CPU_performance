#!/bin/bash

# tput color codes
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
BLUE=$(tput setaf 4)
MAGENTA=$(tput setaf 5)
CYAN=$(tput setaf 6)
WHITE=$(tput setaf 7)
BOLD=$(tput bold)
NC=$(tput sgr0) # No Color

# Log file path
LOG_DIR="/root/scripts/logs"
LOG_FILE="$LOG_DIR/cpu_performance.log"
MAX_LOG_SIZE=$((10 * 1024 * 1024))  # 10 MB in bytes

# Function to rotate log
rotate_log() {
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -ge $MAX_LOG_SIZE ]; then
        timestamp=$(date +"%Y%m%d_%H%M%S")
        mv "$LOG_FILE" "${LOG_FILE}_${timestamp}"
        touch "$LOG_FILE"
        echo "Log rotated at $(date)" >> "$LOG_FILE"
    fi
}

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    rotate_log
}

# Function to print section headers
print_header() {
    printf "\n${BOLD}${CYAN}%s${NC}\n" "$1"
    printf "${CYAN}%s${NC}\n" "$(printf '=%.0s' {1..40})"
}

# Function to trim leading and trailing whitespace
trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"   # remove leading whitespace characters
    var="${var%"${var##*[![:space:]]}"}"   # remove trailing whitespace characters
    printf '%s' "$var"
}

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Check if script is run as root
if [ "$(id -u)" != "0" ]; then
   printf "${RED}This script must be run as root${NC}\n"
   log_message "ERROR: Script was not run as root"
   exit 1
fi

log_message "Script started"

# Create temporary files
TEMP_DIR=$(mktemp -d)
GOVERNOR_FILE="$TEMP_DIR/governor_count"
CPU_INFO_FILE="$TEMP_DIR/cpu_info"
MEMORY_INFO_FILE="$TEMP_DIR/memory_info"

# Function to clean up temporary files
cleanup() {
    rm -rf "$TEMP_DIR"
    log_message "Temporary files cleaned up"
}
trap cleanup EXIT

# Ensure cpupower is installed
if ! command -v cpupower &> /dev/null; then
    echo "cpupower not found, installing..."
    apt install -y linux-tools-common linux-tools-generic
fi

# Ensure bc is installed
if ! command -v bc &> /dev/null; then
    echo "bc not found, installing..."
    apt install -y bc
fi

# Set CPU governor to performance mode
printf "${BLUE}Setting all cores to performance mode...${NC}\n"
log_message "Setting all cores to performance mode"
cpupower frequency-set -g performance

# Initialize variables to store core counts
performance_cores=0
powersave_cores=0
ondemand_cores=0
conservative_cores=0
schedutil_cores=0

# Count cores in each mode
for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    if [ -f "$gov_file" ]; then
        mode=$(cat $gov_file)
        case "$mode" in
            "performance") ((performance_cores++)) ;;
            "powersave") ((powersave_cores++)) ;;
            "ondemand") ((ondemand_cores++)) ;;
            "conservative") ((conservative_cores++)) ;;
            "schedutil") ((schedutil_cores++)) ;;
        esac
    fi
done

# Write core counts to the governor file
printf "performance %d\n" $performance_cores >> "$GOVERNOR_FILE"
printf "powersave %d\n" $powersave_cores >> "$GOVERNOR_FILE"
printf "ondemand %d\n" $ondemand_cores >> "$GOVERNOR_FILE"
printf "conservative %d\n" $conservative_cores >> "$GOVERNOR_FILE"
printf "schedutil %d\n" $schedutil_cores >> "$GOVERNOR_FILE"

log_message "Core counts - Performance: $performance_cores, Powersave: $powersave_cores, Ondemand: $ondemand_cores, Conservative: $conservative_cores, Schedutil: $schedutil_cores"

# Check boost status
if cpupower frequency-info | grep -q "boost state support:.*Active: yes"; then
    echo "Boost is already active" >> "$CPU_INFO_FILE"
    log_message "AMD boost is active"
else
    echo "Boost is not active or not supported" >> "$CPU_INFO_FILE"
    log_message "AMD boost is not active or not supported"
fi

# Get detailed CPU information
cpupower frequency-info >> "$CPU_INFO_FILE"

# Get CPU information
lscpu | egrep "Model name|^CPU\(s\)|Thread\(s\) per core|Core\(s\) per socket|Socket\(s\)|NUMA node\(s\)|CPU MHz|CPU max MHz|CPU min MHz|L1d cache|L1i cache|L2 cache|L3 cache|CPU family|Model|Architecture|CPU op-mode|Virtualization:" >> "$CPU_INFO_FILE"

# Calculate average frequency
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    avg_freq=$(awk '{sum+=$1} END {printf "%.2f", sum/NR/1000}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null)
    avg_freq_ghz=$(echo "scale=2; $avg_freq / 1000" | bc)
else
    avg_freq_ghz="N/A"
fi
echo "Average CPU Frequency: $avg_freq_ghz" >> "$CPU_INFO_FILE"
log_message "Average CPU frequency: $avg_freq_ghz GHz"

# Get CPU utilization
cpu_util=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')
printf "cpu_util %.2f\n" $cpu_util >> "$CPU_INFO_FILE"
log_message "CPU utilization: $cpu_util%"

# Get memory information
free -m | awk 'NR==2{printf "Memory Usage: %s/%sMB (%.2f%%)\n", $3,$2,$3*100/$2 }' > "$MEMORY_INFO_FILE"
log_message "$(cat "$MEMORY_INFO_FILE")"

# Get uptime
uptime -p | awk '{printf "Uptime: %s\n", $0}' >> "$CPU_INFO_FILE"

# Print results
printf "\n${BOLD}${YELLOW}CPU Performance Summary${NC}\n"
printf "${YELLOW}%s${NC}\n" "$(printf '=%.0s' {1..40})"

print_header "1. System Overview"
printf "${BLUE}%-28s${NC}${WHITE}%s${NC}\n" "CPU Model:" "$(grep "Model name" "$CPU_INFO_FILE" | cut -d':' -f2 | xargs)"
printf "${BLUE}%-28s${NC}${WHITE}%s${NC}\n" "Total CPU Threads:" "$(grep "CPU(s)" "$CPU_INFO_FILE" | awk '{print $2}')"
printf "${BLUE}%-28s${NC}${WHITE}%s${NC}\n" "Architecture:" "$(grep "Architecture" "$CPU_INFO_FILE" | cut -d':' -f2 | xargs)"
printf "${BLUE}%-28s${NC}${WHITE}%s${NC}\n" "Uptime:" "$(grep "Uptime" "$CPU_INFO_FILE" | cut -d':' -f2- | xargs)"

print_header "2. CPU Specifications"
printf "${BLUE}%-28s${NC}${WHITE}%.2f GHz${NC}\n" "Minimum Clock Speed:" "$(echo "scale=2; $(grep "CPU min MHz" "$CPU_INFO_FILE" | awk '{print $4}')/1000" | bc)"
printf "${BLUE}%-28s${NC}${WHITE}%.2f GHz${NC}\n" "Maximum Clock Speed:" "$(echo "scale=2; $(grep "CPU max MHz" "$CPU_INFO_FILE" | awk '{print $4}')/1000" | bc)"
printf "${BLUE}%-28s${NC}${GREEN}%.2f GHz${NC}\n" "Average CPU Frequency:" "$(grep "Average CPU Frequency" "$CPU_INFO_FILE" | cut -d':' -f2 | xargs)"
printf "${BLUE}%-28s${NC}${WHITE}%.2f%%${NC}\n" "Current CPU Utilization:" "$(grep "cpu_util" "$CPU_INFO_FILE" | cut -d' ' -f2)"

print_header "3. Cache Information"
printf "${BLUE}%-28s${NC}${WHITE}%s${NC}\n" "L1 Data Cache:" "$(grep "L1d cache" "$CPU_INFO_FILE" | cut -d':' -f2 | xargs)"
printf "${BLUE}%-28s${NC}${WHITE}%s${NC}\n" "L1 Instruction Cache:" "$(grep "L1i cache" "$CPU_INFO_FILE" | cut -d':' -f2 | xargs)"
