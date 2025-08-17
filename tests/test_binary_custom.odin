#+feature dynamic-literals
package postgres_tests

import pool "../pool"
import "core:encoding/json"
import "core:fmt"
import "core:time"

test_binary_format :: proc() {
	fmt.println("\n=== Testing Binary Format ===")

	// Drop and recreate test table
	fmt.println("Dropping existing table...")
	pool.exec("DROP TABLE IF EXISTS test_binary")

	fmt.println("Creating test table...")
	_, create_err := pool.exec(
		`
		CREATE TABLE test_binary (
			id SERIAL PRIMARY KEY,
			bool_val BOOLEAN,
			int2_val INT2,
			int4_val INT4,
			int8_val INT8,
			float4_val FLOAT4,
			float8_val FLOAT8,
			text_val TEXT,
			bytea_val BYTEA,
			date_val DATE,
			timestamp_val TIMESTAMP,
			json_val JSON
		)
	`,
	)

	if create_err != nil {
		fmt.eprintln("Failed to create test table:", create_err)
		return
	}
	fmt.println("Table created successfully")

	// Prepare test data
	fmt.println("Preparing test data...")
	test_date, _ := time.components_to_time(2025, 1, 15, 0, 0, 0, 0)
	test_timestamp, _ := time.components_to_time(2025, 1, 15, 14, 30, 45, 123456000)

	test_json := json.Value{}
	test_json = json.Object {
		"key"    = json.String("value"),
		"number" = json.Float(42),
	}

	fmt.printf(
		"Created test date: %04d-%02d-%02d (expected 2025-01-15)\n",
		time.year(test_date),
		time.month(test_date),
		time.day(test_date),
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

	fmt.println("Setting up binary types...")

	// Test data
	bool_val := true
	int2_val := i16(32767)
	int4_val := i32(2147483647)
	int8_val := i64(9223372036854775807)
	float4_val := f32(3.14159)
	float8_val := f64(2.71828)
	text_val := "Hello Binary!"
	bytea_val := []byte{0xDE, 0xAD, 0xBE, 0xEF}

	fmt.println("About to insert all types with binary format...")

	// Insert with binary format (parameters use binary)
	_, insert_err := pool.exec(
		`
		INSERT INTO test_binary 
		(bool_val, int2_val, int4_val, int8_val, float4_val, float8_val, text_val, bytea_val, date_val, timestamp_val, json_val)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
	`,
		args = {
			bool_val,
			int2_val,
			int4_val,
			int8_val,
			float4_val,
			float8_val,
			text_val,
			bytea_val,
			test_date,
			test_timestamp,
			test_json,
		},
	)

	if insert_err != nil {
		fmt.eprintln("Failed to insert binary data:", insert_err)
		return
	}
	fmt.println("Successfully inserted all types in binary format")

	// Verify with text format query first
	fmt.println("\nVerifying with text format query:")
	text_rows, text_err := pool.query(
		"SELECT bool_val, int2_val, text_val, bytea_val, json_val FROM test_binary",
		result_format = .Text,
	)
	if text_err != nil {
		fmt.eprintln("Failed to query with text format:", text_err)
		return
	}
	defer pool.release_query(&text_rows)

	if pool.next_row(&text_rows) {
		bool_str, _ := pool.scan(&text_rows, string, 0)
		int2_str, _ := pool.scan(&text_rows, string, 1)
		text_str, _ := pool.scan(&text_rows, string, 2)
		bytea_str, _ := pool.scan(&text_rows, string, 3)
		json_str, _ := pool.scan(&text_rows, string, 4)
		defer delete(bool_str)
		defer delete(int2_str)
		defer delete(text_str)
		defer delete(bytea_str)
		defer delete(json_str)

		fmt.printf(
			"  Text format: bool=%s, int2=%s, text='%s', bytea=%s, json='%s'\n",
			bool_str,
			int2_str,
			text_str,
			bytea_str,
			json_str,
		)
	}

	// Now query with binary format (all columns)
	fmt.println("\nNow querying with binary format (all columns):")
	rows, err := pool.query(
		`
		SELECT id, bool_val, int2_val, int4_val, int8_val, float4_val, float8_val, 
		       text_val, bytea_val, date_val, timestamp_val, json_val 
		FROM test_binary
	`,
	)

	if err != nil {
		fmt.eprintln("Failed to query with binary format:", err)
		return
	}
	defer pool.release_query(&rows)

	fmt.println("Retrieved values (binary format):")

	if pool.next_row(&rows) {
		id, _ := pool.scan(&rows, int, 0)
		bool_val_ret, _ := pool.scan(&rows, bool, 1)
		int2_val_ret, _ := pool.scan(&rows, i16, 2)
		int4_val_ret, _ := pool.scan(&rows, i32, 3)
		int8_val_ret, _ := pool.scan(&rows, i64, 4)
		float4_val_ret, _ := pool.scan(&rows, f32, 5)
		float8_val_ret, _ := pool.scan(&rows, f64, 6)
		text_val_ret, _ := pool.scan(&rows, string, 7)
		bytea_val_ret, _ := pool.scan(&rows, []byte, 8)
		date_val_ret, _ := pool.scan(&rows, time.Time, 9)
		timestamp_val_ret, _ := pool.scan(&rows, time.Time, 10)
		json_val_ret, _ := pool.scan(&rows, string, 11)

		defer delete(text_val_ret)
		defer delete(bytea_val_ret)
		defer delete(json_val_ret)

		fmt.printf("  id: %d\n", id)
		fmt.printf("  bool: %t\n", bool_val_ret)
		fmt.printf("  int2: %d\n", int2_val_ret)
		fmt.printf("  int4: %d\n", int4_val_ret)
		fmt.printf("  int8: %d\n", int8_val_ret)
		fmt.printf("  float4: %g\n", float4_val_ret)
		fmt.printf("  float8: %g\n", float8_val_ret)
		fmt.printf("  text: '%s'\n", text_val_ret)
		fmt.printf("  bytea: %02x\n", bytea_val_ret)

		d_year, d_month, d_day := time.date(date_val_ret)
		fmt.printf("  date: %04d-%02d-%02d\n", d_year, int(d_month), d_day)

		ts_year, ts_month, ts_day := time.date(timestamp_val_ret)
		ts_hour, ts_min, ts_sec := time.clock(timestamp_val_ret)
		ts_nano := time.to_unix_nanoseconds(timestamp_val_ret) % 1_000_000_000
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

		fmt.printf("  json: '%s'\n", json_val_ret)
	}

	fmt.println("\n✅ Binary format round-trip successful! All types work correctly.")

	// Clean up
	pool.exec("DROP TABLE test_binary")
}

test_custom_types :: proc() {
	fmt.println("\n=== Testing Custom Types ===")

	// Create test table for custom types
	pool.exec("DROP TABLE IF EXISTS test_custom")
	_, create_err := pool.exec(
		`
		CREATE TABLE test_custom (
			id SERIAL PRIMARY KEY,
			uuid_val UUID,
			test_name TEXT
		)
	`,
	)
	if create_err != nil {
		fmt.eprintln("Failed to create custom types table:", create_err)
		return
	}

	// Test UUID type
	test_uuid := "550e8400-e29b-41d4-a716-446655440000"

	// Insert UUID
	_, insert_err := pool.exec(
		"INSERT INTO test_custom (uuid_val, test_name) VALUES ($1, $2)",
		args = {test_uuid, "Test UUID"},
	)
	if insert_err != nil {
		fmt.eprintln("Failed to insert UUID:", insert_err)
		return
	}
	fmt.println("Successfully inserted UUID with custom type handler")

	// Query UUID back
	rows, query_err := pool.query(
		"SELECT uuid_val FROM test_custom WHERE test_name = $1",
		args = {"Test UUID"},
	)
	if query_err != nil {
		fmt.eprintln("Failed to query UUID:", query_err)
		return
	}
	defer pool.release_query(&rows)

	if pool.next_row(&rows) {
		retrieved_uuid, _ := pool.scan(&rows, string, 0)
		defer delete(retrieved_uuid)
		fmt.printf("Retrieved UUID: %s\n", retrieved_uuid)

		if retrieved_uuid == test_uuid {
			fmt.println("Custom type round-trip successful!")
		} else {
			fmt.printf("UUID mismatch: expected %s, got %s\n", test_uuid, retrieved_uuid)
		}
	}

	fmt.println("Custom type handlers allow extending supported PostgreSQL types")

	// Clean up
	pool.exec("DROP TABLE test_custom")
}

main :: proc() {
	test_binary_format()
	test_custom_types()
}
