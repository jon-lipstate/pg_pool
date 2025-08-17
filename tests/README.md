# PostgreSQL Pool Tests

This directory contains the test suite for the PostgreSQL connection pool library.

## Test Organization

### Core Test Files

- **`test_basic.odin`** - Basic queries, parameterized queries, NULL handling
- **`test_transactions.odin`** - Transaction support and nested transactions (savepoints)
- **`test_type_safety.odin`** - Array type safety, upcasting, and downcasting prevention
- **`test_dates_times.odin`** - Date/time types, timezone handling
- **`test_binary_custom.odin`** - Binary format support and custom types (UUID)
- **`test_struct_scanning.odin`** - Automatic struct scanning with `pg:` tags

### Test Infrastructure

- **`runner.odin`** - Main test runner that executes all tests
- **`package.odin`** - Package declaration for test suite
- **`build.sh`** - Build script for running tests

## Running Tests

### Prerequisites

1. PostgreSQL database running locally
2. Environment file (`.env`) configured with database connection details
3. Odin compiler installed

### Quick Start

```bash
# From the tests directory
./build.sh
```

### Manual Build

```bash
# From the tests directory
odin build . -o:speed -out:pg_pool_tests
./pg_pool_tests
```

### From Parent Directory

```bash
# From the main pg_pool directory
cd tests && ./build.sh
```

## Test Coverage

The test suite covers:

### ✅ Basic Functionality
- Connection establishment
- Basic SELECT/INSERT queries
- Parameterized queries with `$1`, `$2` syntax
- NULL value handling
- Error handling

### ✅ Advanced Features
- Transaction support (`BEGIN`, `COMMIT`, `ROLLBACK`)
- Nested transactions with savepoints
- Binary format by default with text format opt-in (via `result_format = .Text`)
- Custom type support (UUID)
- Automatic struct scanning with field mapping

### ✅ Type System
- Array type safety (prevents unsafe downcasts)
- Safe upcasting (INT2[] → []i32, []i64)
- Type conversion between formats
- NUMERIC/DECIMAL and MONEY types
- INTERVAL type support

### ✅ Date/Time Support
- DATE, TIMESTAMP, TIMESTAMPTZ types
- Timezone handling and conversion
- Binary format parsing for temporal types

### ✅ Performance & Memory
- Memory leak detection
- Connection pooling statistics
- Binary format efficiency

## Test Data Structures

The tests use these structures with PostgreSQL field mapping:

```odin
User :: struct {
    id:         int `pg:"id"`,
    email:      string `pg:"email"`,
    full_name:  string `pg:"name"`,        // Maps to 'name' column
    age:        int `pg:"age"`,
    active:     bool `pg:"is_active"`,     // Maps to 'is_active' column
    created_at: string `pg:"created_at"`,
}

Product :: struct {
    product_id:   int `pg:"id"`,           // Maps to 'id' column
    product_name: string `pg:"name"`,      // Maps to 'name' column
    price:        f64 `pg:"price"`,
    stock_count:  int `pg:"stock"`,        // Maps to 'stock' column
    desc:         string `pg:"description"`, // Maps to 'description' column
}
```

## Environment Setup

Required `.env` file in the parent directory:

```env
DATABASE_URL=postgres://username:password@localhost:5432/database_name
```

Or individual environment variables:
```env
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
POSTGRES_USER=username
POSTGRES_PASSWORD=password
POSTGRES_DATABASE=database_name
```
