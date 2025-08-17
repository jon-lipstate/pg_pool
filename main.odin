package postgres

import pq "./vendor/odin-postgresql"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "env"
import "pool"

PRINT_TRACKING :: true

main :: proc() {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	context.allocator = mem.tracking_allocator(&tracker)
	_main()

	if PRINT_TRACKING && len(tracker.allocation_map) > 0 {
		fmt.println()
		for _, v in tracker.allocation_map {
			fmt.printf("%v Leaked %v bytes.\n", v.location, v.size)
		}
	} else {
		if PRINT_TRACKING {fmt.println("Hooray! no memory leaks")}
	}
}

// Test structures with pg tags for database column mapping
User :: struct {
	id:         int `pg:"id"`,
	email:      string `pg:"email"`,
	full_name:  string `pg:"name"`, // Struct field differs from DB column
	age:        int `pg:"age"`,
	active:     bool `pg:"is_active"`, // Struct field differs from DB column
	created_at: string `pg:"created_at"`,
}

Product :: struct {
	product_id:   int `pg:"id"`, // Struct field differs from DB column
	product_name: string `pg:"name"`, // Struct field differs from DB column  
	price:        f64 `pg:"price"`,
	stock_count:  int `pg:"stock"`, // Struct field differs from DB column
	desc:         string `pg:"description"`, // Struct field differs from DB column
}

_main :: proc() {
	if !env.set() {panic("Failed to read .env file, aborting.")}
	url := os.get_env("DATABASE_URL")
	defer delete(url)

	// Initialize pool
	err := pool.init(url, min_connections = 1, max_connections = 4)
	if err != nil {
		fmt.eprintln("Failed to initialize pool:", err)
		return
	}
	defer pool.destroy_pool()

	fmt.println("Connected to database!")

	// Create test tables
	if !setup_test_tables() {
		fmt.eprintln("Failed to setup test tables")
		return
	}

	// Run tests
	test_basic_queries()
	test_parameterized_queries()
	test_null_handling()
	test_transactions()
	test_struct_scanning()
	test_custom_types()
	test_binary_format()
	test_type_safety()
	test_pool_stats()
}

setup_test_tables :: proc() -> bool {
	fmt.println("\n=== Setting up test tables ===")

	// Drop existing tables
	pool.exec("DROP TABLE IF EXISTS test_users CASCADE")
	pool.exec("DROP TABLE IF EXISTS test_products CASCADE")

	// Create users table
	_, err := pool.exec(
		`
		CREATE TABLE test_users (
			id SERIAL PRIMARY KEY,
			email VARCHAR(255) UNIQUE NOT NULL,
			name VARCHAR(255) NOT NULL,
			age INT,
			is_active BOOLEAN DEFAULT true,
			created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
		);
	`,
	)
	if err != nil {
		fmt.eprintln("Failed to create users table:", err)
		return false
	}

	// Create products table
	_, err = pool.exec(
		`
		CREATE TABLE test_products (
			id SERIAL PRIMARY KEY,
			name VARCHAR(255) NOT NULL,
			price DECIMAL(10,2) NOT NULL,
			stock INT DEFAULT 0,
			description TEXT
		);
	`,
	)
	if err != nil {
		fmt.eprintln("Failed to create products table:", err)
		return false
	}

	fmt.println("Tables created successfully")
	return true
}

test_basic_queries :: proc() {
	fmt.println("\n=== Testing Basic Queries ===")

	// Insert a user
	affected, err := pool.exec(
		"INSERT INTO test_users (email, name, age) VALUES ($1, $2, $3)",
		args = {"alice@example.com", "Alice", 30},
	)
	if err != nil {
		fmt.eprintln("Failed to insert user:", err)
		return
	}
	fmt.printf("Inserted %d user(s)\n", affected)

	// Query the user back
	rows, err2 := pool.query(
		"SELECT id, email, name, age FROM test_users WHERE email = $1",
		args = {"alice@example.com"},
	)
	defer pool.release_query(&rows)
	assert(err2 == nil)

	if pool.next_row(&rows) {
		id, _ := pool.scan(&rows, int, 0)
		email, _ := pool.scan(&rows, string, 1)
		name, _ := pool.scan(&rows, string, 2)
		age, _ := pool.scan(&rows, int, 3)

		fmt.printf("User: id=%d, email=%s, name=%s, age=%d\n", id, email, name, age)
		delete(email)
		delete(name)
	}
}

test_parameterized_queries :: proc() {
	fmt.println("\n=== Testing Parameterized Queries ===")

	// Test simple string insert first
	_, err := pool.exec(
		"INSERT INTO test_products (name, price, stock, description) VALUES ($1, $2, $3, $4)",
		args = {"TestProduct", 99.99, 10, "desc"},
	)
	if err != nil {
		fmt.eprintln("Failed to insert test product:", err)
		return
	}
	fmt.println("Successfully inserted test product")

	// Insert multiple products
	products := []struct {
		name:  string,
		price: f64,
		stock: int,
	}{{"Laptop", 999.99, 10}, {"Mouse", 29.99, 100}, {"Keyboard", 79.99, 50}}

	for p in products {
		_, err := pool.exec(
			"INSERT INTO test_products (name, price, stock) VALUES ($1, $2, $3)",
			args = {p.name, p.price, p.stock},
		)
		if err != nil {
			fmt.eprintln("Failed to insert product", p.name, ":", err)
		}
	}

	// First check what we actually inserted
	check_rows, _ := pool.query("SELECT id, name, price, stock FROM test_products ORDER BY id")
	defer pool.release_query(&check_rows)
	fmt.println("\nActual products in database:")
	for pool.next_row(&check_rows) {
		id, _ := pool.scan(&check_rows, int, 0)
		name, _ := pool.scan(&check_rows, string, 1)
		price, _ := pool.scan(&check_rows, f64, 2)
		stock, _ := pool.scan(&check_rows, int, 3)
		fmt.printf("  id=%d, name=%s, price=%.2f, stock=%d\n", id, name, price, stock)
		delete(name)
	}

	// Query products with price filter
	rows, _ := pool.query(
		"SELECT name, price FROM test_products WHERE price < $1 ORDER BY price",
		args = {100.0},
	)
	defer pool.release_query(&rows)

	fmt.println("Products under $100:")
	for pool.next_row(&rows) {
		name, _ := pool.scan(&rows, string, 0)
		price, _ := pool.scan(&rows, f64, 1)
		fmt.printf("  - %s: $%.2f\n", name, price)
		delete(name)
	}
}

test_null_handling :: proc() {
	fmt.println("\n=== Testing NULL Handling ===")

	// Test auto-detection of NULL for nil pointer
	age_ptr: ^int = nil // nil pointer
	age_value := 25
	age_ptr_valid := &age_value

	// Insert user with NULL age using nil pointer
	pool.exec(
		"INSERT INTO test_users (email, name, age) VALUES ($1, $2, $3)",
		args = {"bob@example.com", "Bob", age_ptr}, // nil pointer = NULL
	)

	// Insert user with valid age using pointer
	pool.exec(
		"INSERT INTO test_users (email, name, age) VALUES ($1, $2, $3)",
		args = {"carol@example.com", "Carol", age_ptr_valid}, // non-nil pointer
	)

	// Test nil slice = NULL
	tags: []string = nil // nil slice
	pool.exec(
		"INSERT INTO test_products (name, price, stock, description) VALUES ($1, $2, $3, $4)",
		args = {"NullProduct", 10.0, 5, tags}, // nil slice = NULL
	)

	// Query back and verify
	rows, _ := pool.query(
		"SELECT name, age FROM test_users WHERE email IN ($1, $2) ORDER BY name",
		args = {"bob@example.com", "carol@example.com"},
	)
	defer pool.release_query(&rows)

	fmt.println("Users with auto-detected NULL:")
	for pool.next_row(&rows) {
		name, _ := pool.scan(&rows, string, 0)
		age, age_err := pool.scan(&rows, int, 1)

		if age_err == .UnexpectedNullValue {
			fmt.printf("  %s has NULL age\n", name)
		} else {
			fmt.printf("  %s is %d years old\n", name, age)
		}
		delete(name)
	}

	// Check the product with NULL description
	rows2, _ := pool.query(
		"SELECT name, description FROM test_products WHERE name = $1",
		args = {"NullProduct"},
	)
	defer pool.release_query(&rows2)

	if pool.next_row(&rows2) {
		prod_name, _ := pool.scan(&rows2, string, 0)
		desc, desc_err := pool.scan(&rows2, string, 1)

		if desc_err == .UnexpectedNullValue {
			fmt.printf("  %s has NULL description\n", prod_name)
		} else {
			fmt.printf("  %s description: %s\n", prod_name, desc)
			delete(desc)
		}
		delete(prod_name)
	}
}

test_transactions :: proc() {
	fmt.println("\n=== Testing Transactions ===")

	// Test basic transaction
	tx, err := pool.begin()
	if err != nil {
		fmt.eprintln("Failed to begin transaction:", err)
		return
	}
	defer pool.rollback(tx) // Safety net - no-op if committed

	// Check current stock
	rows, _ := pool.query(
		"SELECT name, stock FROM test_products WHERE name = $1",
		tx, // Use transaction connection
		args = {"Laptop"},
	)
	defer pool.release_query(&rows)

	if pool.next_row(&rows) {
		name, _ := pool.scan(&rows, string, 0)
		defer delete(name)
		stock, _ := pool.scan(&rows, int, 1)
		fmt.printf("Current stock for %s: %d\n", name, stock)

		// Update stock within transaction
		pool.exec(
			"UPDATE test_products SET stock = stock - $1 WHERE name = $2",
			tx, // Use transaction connection
			args = {2, "Laptop"},
		)

		// Check new stock within same transaction
		rows2, _ := pool.query(
			"SELECT stock FROM test_products WHERE name = $1",
			tx, // Use transaction connection
			args = {"Laptop"},
		)
		defer pool.release_query(&rows2)
		if pool.next_row(&rows2) {
			new_stock, _ := pool.scan(&rows2, int, 0)
			fmt.printf("New stock (in tx): %d\n", new_stock)
		}
	}

	// Commit the transaction
	if err := pool.commit(tx); err != nil {
		fmt.eprintln("Failed to commit:", err)
		return
	}
	fmt.println("Transaction committed successfully")

	// Test nested transactions with savepoints
	test_nested_transactions()
}

test_nested_transactions :: proc() {
	fmt.println("\n=== Testing Nested Transactions (Savepoints) ===")

	// Start outer transaction
	tx1, err := pool.begin()
	if err != nil {
		fmt.eprintln("Failed to begin transaction:", err)
		return
	}
	defer pool.rollback(tx1)

	// Insert a new user in outer transaction
	pool.exec(
		"INSERT INTO test_users (email, name, age) VALUES ($1, $2, $3)",
		tx1,
		args = {"charlie@example.com", "Charlie", 35},
	)
	fmt.println("Inserted Charlie in outer transaction")

	// Start nested transaction (savepoint)
	tx2, err2 := pool.begin(tx1)
	if err2 != nil {
		fmt.eprintln("Failed to create savepoint:", err2)
		return
	}

	// Insert another user in nested transaction
	pool.exec(
		"INSERT INTO test_users (email, name, age) VALUES ($1, $2, $3)",
		tx2,
		args = {"david@example.com", "David", 40},
	)
	fmt.println("Inserted David in nested transaction")

	// Rollback nested transaction (David should be rolled back)
	pool.rollback(tx2)
	fmt.println("Rolled back nested transaction (David)")

	// Charlie should still be there, commit outer transaction
	pool.commit(tx1)
	fmt.println("Committed outer transaction (Charlie)")

	// Verify results
	rows, _ := pool.query(
		"SELECT name FROM test_users WHERE email IN ($1, $2) ORDER BY name",
		args = {"charlie@example.com", "david@example.com"},
	)
	defer pool.release_query(&rows)

	fmt.println("Users after nested transaction test:")
	for pool.next_row(&rows) {
		name, _ := pool.scan(&rows, string, 0)
		fmt.printf("  - %s\n", name)
		delete(name)
	}
}

test_struct_scanning :: proc() {
	fmt.println("\n=== Testing Struct Scanning ===")

	// Query user into struct
	user, err := pool.query_row_into(
		"SELECT id, email, name, age, is_active FROM test_users WHERE email = $1",
		User,
		nil, // No specific connection, will acquire from pool
		args = {"alice@example.com"},
	)

	if err == nil {
		fmt.printf(
			"Struct scan: User{{id=%d, email=%s, full_name=%s, age=%d, active=%v}}\n",
			user.id,
			user.email,
			user.full_name,
			user.age,
			user.active,
		)
		delete(user.email)
		delete(user.full_name)
		delete(user.created_at)
	} else {
		fmt.println("Failed to scan into struct:", err)
	}

	// Test with products
	rows, _ := pool.query(
		"SELECT id, name, price, stock, description FROM test_products ORDER BY id",
	)
	defer pool.release_query(&rows)

	fmt.println("Products from struct scan:")
	for pool.next_row(&rows) {
		product := pool.scan_into(&rows, Product)
		fmt.printf(
			"  Product{{id=%d, name=%s, price=%.2f, stock=%d, desc=%s}}\n",
			product.product_id,
			product.product_name,
			product.price,
			product.stock_count,
			product.desc,
		)
		delete(product.product_name)
		if product.desc != "" {
			delete(product.desc)
		}

	}
}

test_custom_types :: proc() {
	fmt.println("\n=== Testing Custom Types ===")

	// Create a table with UUID column
	pool.exec("DROP TABLE IF EXISTS test_custom")
	_, err := pool.exec(
		`
		CREATE TABLE test_custom (
			id SERIAL PRIMARY KEY,
			uuid_field UUID,
			json_field JSONB
		)
	`,
	)
	if err != nil {
		fmt.eprintln("Failed to create custom types table:", err)
		return
	}

	// Define a custom UUID type handler
	// UUID is stored as 16 bytes in binary format
	uuid_type := pool.Postgres_Type {
		oid = 2950, // UUID OID
		format = .Text, // Use text format for simplicity
		writer = proc(buf: ^[dynamic]byte, arg: any, format: pq.Format) -> (size: i32) {
			// Expect a string UUID like "550e8400-e29b-41d4-a716-446655440000"
			uuid_str := arg.(string)
			p_bytes := transmute([]byte)uuid_str
			append(buf, ..p_bytes)
			append(buf, 0) // null terminator for text format
			return i32(len(uuid_str))
		},
		reader = nil, // Not needed for this test
	}

	// Test inserting with custom type
	test_uuid := "550e8400-e29b-41d4-a716-446655440000"
	_, err2 := pool.exec(
		"INSERT INTO test_custom (uuid_field) VALUES ($1)",
		types = {uuid_type},
		args = {test_uuid},
	)
	if err2 != nil {
		fmt.eprintln("Failed to insert with custom type:", err2)
		return
	}

	fmt.println("Successfully inserted UUID with custom type handler")

	// Query it back
	rows, _ := pool.query("SELECT uuid_field FROM test_custom")
	defer pool.release_query(&rows)

	if pool.next_row(&rows) {
		uuid_result, _ := pool.scan(&rows, string, 0)
		defer delete(uuid_result)
		fmt.printf("Retrieved UUID: %s\n", uuid_result)

		if uuid_result == test_uuid {
			fmt.println("Custom type round-trip successful!")
		} else {
			fmt.println("UUID mismatch!")
		}
	}

	// Example: Binary format custom type could be added for POINT, INET, etc.
	// point_type := pool.Postgres_Type{
	//     oid = 600,  // POINT OID
	//     format = .Binary,
	//     writer = proc(buf: ^[dynamic]byte, arg: any, format: pq.Format) -> (size: i32) {
	//         point := arg.([2]f64)
	//         // Write two float64 in network byte order
	//         ...
	//     },
	// }
	fmt.println("Custom type handlers allow extending supported PostgreSQL types")

	// Clean up
	pool.exec("DROP TABLE test_custom")
}

test_binary_format :: proc() {
	fmt.println("\n=== Testing Binary Format ===")

	fmt.println("Dropping existing table...")
	// Create a table with various types
	_, drop_err := pool.exec("DROP TABLE IF EXISTS test_binary")
	if drop_err != nil {
		fmt.eprintln("Warning: Failed to drop table:", drop_err)
	}

	fmt.println("Creating test table...")
	_, err := pool.exec(
		`
		CREATE TABLE test_binary (
			id SERIAL PRIMARY KEY,
			bool_val BOOLEAN,
			int2_val SMALLINT,
			int4_val INTEGER,
			int8_val BIGINT,
			float4_val REAL,
			float8_val DOUBLE PRECISION,
			text_val TEXT,
			bytea_val BYTEA,
			date_val DATE,
			timestamp_val TIMESTAMP,
			json_val JSONB
		)
	`,
	)
	if err != nil {
		fmt.eprintln("Failed to create binary test table:", err)
		return
	}
	fmt.println("Table created successfully")

	// Test data
	fmt.println("Preparing test data...")
	// Create specific dates/times for testing
	test_date, date_ok := time.components_to_time(2025, 1, 15, 0, 0, 0, 0)
	if !date_ok {
		fmt.eprintln("Failed to create test date")
		test_date = time.Time{}
	}
	test_timestamp, ts_ok := time.components_to_time(2025, 1, 15, 14, 30, 45, 123456789)
	if !ts_ok {
		fmt.eprintln("Failed to create test timestamp")
		test_timestamp = time.Time{}
	}

	// Debug: print what we actually created
	d_year, d_month, d_day := time.date(test_date)
	fmt.printf(
		"Created test date: %04d-%02d-%02d (expected 2025-01-15)\n",
		d_year,
		int(d_month),
		d_day,
	)

	ts_year, ts_month, ts_day := time.date(test_timestamp)
	ts_hour, ts_min, ts_sec := time.clock(test_timestamp)
	fmt.printf(
		"Created test timestamp: %04d-%02d-%02d %02d:%02d:%02d (expected 2025-01-15 14:30:45)\n",
		ts_year,
		int(ts_month),
		ts_day,
		ts_hour,
		ts_min,
		ts_sec,
	)

	test_json := json.parse_string(`{"key": "value", "number": 42}`) or_else json.Value{}
	defer json.destroy_value(test_json)
	test_bytes := []byte{0xDE, 0xAD, 0xBE, 0xEF}

	fmt.println("Setting up binary types...")
	// Insert using binary format (by specifying types with Binary format)
	binary_types := []pool.Postgres_Type {
		{oid = pool.OID_BOOL, format = .Binary},
		{oid = pool.OID_INT2, format = .Binary},
		{oid = pool.OID_INT4, format = .Binary},
		{oid = pool.OID_INT8, format = .Binary},
		{oid = pool.OID_FLOAT4, format = .Binary},
		{oid = pool.OID_FLOAT8, format = .Binary},
		{oid = pool.OID_TEXT, format = .Binary},
		{oid = pool.OID_BYTEA, format = .Binary},
		{oid = pool.OID_DATE, format = .Binary},
		{oid = pool.OID_TIMESTAMP, format = .Binary},
		{oid = pool.OID_JSONB, format = .Binary},
	}

	// Insert all types at once
	fmt.println("About to insert all types with binary format...")
	_, err2 := pool.exec(
		`INSERT INTO test_binary 
		(bool_val, int2_val, int4_val, int8_val, float4_val, float8_val, text_val, bytea_val, date_val, timestamp_val, json_val)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
		types = binary_types,
		args = {
			true,
			i16(32767),
			i32(2147483647),
			i64(9223372036854775807),
			f32(3.14159),
			f64(2.71828),
			"Hello Binary!",
			test_bytes,
			test_date,
			test_timestamp,
			test_json,
		},
	)
	if err2 != nil {
		fmt.eprintln("Failed to insert with binary format:", err2)
		return
	}

	fmt.println("Successfully inserted all types in binary format")

	// First query with text format to verify data was inserted
	fmt.println("\nVerifying with text format query:")
	text_rows, text_err := pool.query(
		"SELECT bool_val, int2_val, text_val, bytea_val, json_val FROM test_binary",
		result_format = .Text,
	)
	defer pool.release_query(&text_rows)
	if text_err == nil && pool.next_row(&text_rows) {
		t_bool, _ := pool.scan(&text_rows, bool, 0)
		t_int2, _ := pool.scan(&text_rows, i16, 1)
		t_text, _ := pool.scan(&text_rows, string, 2)
		t_bytea, _ := pool.scan(&text_rows, []byte, 3)
		t_json, _ := pool.scan(&text_rows, string, 4)
		fmt.printf(
			"  Text format: bool=%v, int2=%d, text='%s', bytea=%02x, json='%s'\n",
			t_bool,
			t_int2,
			t_text,
			t_bytea,
			t_json,
		)
		delete(t_text)
		delete(t_bytea)
		delete(t_json)
	}

	// Query back with binary format (now the default) - all columns
	fmt.println("\nNow querying with binary format (all columns):")
	rows, err3 := pool.query("SELECT * FROM test_binary")
	defer pool.release_query(&rows)
	if err3 != nil {
		fmt.eprintln("Failed to query with binary format:", err3)
		return
	}

	if pool.next_row(&rows) {
		id, _ := pool.scan(&rows, int, 0)
		bool_val, _ := pool.scan(&rows, bool, 1)
		int2_val, _ := pool.scan(&rows, i16, 2)
		int4_val, _ := pool.scan(&rows, i32, 3)
		int8_val, _ := pool.scan(&rows, i64, 4)
		float4_val, _ := pool.scan(&rows, f32, 5)
		float8_val, _ := pool.scan(&rows, f64, 6)
		text_val, _ := pool.scan(&rows, string, 7)
		bytea_val, _ := pool.scan(&rows, []byte, 8)
		date_val, _ := pool.scan(&rows, time.Time, 9)
		timestamp_val, _ := pool.scan(&rows, time.Time, 10)
		json_val, _ := pool.scan(&rows, string, 11) // Read JSON as string for simplicity

		defer {
			delete(text_val)
			delete(bytea_val)
			delete(json_val)
		}

		fmt.println("Retrieved values (binary format):")
		fmt.printf("  id: %v\n", id)
		fmt.printf("  bool: %v\n", bool_val)
		fmt.printf("  int2: %v\n", int2_val)
		fmt.printf("  int4: %v\n", int4_val)
		fmt.printf("  int8: %v\n", int8_val)
		fmt.printf("  float4: %.5f\n", float4_val)
		fmt.printf("  float8: %.5f\n", float8_val)
		fmt.printf("  text: '%s'\n", text_val)
		fmt.printf("  bytea: %02x\n", bytea_val)
		// Format and display the dates
		date_year, date_month, date_day := time.date(date_val)
		fmt.printf("  date: %04d-%02d-%02d\n", date_year, int(date_month), date_day)

		ts_year, ts_month, ts_day := time.date(timestamp_val)
		ts_hour, ts_min, ts_sec := time.clock(timestamp_val)
		ts_nano := time.to_unix_nanoseconds(timestamp_val) % 1_000_000_000
		fmt.printf(
			"  timestamp: %04d-%02d-%02d %02d:%02d:%02d.%06d\n",
			ts_year,
			int(ts_month),
			ts_day,
			ts_hour,
			ts_min,
			ts_sec,
			ts_nano / 1000,
		)
		fmt.printf("  json: '%s'\n", json_val)

		// Validate
		if bool_val &&
		   int2_val == 32767 &&
		   int4_val == 2147483647 &&
		   int8_val == 9223372036854775807 &&
		   text_val == "Hello Binary!" &&
		   len(bytea_val) == 4 &&
		   abs(float4_val - 3.14159) < 0.0001 &&
		   abs(float8_val - 2.71828) < 0.0001 {
			fmt.println("\n✅ Binary format round-trip successful! All types work correctly.")
		} else {
			fmt.println("\n❌ Binary format validation failed!")
		}
	}

	// Clean up
	pool.exec("DROP TABLE test_binary")

	// Additional date/time tests
	test_dates_and_times()
}

test_dates_and_times :: proc() {
	fmt.println("\n=== Testing Dates and Times in Detail ===")

	// First check what timezone the database is using
	tz_rows, _ := pool.query("SHOW timezone")
	defer pool.release_query(&tz_rows)
	if pool.next_row(&tz_rows) {
		tz, _ := pool.scan(&tz_rows, string, 0)
		fmt.printf("Database timezone: %s\n", tz)
		delete(tz)
	}

	// Create table for date tests
	pool.exec("DROP TABLE IF EXISTS test_dates")
	_, err := pool.exec(
		`
		CREATE TABLE test_dates (
			id SERIAL PRIMARY KEY,
			test_date DATE,
			test_timestamp TIMESTAMP,
			test_timestamptz TIMESTAMPTZ,
			description TEXT
		)
	`,
	)
	if err != nil {
		fmt.eprintln("Failed to create dates table:", err)
		return
	}

	// Test various dates
	test_cases := []struct {
		desc: string,
		date: time.Time,
		ts:   time.Time,
	} {
		{
			desc = "Year 2000 (PG epoch)",
			date = time.components_to_time(2000, 1, 1, 0, 0, 0, 0) or_else time.Time{},
			ts = time.components_to_time(2000, 1, 1, 0, 0, 0, 0) or_else time.Time{},
		},
		{
			desc = "Year 2025 mid-year",
			date = time.components_to_time(2025, 6, 15, 0, 0, 0, 0) or_else time.Time{},
			ts = time.components_to_time(2025, 6, 15, 12, 30, 45, 123456789) or_else time.Time{},
		},
		{
			desc = "Year 1999 (before epoch)",
			date = time.components_to_time(1999, 12, 31, 0, 0, 0, 0) or_else time.Time{},
			ts = time.components_to_time(1999, 12, 31, 23, 59, 59, 999999999) or_else time.Time{},
		},
		{
			desc = "Leap year date",
			date = time.components_to_time(2024, 2, 29, 0, 0, 0, 0) or_else time.Time{},
			ts = time.components_to_time(2024, 2, 29, 15, 45, 30, 0) or_else time.Time{},
		},
	}

	// Insert using binary format
	binary_types := []pool.Postgres_Type {
		{oid = pool.OID_DATE, format = .Binary},
		{oid = pool.OID_TIMESTAMP, format = .Binary},
		{oid = pool.OID_TIMESTAMPTZ, format = .Binary},
		{oid = pool.OID_TEXT, format = .Binary},
	}

	for tc in test_cases {
		_, err := pool.exec(
			`INSERT INTO test_dates (test_date, test_timestamp, test_timestamptz, description) 
			 VALUES ($1, $2, $3, $4)`,
			types = binary_types,
			args = {tc.date, tc.ts, tc.ts, tc.desc},
		)
		if err != nil {
			fmt.eprintln("Failed to insert:", tc.desc, "-", err)
		}
	}

	// Query back and verify
	fmt.println("\nQuerying dates with binary format:")
	rows, err2 := pool.query(
		"SELECT test_date, test_timestamp, test_timestamptz, description FROM test_dates ORDER BY id",
	)
	if err2 != nil {
		fmt.eprintln("Failed to query dates:", err2)
		return
	}

	for pool.next_row(&rows) {
		date_val, _ := pool.scan(&rows, time.Time, 0)
		ts_val, _ := pool.scan(&rows, time.Time, 1)
		tstz_val, _ := pool.scan(&rows, time.Time, 2)
		desc, _ := pool.scan(&rows, string, 3)

		// Format dates for display
		d_year, d_month, d_day := time.date(date_val)
		ts_year, ts_month, ts_day := time.date(ts_val)
		ts_hour, ts_min, ts_sec := time.clock(ts_val)
		ts_nano := time.to_unix_nanoseconds(ts_val) % 1_000_000_000

		fmt.printf("\n%s:\n", desc)
		fmt.printf("  Date: %04d-%02d-%02d\n", d_year, int(d_month), d_day)
		fmt.printf(
			"  Timestamp: %04d-%02d-%02d %02d:%02d:%02d.%06d\n",
			ts_year,
			int(ts_month),
			ts_day,
			ts_hour,
			ts_min,
			ts_sec,
			ts_nano / 1000,
		)
		delete(desc)
	}

	// IMPORTANT: Release the query before dropping the table
	pool.release_query(&rows)

	// Clean up
	fmt.println("\nAbout to drop test_dates table...")
	_, drop_err := pool.exec("DROP TABLE test_dates")
	if drop_err != nil {
		fmt.eprintln("Failed to drop test_dates table:", drop_err)
		return
	}
	fmt.println("test_dates table dropped successfully")

	// Simple timezone test
	fmt.println("About to call test_simple_tz()...")
	test_simple_tz()
	fmt.println("test_simple_tz() completed")
}

test_simple_tz :: proc() {
	fmt.println("\n=== Testing TIMESTAMP vs TIMESTAMPTZ (Simple) ===")

	fmt.println("About to query timezone...")
	// Check current timezone
	tz_check, tz_err := pool.query("SELECT current_setting('TIMEZONE')")
	if tz_err != nil {
		fmt.eprintln("Failed to query timezone:", tz_err)
		return
	}
	fmt.println("Got timezone result, about to scan...")
	if pool.next_row(&tz_check) {
		fmt.println("Scanning timezone value...")
		tz, scan_err := pool.scan(&tz_check, string, 0)
		if scan_err != nil {
			fmt.eprintln("Failed to scan timezone:", scan_err)
		} else {
			fmt.printf("Current timezone: %s\n", tz)
			delete(tz)
		}
	}
	// Release the query BEFORE any other operations
	pool.release_query(&tz_check)
	fmt.println("Timezone check complete")

	// Use text format for simplicity
	fmt.println("Dropping test_tz table if exists...")
	_, drop_err := pool.exec("DROP TABLE IF EXISTS test_tz")
	if drop_err != nil {
		fmt.eprintln("Failed to drop test_tz:", drop_err)
		return
	}

	fmt.println("Creating test_tz table...")
	_, create_err := pool.exec("CREATE TABLE test_tz (ts TIMESTAMP, tstz TIMESTAMPTZ)")
	if create_err != nil {
		fmt.eprintln("Failed to create test_tz:", create_err)
		return
	}

	// Insert a timestamp as text
	fmt.println("Inserting test data...")
	_, insert_err := pool.exec(
		"INSERT INTO test_tz VALUES ('2025-01-15 12:00:00', '2025-01-15 12:00:00')",
	)
	if insert_err != nil {
		fmt.eprintln("Failed to insert into test_tz:", insert_err)
		return
	}

	// Query in UTC
	fmt.println("\nWith timezone = UTC:")
	rows1, _ := pool.query("SELECT ts::text, tstz::text FROM test_tz")
	if pool.next_row(&rows1) {
		ts, _ := pool.scan(&rows1, string, 0)
		tstz, _ := pool.scan(&rows1, string, 1)
		fmt.printf("  TIMESTAMP:   %s\n", ts)
		fmt.printf("  TIMESTAMPTZ: %s\n", tstz)
		delete(ts)
		delete(tstz)
	}
	// Release the query BEFORE changing timezone
	pool.release_query(&rows1)

	// Change timezone and query again
	fmt.println("\nAbout to change timezone...")
	_, set_tz_err := pool.exec("SET TIME ZONE 'America/New_York'")
	if set_tz_err != nil {
		fmt.eprintln("Failed to set timezone:", set_tz_err)
		// Try a simpler timezone
		fmt.println("Trying 'UTC-5' instead...")
		_, set_tz_err2 := pool.exec("SET TIME ZONE 'UTC-5'")
		if set_tz_err2 != nil {
			fmt.eprintln("Failed to set UTC-5:", set_tz_err2)
			pool.exec("DROP TABLE test_tz")
			return
		}
	}

	fmt.println("Timezone changed, querying again...")
	rows2, err2 := pool.query("SELECT ts::text, tstz::text FROM test_tz")
	if err2 != nil {
		fmt.eprintln("Failed to query after timezone change:", err2)
		pool.exec("DROP TABLE test_tz")
		return
	}
	if pool.next_row(&rows2) {
		ts, _ := pool.scan(&rows2, string, 0)
		tstz, _ := pool.scan(&rows2, string, 1)
		fmt.printf("  TIMESTAMP:   %s (no change)\n", ts)
		fmt.printf("  TIMESTAMPTZ: %s (adjusted)\n", tstz)
		delete(ts)
		delete(tstz)
	}
	// Release query BEFORE resetting timezone
	pool.release_query(&rows2)

	fmt.println("\nResetting timezone...")
	// Reset
	pool.exec("SET TIME ZONE 'UTC'")
	pool.exec("DROP TABLE test_tz")
	fmt.println("Timezone test complete")
}

test_timezone_handling :: proc() {
	fmt.println("\n=== Testing TIMESTAMP vs TIMESTAMPTZ ===")

	// Create a test table
	pool.exec("DROP TABLE IF EXISTS test_tz")
	_, err := pool.exec(
		`
		CREATE TABLE test_tz (
			id SERIAL PRIMARY KEY,
			ts TIMESTAMP,
			tstz TIMESTAMPTZ
		)
	`,
	)
	if err != nil {
		fmt.eprintln("Failed to create test_tz table:", err)
		return
	}

	// Create a specific time: 2025-01-15 12:00:00
	test_time, _ := time.components_to_time(2025, 1, 15, 12, 0, 0, 0)

	fmt.println("\nInserting the same time value into both TIMESTAMP and TIMESTAMPTZ columns...")
	year, month, day := time.date(test_time)
	hour, min, sec := time.clock(test_time)
	fmt.printf(
		"Inserting time: %04d-%02d-%02d %02d:%02d:%02d\n",
		year,
		int(month),
		day,
		hour,
		min,
		sec,
	)

	// Insert using binary format
	binary_types := []pool.Postgres_Type {
		{oid = pool.OID_TIMESTAMP, format = .Binary},
		{oid = pool.OID_TIMESTAMPTZ, format = .Binary},
	}

	_, err2 := pool.exec(
		"INSERT INTO test_tz (ts, tstz) VALUES ($1, $2)",
		types = binary_types,
		args = {test_time, test_time},
	)
	if err2 != nil {
		fmt.eprintln("Failed to insert:", err2)
		return
	}

	// Query back with text format to see what PostgreSQL shows
	fmt.println("\nQuerying back with TEXT format:")
	text_rows, _ := pool.query("SELECT ts, tstz FROM test_tz", result_format = .Text)
	defer pool.release_query(&text_rows)
	if pool.next_row(&text_rows) {
		ts_text, _ := pool.scan(&text_rows, string, 0)
		tstz_text, _ := pool.scan(&text_rows, string, 1)
		fmt.printf("  TIMESTAMP:   %s\n", ts_text)
		fmt.printf("  TIMESTAMPTZ: %s\n", tstz_text)
		delete(ts_text)
		delete(tstz_text)
	}

	// Query back with binary format
	fmt.println("\nQuerying back with BINARY format:")
	binary_rows, _ := pool.query("SELECT ts, tstz FROM test_tz")
	defer pool.release_query(&binary_rows)
	if pool.next_row(&binary_rows) {
		ts_val, _ := pool.scan(&binary_rows, time.Time, 0)
		tstz_val, _ := pool.scan(&binary_rows, time.Time, 1)

		ts_year, ts_month, ts_day := time.date(ts_val)
		ts_hour, ts_min, ts_sec := time.clock(ts_val)
		fmt.printf(
			"  TIMESTAMP:   %04d-%02d-%02d %02d:%02d:%02d\n",
			ts_year,
			int(ts_month),
			ts_day,
			ts_hour,
			ts_min,
			ts_sec,
		)

		tstz_year, tstz_month, tstz_day := time.date(tstz_val)
		tstz_hour, tstz_min, tstz_sec := time.clock(tstz_val)
		fmt.printf(
			"  TIMESTAMPTZ: %04d-%02d-%02d %02d:%02d:%02d\n",
			tstz_year,
			int(tstz_month),
			tstz_day,
			tstz_hour,
			tstz_min,
			tstz_sec,
		)
	}

	// Test with different timezone
	fmt.println("\nChanging session timezone to 'America/New_York' (UTC-5):")
	pool.exec("SET TIME ZONE 'America/New_York'")

	text_rows2, _ := pool.query("SELECT ts, tstz FROM test_tz", result_format = .Text)
	defer pool.release_query(&text_rows2)
	if pool.next_row(&text_rows2) {
		ts_text, _ := pool.scan(&text_rows2, string, 0)
		tstz_text, _ := pool.scan(&text_rows2, string, 1)
		fmt.printf("  TIMESTAMP:   %s (unchanged)\n", ts_text)
		fmt.printf("  TIMESTAMPTZ: %s (adjusted for timezone)\n", tstz_text)
		delete(ts_text)
		delete(tstz_text)
	}

	// Reset timezone
	pool.exec("SET TIME ZONE 'UTC'")

	// Clean up
	pool.exec("DROP TABLE test_tz")
}

test_pool_stats :: proc() {
	fmt.println("\n=== Testing Pool Statistics ===")

	stats := pool.get_pool_stats()
	fmt.println("Pool Statistics:")
	fmt.printf("  Active connections: %d\n", stats.active_connections)
	fmt.printf("  Idle connections: %d\n", stats.idle_connections)
	fmt.printf("  Total connections: %d\n", stats.total_connections)
	fmt.printf(
		"  Peak memory used: %d bytes (%d KB)\n",
		stats.peak_memory_used,
		stats.peak_memory_used / 1024,
	)
	fmt.printf(
		"  Average query memory: %d bytes (%d KB)\n",
		stats.avg_last_used,
		stats.avg_last_used / 1024,
	)
	fmt.printf(
		"  Total memory allocated: %d bytes (%d KB)\n",
		stats.total_memory,
		stats.total_memory / 1024,
	)
}
