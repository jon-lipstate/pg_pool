package postgres

import pq "./vendor/odin-postgresql"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
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
	_, err := pool.exec(`
		CREATE TABLE test_custom (
			id SERIAL PRIMARY KEY,
			uuid_field UUID,
			json_field JSONB
		)
	`)
	if err != nil {
		fmt.eprintln("Failed to create custom types table:", err)
		return
	}
	
	// Define a custom UUID type handler
	// UUID is stored as 16 bytes in binary format
	uuid_type := pool.Postgres_Type{
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
