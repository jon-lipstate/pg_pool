package postgres_tests

import "core:fmt"
import pool "../pool"

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

setup_test_tables :: proc() -> bool {
	// Drop existing tables first
	pool.exec("DROP TABLE IF EXISTS users")
	pool.exec("DROP TABLE IF EXISTS products")
	
	// Create test tables
	_, user_err := pool.exec(`
		CREATE TABLE users (
			id SERIAL PRIMARY KEY,
			email VARCHAR(255) NOT NULL,
			name VARCHAR(255),
			age INT,
			is_active BOOLEAN DEFAULT true,
			created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
		)
	`)
	
	if user_err != nil {
		fmt.eprintln("Failed to create users table:", user_err)
		return false
	}
	
	_, product_err := pool.exec(`
		CREATE TABLE products (
			id SERIAL PRIMARY KEY,
			name VARCHAR(255) NOT NULL,
			price DECIMAL(10, 2),
			stock INT DEFAULT 0,
			description TEXT
		)
	`)
	
	if product_err != nil {
		fmt.eprintln("Failed to create products table:", product_err)
		return false
	}
	
	return true
}

test_basic_queries :: proc() {
	fmt.println("\n=== Testing Basic Queries ===")
	
	// Insert a test user
	affected, err := pool.exec("INSERT INTO users (email, name, age) VALUES ($1, $2, $3)", args = {"alice@example.com", "Alice", 30})
	if err != nil {
		fmt.eprintln("Failed to insert user:", err)
		return
	}
	
	fmt.printf("Inserted %v user(s)\n", affected)
	
	// Query the user back
	rows, query_err := pool.query("SELECT id, email, name, age FROM users WHERE email = $1", args = {"alice@example.com"})
	if query_err != nil {
		fmt.eprintln("Failed to query user:", query_err)
		return
	}
	defer pool.release_query(&rows)
	
	if pool.next_row(&rows) {
		id, _ := pool.scan(&rows, int, 0)
		email, _ := pool.scan(&rows, string, 1)
		name, _ := pool.scan(&rows, string, 2)
		age, _ := pool.scan(&rows, int, 3)
		defer delete(email)
		defer delete(name)
		
		fmt.printf("User: id=%d, email=%s, name=%s, age=%d\n", id, email, name, age)
	}
}

test_parameterized_queries :: proc() {
	fmt.println("\n=== Testing Parameterized Queries ===")
	
	// Insert a test product
	_, insert_err := pool.exec("INSERT INTO products (name, price, stock) VALUES ($1, $2, $3)", args = {"TestProduct", 99.99, 10})
	if insert_err != nil {
		fmt.eprintln("Failed to insert product:", insert_err)
		return
	}
	fmt.println("Successfully inserted test product")
	
	// Add some more test data
	pool.exec("INSERT INTO products (name, price, stock) VALUES ($1, $2, $3)", args = {"Laptop", 999.99, 10})
	pool.exec("INSERT INTO products (name, price, stock) VALUES ($1, $2, $3)", args = {"Mouse", 29.99, 100})
	pool.exec("INSERT INTO products (name, price, stock) VALUES ($1, $2, $3)", args = {"Keyboard", 79.99, 50})
	
	// Query all products to verify they exist
	all_rows, all_err := pool.query("SELECT id, name, price, stock FROM products ORDER BY id")
	if all_err != nil {
		fmt.eprintln("Failed to query all products:", all_err)
		return
	}
	defer pool.release_query(&all_rows)
	
	fmt.println("\nActual products in database:")
	for pool.next_row(&all_rows) {
		id, _ := pool.scan(&all_rows, int, 0)
		name, _ := pool.scan(&all_rows, string, 1)
		price, _ := pool.scan(&all_rows, f64, 2)
		stock, _ := pool.scan(&all_rows, int, 3)
		defer delete(name)
		
		fmt.printf("  id=%d, name=%s, price=%.2f, stock=%d\n", id, name, price, stock)
	}
	
	// Query products under $100
	rows, query_err := pool.query("SELECT name, price FROM products WHERE price < $1 ORDER BY price", args = {100.00})
	if query_err != nil {
		fmt.eprintln("Failed to query products:", query_err)
		return
	}
	defer pool.release_query(&rows)
	
	fmt.println("Products under $100:")
	for pool.next_row(&rows) {
		name, _ := pool.scan(&rows, string, 0)
		price, _ := pool.scan(&rows, f64, 1)
		defer delete(name)
		
		fmt.printf("  - %s: $%.2f\n", name, price)
	}
}

test_null_handling :: proc() {
	fmt.println("\n=== Testing NULL Handling ===")
	
	// Insert users with NULL values
	pool.exec("INSERT INTO users (email, name, age) VALUES ($1, $2, $3)", args = {"bob@example.com", "Bob", nil})
	pool.exec("INSERT INTO users (email, name, age) VALUES ($1, $2, $3)", args = {"carol@example.com", "Carol", 25})
	
	// Also test products with NULL description  
	pool.exec("INSERT INTO products (name, price, stock, description) VALUES ($1, $2, $3, $4)", args = {"NullProduct", 10.00, 5, nil})
	
	// Query users and handle NULL age
	rows, err := pool.query("SELECT name, age FROM users WHERE email IN ($1, $2) ORDER BY name", args = {"bob@example.com", "carol@example.com"})
	if err != nil {
		fmt.eprintln("Failed to query users:", err)
		return
	}
	defer pool.release_query(&rows)
	
	fmt.println("Users with auto-detected NULL:")
	for pool.next_row(&rows) {
		name, _ := pool.scan(&rows, string, 0)
		age, age_err := pool.scan(&rows, int, 1)
		defer delete(name)
		
		if age_err == pool.QueryError.UnexpectedNullValue {
			fmt.printf("  %s has NULL age\n", name)
		} else {
			fmt.printf("  %s is %d years old\n", name, age)
		}
	}
	
	// Query product description (may be NULL)
	prod_rows, prod_err := pool.query("SELECT description FROM products WHERE name = $1", args = {"NullProduct"})
	if prod_err != nil {
		fmt.eprintln("Failed to query product:", prod_err)
		return
	}
	defer pool.release_query(&prod_rows)
	
	if pool.next_row(&prod_rows) {
		desc, desc_err := pool.scan(&prod_rows, string, 0)
		defer delete(desc)
		
		if desc_err == pool.QueryError.UnexpectedNullValue {
			fmt.println("  NullProduct description: NULL")
		} else {
			fmt.printf("  NullProduct description: %s\n", desc)
		}
	}
}

main :: proc() {
	// Initialize database connection first
	if !setup_test_tables() {
		return
	}
	
	test_basic_queries()
	test_parameterized_queries()
	test_null_handling()
}