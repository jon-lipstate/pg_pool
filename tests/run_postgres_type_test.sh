#!/bin/bash

echo "Building test_postgres_type..."
if odin build test_postgres_type.odin -file -out:test_postgres_type; then
    echo "✓ Build successful"
    echo ""
    echo "Running test (requires DATABASE_URL to be set)..."
    if [ -z "$DATABASE_URL" ]; then
        echo "⚠️  DATABASE_URL not set. ⚠️"
        exit 1
    fi
    echo ""
    ./test_postgres_type
else
    echo "✗ Build failed"
    exit 1
fi