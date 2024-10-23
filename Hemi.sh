#!/bin/bash

# Function to display messages in purple
show() {
    echo -e "\033[1;35m$1\033[0m"
}

# Function to restart the hemi service
restart_service() {
    local service_name="hemi.service"
    local attempts=0
    local max_attempts=10

    while (( attempts < max_attempts )); do
        sudo systemctl restart "$service_name"
        if systemctl is-active --quiet "$service_name"; then
            show "$service_name restarted successfully."
            return 0
        else
            attempts=$((attempts + 1))
            show "Failed to restart $service_name (Attempt $attempts/$max_attempts). Checking system logs for details..."
            sudo journalctl -u "$service_name" --no-pager -n 10
            show "Retrying in 5 seconds..."
            sleep 5
        fi
    done

    show "Failed to restart $service_name after $max_attempts attempts."
    return 1
}

# Function to fetch and update the static fee
fetch_and_update_fee() {
    local service_name="hemi.service"
    local service_file="/etc/systemd/system/$service_name"

    while true; do
        raw_fee=$(curl -sSL "https://mempool.space/testnet/api/v1/fees/mempool-blocks" | jq -r '.[0].medianFee')

        if [[ $? -ne 0 || -z "$raw_fee" ]]; then
            show "Error: Failed to fetch static fee. Retrying in 10 seconds."
            sleep 10
            continue
        fi

        static_fee=$(printf "%.0f" "$raw_fee")
        show "Static fee fetched: $static_fee"

        if [[ -f "$service_file" ]]; then
            if systemctl is-active --quiet "$service_name"; then
                show "Stopping $service_name..."
                sudo systemctl stop "$service_name"
            fi

            show "Updating static fee in $service_file"
            sudo sed -i '/POPM_STATIC_FEE/d' "$service_file"
            sudo sed -i "/\[Service\]/a Environment=\"POPM_STATIC_FEE=$static_fee\"" "$service_file"
            
            sudo systemctl daemon-reload
            show "Waiting 2 seconds before restarting the service..."
            sleep 2

            restart_service "$service_name"
        fi

        sleep 600
    done
}

# Initial setup and wallet management
curl -s https://raw.githubusercontent.com/choir94/Airdropguide/refs/heads/main/logo.sh | bash
sleep 6

ARCH=$(uname -m)

if ! command -v jq &> /dev/null; then
    show "jq not found, installing..."
    sudo apt-get update
    sudo apt-get install -y jq > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        show "Failed to install jq. Please check your package manager."
        exit 1
    fi
fi

check_latest_version() {
    for i in {1..3}; do
        LATEST_VERSION=$(curl -s https://api.github.com/repos/hemilabs/heminetwork/releases/latest | jq -r '.tag_name')
        if [ -n "$LATEST_VERSION" ]; then
            show "Latest available version: $LATEST_VERSION"
            return 0
        fi
        show "Attempt $i: Failed to fetch the latest version. Retrying..."
        sleep 2
    done

    show "Failed to fetch the latest version after 3 attempts. Please check your internet connection or GitHub API limits."
    exit 1
}

check_latest_version

download_needed=true

if [ "$ARCH" == "x86_64" ]; then
    if [ -d "heminetwork_${LATEST_VERSION}_linux_amd64" ]; then
        show "Latest version for x86_64 is already downloaded. Skipping download."
        cd "heminetwork_${LATEST_VERSION}_linux_amd64" || { show "Failed to enter directory."; exit 1; }
        download_needed=false
    fi
elif [ "$ARCH" == "arm64" ]; then
    if [ -d "heminetwork_${LATEST_VERSION}_linux_arm64" ]; then
        show "Latest version for arm64 is already downloaded. Skipping download."
        cd "heminetwork_${LATEST_VERSION}_linux_arm64" || { show "Failed to enter directory."; exit 1; }
        download_needed=false
    fi
fi

if [ "$download_needed" = true ]; then
    if [ "$ARCH" == "x86_64" ]; then
        show "Downloading for x86_64 architecture..."
        wget --quiet --show-progress "https://github.com/hemilabs/heminetwork/releases/download/$LATEST_VERSION/heminetwork_${LATEST_VERSION}_linux_amd64.tar.gz" -O "heminetwork_${LATEST_VERSION}_linux_amd64.tar.gz"
        tar -xzf "heminetwork_${LATEST_VERSION}_linux_amd64.tar.gz" > /dev/null
        cd "heminetwork_${LATEST_VERSION}_linux_amd64" || { show "Failed to enter directory."; exit 1; }
    elif [ "$ARCH" == "arm64" ]; then
        show "Downloading for arm64 architecture..."
        wget --quiet --show-progress "https://github.com/hemilabs/heminetwork/releases/download/$LATEST_VERSION/heminetwork_${LATEST_VERSION}_linux_arm64.tar.gz" -O "heminetwork_${LATEST_VERSION}_linux_arm64.tar.gz"
        tar -xzf "heminetwork_${LATEST_VERSION}_linux_arm64.tar.gz" > /dev/null
        cd "heminetwork_${LATEST_VERSION}_linux_arm64" || { show "Failed to enter directory."; exit 1; }
    else
        show "Unsupported architecture: $ARCH"
        exit 1
    fi
else
    show "Skipping download since the latest version is already present."
fi

echo
show "Choose only one option:"
show "1. Create New Wallet (recommended)"
show "2. Use existing wallet"
read -p "Enter your choice (1/2): " choice
echo

if [ "$choice" == "1" ]; then
    show "Creating a new wallet..."
    ./keygen -secp256k1 -json -net="testnet" > ~/popm-address.json
    if [ $? -ne 0 ]; then
        show "Failed to create wallet."
        exit 1
    fi
    cat ~/popm-address.json
    echo
    read -p "Have you saved the above details? (y/N): " saved
    echo
    if [[ "$saved" =~ ^[Yy]$ ]]; then
        pubkey_hash=$(jq -r '.pubkey_hash' ~/popm-address.json)
        show "Join : https://discord.gg/hemixyz"
        show "Request faucet from the faucet channel for this address: $pubkey_hash"
        echo
        read -p "Have you requested faucet? (y/N): " faucet_requested
        if [[ "$faucet_requested" =~ ^[Yy]$ ]]; then
            priv_key=$(jq -r '.private_key' ~/popm-address.json)
            read -p "Enter static fee (numeric only, recommended: 100-200): " static_fee
            echo
            export POPM_BTC_PRIVKEY="$priv_key"
            export POPM_STATIC_FEE="$static_fee"
            export POPM_BFG_URL="wss://testnet.rpc.hemi.network/v1/ws/public"
            
            screen -dmS airdropnode ./popmd
            if [ $? -ne 0 ]; then
                show "Failed to start PoP mining in a separate screen session."
                exit 1
            fi

            show "PoP mining has started in a separate screen session named 'airdropnode'."
        fi
    fi

elif [ "$choice" == "2" ]; then
    read -p "Enter your Private key: " priv_key
    read -p "Enter static fee (numeric only, recommended: 200-600): " static_fee
    echo
    export POPM_BTC_PRIVKEY="$priv_key"
    export POPM_STATIC_FEE="$static_fee"
    export POPM_BFG_URL="wss://testnet.rpc.hemi.network/v1/ws/public"
    
    screen -dmS airdropnode ./popmd
    if [ $? -ne 0 ]; then
        show "Failed to start PoP mining in a separate screen session."
        exit 1
    fi

    show "PoP mining has started in a separate screen session named 'airdropnode'."
else
    show "Invalid choice."
    exit 1
fi

# Start fetching and updating fee in the background
fetch_and_update_fee &

echo -e "\033[1;35m Join the airdrop node https://t.me/airdrop_node \033[0m"
