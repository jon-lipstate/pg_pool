# pg_pool

Multi-threadable PostgreSQL pool library for Odin built on libpq with a high-level api interface. This library is still considered in work, design suggestions welcome.

## Features

- **Connection Pooling** - Configurable min/max connections with automatic lifecycle management
- **Transaction Support** - Including nested transactions via savepoints
- **Rich Type Support** - Arrays, NUMERIC, MONEY, INTERVAL, UUID, JSON, basic types, pointers
- **Struct Scanning** - Automatic mapping with `pg:` tags to alias field to db names via RTTI

## Installation

```bash
# Install PostgreSQL client library
sudo apt install libpq-dev    # Debian/Ubuntu
brew install libpq             # macOS
```

Clone bindings into `vendor/`: [odin-postgresql](https://github.com/laytan/odin-postgresql).

Configure Connection string or setup `.env` with it.

### Usage

pgpool uses a global pool (`pool.POOL`)that is initialized as follows:

```odin
import pool "pg_pool/pool"

main :: proc() {
    // Initialize the pool
    err := pool.init(
        "postgresql://user:password@localhost/mydb", // or from env file
        min_connections = 2,
        max_connections = 10,
    )
    if err != nil {
        fmt.eprintln("Failed to initialize pool:", err)
        return
    }
    defer pool.destroy_pool()
}
```

## Examples

### Basic Queries

**Important**: Scanning `nil` values into non-nil types like `int` will set the zero value. used `^int` if it can be nil.

```odin
rows, err := pool.query("SELECT id, name FROM users WHERE active = true")
if err != nil {
    fmt.eprintln("Query failed:", err)
    return
}
defer pool.release_query(&rows)

for pool.next_row(&rows) {
    id, _ := pool.scan(&rows, int, 0)
    name, _ := pool.scan(&rows, string, 1, context.allocator)
    defer delete(name)  // scan will allocate when required, and accepts a custom allocator
    
    fmt.printf("User: %d - %s\n", id, name)
}
```

### Parameterized Queries

```odin
// Safe from SQL injection
user_id := 42
rows, err := pool.query(
    "SELECT email, created_at FROM users WHERE id = $1", 
    args = {user_id}
)
defer pool.release_query(&rows)
```

### Transactions

```odin
// Start transaction
tx, err := pool.begin()
if err != nil {
    return
}
defer pool.rollback(tx)  // rollback is commit-safe; it can always be called with defer and will only execute if not commited

// Perform operations
pool.exec("UPDATE accounts SET balance = balance - $1 WHERE id = $2", 
    tx, args = {100.00, sender_id})
pool.exec("UPDATE accounts SET balance = balance + $1 WHERE id = $2", 
    tx, args = {100.00, receiver_id})

// Commit if everything succeeded
pool.commit(tx)
```

### Struct Scanning

NOTE: Struct scanning only parses into basic types, single variant unions, pointers and slices. Nested structs and other types not listed are not implemented yet.

```odin
User :: struct {
    id:         int    `pg:"id"`,
    email:      string `pg:"email"`,
    full_name:  string `pg:"name"`,      // Maps to 'name' column
    active:     bool   `pg:"is_active"`, // Maps to 'is_active' column
    created_at: time.Time `pg:"created_at"`, // Times are currently always assumed UTC (No Locale mapping yet)
}

// Automatic struct mapping
user := pool.query_row_into(
    "SELECT id, email, name, is_active, created_at FROM users WHERE id = $1",
    User,
    args = {user_id}
)
```

## Type Support

### Native Types

| PostgreSQL Type | Odin Type | Notes |
|----------------|-----------|--------|
| SMALLINT/INT2 | `i16` | |
| INTEGER/INT4 | `i32` | |
| BIGINT/INT8 | `i64` | |
| REAL/FLOAT4 | `f32` | |
| DOUBLE PRECISION/FLOAT8 | `f64` | |
| BOOLEAN | `bool` | |
| TEXT/VARCHAR/CHAR | `string` | Allocated |
| BYTEA | `[]byte` | Allocated |
| DATE | `time.Time` | |
| TIMESTAMP/TIMESTAMPTZ | `time.Time` | |
| INTERVAL | `pool.Interval` | Duration type |
| UUID | `string` | Allocated |
| JSON/JSONB | `json.Value` or `string` | Allocated |

### Array Types

Arrays support safe upcasting but prevent unsafe downcasting:

```odin
// Safe upcasts
int2_array, _ := pool.scan(&rows, []i16, 0)  // INT2[] → []i16
int2_array, _ := pool.scan(&rows, []i32, 0)  // INT2[] → []i32 (upcast)
int2_array, _ := pool.scan(&rows, []i64, 0)  // INT2[] → []i64 (upcast)

// Unsafe downcasts (returns error)
int8_array, err := pool.scan(&rows, []i32, 0)  // INT8[] → []i32 (error!)
```

### Special Types

#### NUMERIC/DECIMAL

```odin
import "core:math/fixed"

// Using Fixed-point for exact decimal arithmetic
price: pool.Numeric  // alias for core:math/fixed.Fixed52_12
fixed.init_from_f64(&price, 123.45)

pool.exec("INSERT INTO products (price) VALUES ($1)", args = {price})

// Reading back - can scan as Numeric for exact value or f64 with possible precision loss
rows, _ := pool.query("SELECT price FROM products")
defer pool.release_query(&rows)
if pool.next_row(&rows) {
    // Exact: NUMERIC → pool.Numeric (maintains up to 3 decimal places exactly)
    exact_price, _ := pool.scan(&rows, pool.Numeric, 0)
    
    // Approximate: NUMERIC → f64 (may lose precision beyond 15-17 significant digits)
    approx_price, _ := pool.scan(&rows, f64, 0)
}
```

#### MONEY

```odin
amount: pool.Money  // i64 storing cents
amount = 12345      // $123.45

pool.exec("UPDATE accounts SET balance = $1", args = {amount})
```

#### INTERVAL

```odin
interval := pool.Interval{
    months: 3,
    days: 15,
    microseconds: 7200000000, // 2 hours
}

pool.exec("UPDATE tasks SET reminder = $1", args = {interval})
```

## Binary vs Text Format

Binary format is the default for better performance and type safety:

```odin
// Binary format (default)
rows, _ := pool.query("SELECT * FROM users")

// Text format (when needed for compatibility)
rows, _ := pool.query("SELECT * FROM users", result_format = .Text)
```

## Connection Pool Management

### Configuration

```odin
pool.init(
    connection_string,
    min_connections = 2,      // Minimum idle connections
    max_connections = 10,     // Maximum total connections
    max_idle_mins = 5,        // Close idle connections after
    total_cnx_memory = 16*MB, // Total memory for all connections
)
```

### Pool Statistics

```odin
stats := pool.get_pool_stats()
fmt.printf("Active: %d, Idle: %d, Total: %d\n", 
    stats.active_connections,
    stats.idle_connections, 
    stats.total_connections)
```

### Manual Connection Management

```odin
// Acquire connection manually (usually not needed)
cnx, err := pool.acquire()
if err != nil {
    return
}
defer pool.release(cnx)

// Use connection for multiple operations
rows1, _ := pool.query("SELECT ...", cnx)
rows2, _ := pool.query("SELECT ...", cnx)
```

## Memory Management

The library uses arena allocation for efficient memory management:

- Each connection has its own arena
- Query results are allocated from the connection's arena
- Strings and dynamic arrays from `scan()` must be freed by caller (or supply custom allocator)
- Arena is reset when connection is released

### Monitoring Memory Usage

```odin
// Get memory stats for the entire pool
stats := pool.get_pool_stats()
fmt.printf("Pool Memory Stats:\n")
fmt.printf("  Total allocated: %d KB\n", stats.total_memory / 1024)
fmt.printf("  Peak usage: %d KB\n", stats.peak_memory_used / 1024)
fmt.printf("  Avg query memory: %d KB\n", stats.avg_last_used / 1024)

// Get memory info for a specific query
rows, _ := pool.query("SELECT * FROM large_table")
defer pool.release_query(&rows)

used, allocated := pool.get_query_memory(&rows)
fmt.printf("Query memory: %d KB used of %d KB allocated\n", 
    used / 1024, allocated / 1024)
```

### Custom Arena Sizing

```odin
// Specify arena size when acquiring connection
cnx, _ := pool.acquire(allocation_size = 256 * mem.Kilobyte)
defer pool.release(cnx)

// Or specify for a single query
rows, _ := pool.query(
    "SELECT large_data FROM big_table",
    arena_size = 1 * mem.Megabyte,
)
```

## Custom Type System (Postgres_Type)

The library provides a custom type system for precise control over PostgreSQL type handling, particularly useful for:

- Forcing specific wire formats (binary vs text)
- Handling custom PostgreSQL types (INET, CIDR, etc.)
- Implementing custom serialization/deserialization logic

### Basic Usage

```odin
// Define type hints for binary format transmission
binary_types := []pool.Postgres_Type {
    {oid = pool.OID_INT4, format = .Binary},
    {oid = pool.OID_FLOAT8, format = .Binary},
    {oid = pool.OID_TIMESTAMP, format = .Binary},
}

// Use with exec or query
_, err := pool.exec(
    "INSERT INTO data (id, value, created) VALUES ($1, $2, $3)",
    types = binary_types,
    args = {42, 3.14159, time.now()},
)
```

### Custom Type Handlers

Custom types support both writing (serialization) and reading (deserialization):

#### Writing Custom Types

```odin
// Define a custom UUID writer for insertion
uuid_writer := pool.Postgres_Type {
    oid = pool.OID_UUID,
    format = .Text,
    writer = proc(buf: ^[dynamic]byte, arg: any, format: pq.Format) -> (size: i32) {
        uuid_str := arg.(string)
        p_bytes := transmute([]byte)uuid_str
        append(buf, ..p_bytes)
        append(buf, 0) // null terminator for text format
        return i32(len(uuid_str))
    },
}

// Use for insertion
_, err := pool.exec(
    "INSERT INTO users (id, email) VALUES ($1, $2)",
    types = []pool.Postgres_Type{uuid_writer, {}},
    args = {"550e8400-e29b-41d4-a716-446655440000", "user@example.com"},
)
```

#### Reading Custom Types

```odin
// Define a custom UUID reader
uuid_reader := pool.Postgres_Type {
    reader = proc(bytes: []byte, oid: pq.OID, text_mode: bool, allocator: mem.Allocator) -> (any, pool.Error) {
        if text_mode {
            // Text format: UUID as string
            uuid_str := string(bytes)
            return strings.clone(uuid_str, allocator), nil
        } else {
            // Binary format: 16 bytes
            if len(bytes) != 16 {
                return nil, pool.QueryError.InvalidFormat
            }
            // Convert to string format
            return format_uuid_from_bytes(bytes, allocator), nil
        }
    },
}

// Use when scanning
rows, _ := pool.query("SELECT id FROM users")
defer pool.release_query(&rows)

if pool.next_row(&rows) {
    uuid, _ := pool.scan(&rows, string, 0, custom_type = uuid_reader)
    defer delete(uuid)
    fmt.println("UUID:", uuid)
}
```

### Available OID Constants

Common PostgreSQL type OIDs are predefined:

| Constant | OID | PostgreSQL Type |
|----------|-----|-----------------|
| `OID_INT2` | 21 | SMALLINT |
| `OID_INT4` | 23 | INTEGER |
| `OID_INT8` | 20 | BIGINT |
| `OID_FLOAT4` | 700 | REAL |
| `OID_FLOAT8` | 701 | DOUBLE PRECISION |
| `OID_BOOL` | 16 | BOOLEAN |
| `OID_TEXT` | 25 | TEXT |
| `OID_VARCHAR` | 1043 | VARCHAR |
| `OID_DATE` | 1082 | DATE |
| `OID_TIMESTAMP` | 1114 | TIMESTAMP |
| `OID_TIMESTAMPTZ` | 1184 | TIMESTAMPTZ |
| `OID_INTERVAL` | 1186 | INTERVAL |
| `OID_UUID` | 2950 | UUID |
| `OID_NUMERIC` | 1700 | NUMERIC/DECIMAL |
| `OID_JSON` | 114 | JSON |
| `OID_JSONB` | 3802 | JSONB |
| `OID_INET` | 869 | INET |
| `OID_MONEY` | 790 | MONEY |

Array type OIDs are also available (e.g., `OID_ARR_INT4`, `OID_ARR_TEXT`).

### When to Use Custom Types

1. **Automatic type detection works for most cases** - The library automatically detects types for basic Odin types
2. **Use Postgres_Type when you need:**
   - Explicit binary format for better performance
   - Custom types not directly supported (UUID, INET, geometric types)
   - Override default type mapping behavior
   - Custom serialization logic

### Performance Considerations

Binary format typically offers better performance than text format:
- Reduced parsing overhead
- Smaller data transfer size for numeric types
- Direct memory representation for many types

```odin
// Force all parameters to use binary format
all_binary := proc(query: string, args: ..any) -> (Rows, Error) {
    types := make([]pool.Postgres_Type, len(args))
    for _, i in args {
        types[i] = {format = .Binary}
    }
    defer delete(types)
    return pool.query(query, types = types, args = args)
}
```

## Error Handling

```odin
Error :: union {
    mem.Allocator_Error,
    Pool_Error,
    Query_Error,
    DB_Error,
}

// Check specific error types
rows, err := pool.query("SELECT ...")
switch e in err {
case Pool_Error:
    if e == .UnableToAcquireConnection {
        // Handle pool exhaustion
    }
case DB_Error:
    fmt.eprintln("Database error:", e.message)
case Query_Error:
    if e == .NoRows {
        // Handle empty result
    }
}
```

## Limitations

- No prepared statement support yet (code exists but not finished)
- No COPY support for bulk operations
- No LISTEN/NOTIFY support
- Limited geometric and network types
- Struct scanning doesn't support pointer fields
- Some error conditions panic instead of returning errors
- More testing/asserts
- tprint is used extensively and not really cleaned up yet
