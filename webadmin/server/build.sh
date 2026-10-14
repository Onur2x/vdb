#!/bin/bash
echo "Building VDB Web API (FPC Native)..."

lazbuild main.pas

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

echo ""
echo "Build successful!"
echo "Run: ./main"