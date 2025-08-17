package postgres_tests

import pool "../pool"
import "core:fmt"
import "core:time"

// Test structures with pg tags for database column mapping
User :: struct {
	id:         int `pg:"id"`,
	email:      string `pg:"email"`,
	full_name:  string `pg:"name"`, // Struct field differs from DB column
	age:        int `pg:"age"`,
	active:     bool `pg:"is_active"`, // Struct field differs from DB column
	created_at: time.Time `pg:"created_at"`,
}

Product :: struct {
	product_id:   int `pg:"id"`, // Struct field differs from DB column
	product_name: string `pg:"name"`, // Struct field differs from DB column  
	price:        f64 `pg:"price"`,
	stock_count:  int `pg:"stock"`, // Struct field differs from DB column
	desc:         string `pg:"description"`, // Struct field differs from DB column
}

test_struct_scanning :: proc() {
	fmt.println("\n=== Testing Struct Scanning ===")

	// Test automatic struct scanning with pg tags
	rows, err := pool.query(
		"SELECT id, email, name, age, is_active, created_at FROM users WHERE email = $1",
		args = {"alice@example.com"},
	)
	if err != nil {
		fmt.eprintln("Failed to query user for struct scan:", err)
		return
	}
	defer pool.release_query(&rows)

	if pool.next_row(&rows) {
		user := pool.scan_into(&rows, User)
		year, month, day := time.date(user.created_at)
		hour, min, sec := time.clock(user.created_at)
		fmt.printf(
			"Struct scan: User{id=%d, email=%s, full_name=%s, age=%d, active=%t, created=%04d-%02d-%02d %02d:%02d:%02d}\n",
			user.id,
			user.email,
			user.full_name,
			user.age,
			user.active,
			year,
			int(month),
			day,
			hour,
			min,
			sec,
		)
		defer delete(user.email)
		defer delete(user.full_name)
	}

	// Test struct scanning with products
	prod_rows, prod_err := pool.query(
		"SELECT id, name, price, stock, description FROM products ORDER BY id",
	)
	if prod_err != nil {
		fmt.eprintln("Failed to query products for struct scan:", prod_err)
		return
	}
	defer pool.release_query(&prod_rows)

	fmt.println("Products from struct scan:")
	for pool.next_row(&prod_rows) {
		product := pool.scan_into(&prod_rows, Product)
		fmt.printf(
			"  Product{id=%d, name=%s, price=%.2f, stock=%d, desc=%s}\n",
			product.product_id,
			product.product_name,
			product.price,
			product.stock_count,
			product.desc,
		)
		defer delete(product.product_name)
		defer delete(product.desc)
	}
}

main :: proc() {
	test_struct_scanning()
}
