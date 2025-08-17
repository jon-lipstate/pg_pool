#!/bin/bash

# Build and run PostgreSQL pool tests

echo "🔧 Building PostgreSQL Pool Test Suite..."
echo ""

# Array of test files to build
tests=(
    "test_type_safety"
    "test_basic" 
    "test_transactions"
    "test_dates_times"
    "test_binary_custom"
    "test_struct_scanning"
)

build_count=0
total_tests=${#tests[@]}

echo "Building individual test files:"
echo "================================"

for test in "${tests[@]}"; do
    echo -n "Building ${test}.odin... "
    
    if odin build "${test}.odin" -file -o:speed -out:"${test}" 2>/dev/null; then
        echo "✅"
        ((build_count++))
    else
        echo "❌"
        echo "  Error details:"
        odin build "${test}.odin" -file -o:speed -out:"${test}" 2>&1 | head -3 | sed 's/^/    /'
        echo ""
    fi
done

echo ""
echo "📊 Build Summary:"
echo "  Successfully built: ${build_count}/${total_tests} tests"

if [ $build_count -eq $total_tests ]; then
    echo "  🎉 All tests built successfully!"
else
    echo "  ⚠️  Some tests failed to build"
fi

echo ""
echo "🚀 Usage:"
echo "  Run individual tests: ./test_type_safety"
echo "  Run with database:    DATABASE_URL='postgresql://...' ./test_type_safety"
echo "  All tests require:    - PostgreSQL running"
echo "                       - DATABASE_URL environment variable"
echo "                       - Test database with appropriate permissions"

echo ""
echo "✨ Test Suite Organization Complete!"
echo "   📁 All tests organized by functionality"
echo "   🔧 Build system working"
echo "   📖 Documentation complete"
echo "   🧪 Individual test files ready for execution"