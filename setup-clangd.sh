#!/bin/bash

# Get Node.js version without the 'v' prefix
NODE_VERSION=$(node -v | sed 's/v//')

# Construct the node-gyp path
NODE_GYP_PATH="$HOME/Library/Caches/node-gyp/$NODE_VERSION"

# Check if the node-gyp directory exists
if [ ! -d "$NODE_GYP_PATH" ]; then
    echo "Error: node-gyp directory not found at $NODE_GYP_PATH"
    echo "Running node-gyp configure to set up headers..."
    cd "$(dirname "$0")" && npm run configure
fi

# Generate .clangd from template
sed "s|{{NODE_GYP_PATH}}|$NODE_GYP_PATH|g" "$(dirname "$0")/.clangd.template" > "$(dirname "$0")/.clangd"

echo "Generated .clangd configuration with node-gyp path: $NODE_GYP_PATH" 