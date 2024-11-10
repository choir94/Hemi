#!/bin/bash

# Define color codes
WHITE="\033[1;37m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
GREEN="\033[1;32m"
RESET_COLOR="\033[0m"

# Display function with color
tampilkan() {
    echo -e "$CYAN$1$RESET_COLOR"
}

# Check and install required dependencies
install_dependencies() {
    for cmd in curl wget jq; do
        if ! command -v "$cmd" &>/dev/null; then
            tampilkan "$cmd tidak ditemukan, menginstal..."
            sudo apt-get update && sudo apt-get install -y "$cmd" > /dev/null 2>&1
            if [ $? -ne 0 ]; then
                tampilkan "Gagal menginstal $cmd. Silakan periksa manajer paket Anda."
                exit 1
            fi
        fi
    done
}

# Check latest version from GitHub
periksa_versi_terbaru() {
    for i in {1..3}; do
        VERSI_TERBARU=$(curl -s https://api.github.com/repos/hemilabs/heminetwork/releases/latest | jq -r '.tag_name')
        if [ -n "$VERSI_TERBARU" ]; then
            tampilkan "Versi terbaru yang tersedia: $VERSI_TERBARU"
            return 0
        fi
        tampilkan "Percobaan $i: Gagal mengambil versi terbaru. Mencoba lagi..."
        sleep 2
    done

    tampilkan "Gagal mengambil versi terbaru setelah 3 percobaan."
    exit 1
}

# Check system architecture and download the latest version if not already present
download_and_extract() {
    local arch_dir=""
    case "$ARCH" in
        x86_64) arch_dir="heminetwork_${VERSI_TERBARU}_linux_amd64" ;;
        arm64)  arch_dir="heminetwork_${VERSI_TERBARU}_linux_arm64" ;;
        *) tampilkan "Arsitektur tidak didukung: $ARCH"; exit 1 ;;
    esac

    if [ -d "$arch_dir" ]; then
        tampilkan "Versi terbaru sudah diunduh. Melewati unduhan."
    else
        tampilkan "Mengunduh versi terbaru untuk arsitektur $ARCH..."
        wget -q --show-progress "https://github.com/hemilabs/heminetwork/releases/download/$VERSI_TERBARU/${arch_dir}.tar.gz" -O "${arch_dir}.tar.gz"
        tar -xzf "${arch_dir}.tar.gz"
    fi

    cd "$arch_dir" || { tampilkan "Gagal masuk ke direktori."; exit 1; }
}

# Start PoP mining in a screen session
start_pop_mining() {
    local priv_key="$1"
    local fee="$2"
    export POPM_BTC_PRIVKEY="$priv_key"
    export POPM_STATIC_FEE="$fee"
    export POPM_BFG_URL="wss://testnet.rpc.hemi.network/v1/ws/public"

    screen -dmS airdropnode ./popmd
    if [ $? -ne 0 ]; then
        tampilkan "Gagal memulai PoP mining dalam sesi screen terpisah."
        exit 1
    fi
    tampilkan "PoP mining telah dimulai dalam sesi screen terpisah bernama 'airdropnode'."
}

# Fetch and update static fees periodically
ambil_dan_perbarui_biaya() {
    local nama_layanan="hemi.service"
    local berkas_layanan="/etc/systemd/system/$nama_layanan"

    while true; do
        biaya_mentah=$(curl -sSL "https://mempool.space/testnet/api/v1/fees/mempool-blocks" | jq '.[0].medianFee')
        if [[ -n "$biaya_mentah" ]]; then
            biaya_statis=$(printf "%.0f" "$biaya_mentah")
            tampilkan "Biaya statis yang diambil: $biaya_statis"
            sudo sed -i '/POPM_STATIC_FEE/d' "$berkas_layanan"
            sudo sed -i "/\[Service\]/a Environment=\"POPM_STATIC_FEE=$biaya_statis\"" "$berkas_layanan"
            sudo systemctl daemon-reload && sudo systemctl restart "$nama_layanan"
        else
            tampilkan "Gagal mengambil biaya statis. Coba lagi dalam 15 detik."
        fi
        sleep 600
    done
}

# Main execution
install_dependencies
ARCH=$(uname -m)
periksa_versi_terbaru
download_and_extract

# Wallet setup options
tampilkan "$YELLOW Pilih hanya satu opsi:"
tampilkan "$GREEN 1. Buat Wallet Baru (direkomendasikan)"
tampilkan "$GREEN 2. Gunakan wallet yang sudah ada"
read -p "Masukkan pilihan Anda (1/2): " pilihan

if [ "$pilihan" == "1" ]; then
    tampilkan "Membuat wallet baru..."
    ./keygen -secp256k1 -json -net="testnet" > ~/popm-address.json
    if [ $? -ne 0 ]; then
        tampilkan "Gagal membuat wallet."
        exit 1
    fi
    cat ~/popm-address.json
    read -p "Sudah menyimpan detail di atas? (y/N): " tersimpan
    if [[ "$tersimpan" =~ ^[Yy]$ ]]; then
        pubkey_hash=$(jq -r '.pubkey_hash' ~/popm-address.json)
        tampilkan "$CYAN Minta faucet untuk alamat: $pubkey_hash"
        read -p "Sudah meminta faucet? (y/N): " faucet_diminta
        if [[ "$faucet_diminta" =~ ^[Yy]$ ]]; then
            priv_key=$(jq -r '.private_key' ~/popm-address.json)
            read -p "Masukkan biaya statis (100-200): " biaya_statis
            start_pop_mining "$priv_key" "$biaya_statis"
        fi
    fi

elif [ "$pilihan" == "2" ]; then
    read -p "Masukkan Private key Anda: " priv_key
    read -p "Masukkan biaya statis (100-200): " biaya_statis
    start_pop_mining "$priv_key" "$biaya_statis"
else
    tampilkan "Pilihan tidak valid."
    exit 1
fi

echo -e "${CYAN} Bergabung dengan airdrop node https://t.me/airdrop_node ${RESET_COLOR}"

# Run fee update in background
ambil_dan_perbarui_biaya &
