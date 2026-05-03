#!/bin/bash

# Configuration
PI_USER="autox"
PI_HOST="192.168.0.126"
PI_DEST_DIR="/opt/geoteleport" # Assuming this is where it's deployed based on previous messages
PI_TMP_DIR="/tmp/geoteleport_deploy"

echo "=========================================================="
echo "🚀 GeoTeleportMac -> Raspberry Pi Deployment Script"
echo "=========================================================="

# Ensure cargo-zigbuild is installed (macOS Homebrew)
if ! command -v cargo-zigbuild &> /dev/null; then
    echo "📦 Installing cargo-zigbuild (cross-compiler)..."
    brew install cargo-zigbuild
fi

# Ensure aarch64 target is added
rustup target add aarch64-unknown-linux-gnu

echo "🔨 Building Raspberry Pi Host (aarch64)..."
cd raspberry-pi-host
touch src/main.rs
~/.cargo/bin/cargo zigbuild --release --target aarch64-unknown-linux-gnu
cd ..

echo "🔨 Building Device Core Daemon (aarch64)..."
cd native-device-core
~/.cargo/bin/cargo zigbuild --release --target aarch64-unknown-linux-gnu --bin geoteleport-device-core
cd ..

echo "✅ Build completed locally!"

echo "📦 Transferring binaries to Raspberry Pi ($PI_USER@$PI_HOST)..."

# Create a temporary directory on the Pi to hold the new binaries
ssh $PI_USER@$PI_HOST "mkdir -p $PI_TMP_DIR"

# SCP the compiled binaries
scp raspberry-pi-host/target/aarch64-unknown-linux-gnu/release/raspberry-pi-host $PI_USER@$PI_HOST:$PI_TMP_DIR/raspberry-pi-host
scp native-device-core/target/aarch64-unknown-linux-gnu/release/geoteleport-device-core $PI_USER@$PI_HOST:$PI_TMP_DIR/geoteleport-device-core

echo "🔄 Restarting services on Raspberry Pi..."
ssh -t $PI_USER@$PI_HOST "sudo systemctl stop geoteleport.service || true && \
    sudo mv $PI_TMP_DIR/raspberry-pi-host $PI_DEST_DIR/geoteleport-host && \
    sudo mv $PI_TMP_DIR/geoteleport-device-core $PI_DEST_DIR/geoteleport-device-core && \
    sudo chmod +x $PI_DEST_DIR/geoteleport-host $PI_DEST_DIR/geoteleport-device-core && \
    sudo systemctl start geoteleport.service && \
    rm -rf $PI_TMP_DIR && \
    echo '✅ Deployment Successful!'"

echo "🎉 All done. The service should be running on http://$PI_HOST:8080"
