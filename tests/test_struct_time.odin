package postgres_tests

import "core:fmt"
import "core:time"
import pool "../pool"

// Test structure with time.Time field
UserWithTime :: struct {
	id:         int       `pg:"id"`,
	email:      string    `pg:"email"`,
	created_at: time.Time `pg:"created_at"`,
}

test_struct_with_time :: proc() {
	fmt.println("\n=== Testing Struct Scanning with time.Time ===")
	
	// Create test table
	pool.exec("DROP TABLE IF EXISTS test_users_time")
	_, err := pool.exec(`
		CREATE TABLE test_users_time (
			id SERIAL PRIMARY KEY,
			email TEXT NOT NULL,
			created_at TIMESTAMP NOT NULL DEFAULT NOW()
		)
	`)
	if err != nil {
		fmt.eprintln("Failed to create table:", err)
		return
	}
	defer pool.exec("DROP TABLE test_users_time")
	
	// Insert test data
	_, insert_err := pool.exec(
		"INSERT INTO test_users_time (email, created_at) VALUES ($1, $2)",
		args = {"test@example.com", "2025-01-15 14:30:00"},
	)
	if insert_err != nil {
		fmt.eprintln("Failed to insert:", insert_err)
		return
	}
	
	// Try manual scanning first to verify time.Time works
	fmt.println("\nManual scanning test:")
	manual_rows, manual_err := pool.query("SELECT id, email, created_at FROM test_users_time")
	if manual_err != nil {
		fmt.eprintln("Failed to query:", manual_err)
		return
	}
	defer pool.release_query(&manual_rows)
	
	if pool.next_row(&manual_rows) {
		id, _ := pool.scan(&manual_rows, int, 0)
		email, _ := pool.scan(&manual_rows, string, 1)
		created_at, time_err := pool.scan(&manual_rows, time.Time, 2)
		defer delete(email)
		
		if time_err != nil {
			fmt.eprintln("Failed to scan time.Time:", time_err)
		} else {
			year, month, day := time.date(created_at)
			hour, min, sec := time.clock(created_at)
			fmt.printf("Manual scan: id=%d, email=%s, created_at=%04d-%02d-%02d %02d:%02d:%02d\n",
				id, email, year, int(month), day, hour, min, sec)
		}
	}
	
	// Now try struct scanning
	fmt.println("\nStruct scanning test:")
	struct_rows, struct_err := pool.query("SELECT id, email, created_at FROM test_users_time")
	if struct_err != nil {
		fmt.eprintln("Failed to query for struct scan:", struct_err)
		return
	}
	defer pool.release_query(&struct_rows)
	
	if pool.next_row(&struct_rows) {
		// This might fail if time.Time isn't supported in scan_into
		user := pool.scan_into(&struct_rows, UserWithTime)
		defer delete(user.email)
		
		year, month, day := time.date(user.created_at)
		hour, min, sec := time.clock(user.created_at)
		fmt.printf("Struct scan: id=%d, email=%s, created_at=%04d-%02d-%02d %02d:%02d:%02d\n",
			user.id, user.email, year, int(month), day, hour, min, sec)
	}
}

main :: proc() {
	test_struct_with_time()
}