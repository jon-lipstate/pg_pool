package postgres_tests

import pool "../pool"
import pq "../vendor/odin-postgresql"
import "core:fmt"
import "core:mem"
import "core:strings"

test_custom_types :: proc() {
	fmt.println("\n=== Testing Custom Type Readers ===")

	// Create test table with UUID
	pool.exec("DROP TABLE IF EXISTS test_custom_types")
	_, err := pool.exec(
		`
		CREATE TABLE test_custom_types (
			id SERIAL PRIMARY KEY,
			uuid_field UUID,
			inet_field INET
		)
	`,
	)
	if err != nil {
		fmt.eprintln("Failed to create table:", err)
		return
	}
	defer pool.exec("DROP TABLE test_custom_types")

	// Test 1: Insert UUIDs using the writer
	fmt.println("\nTest 1: Inserting UUID with custom writer...")

	test_uuid := "550e8400-e29b-41d4-a716-446655440000"

	// Define custom UUID writer for insertion
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

	_, insert_err := pool.exec(
		"INSERT INTO test_custom_types (uuid_field, inet_field) VALUES ($1, $2)",
		types = {uuid_writer, {}},
		args = {test_uuid, "192.168.1.1"},
	)
	if insert_err != nil {
		fmt.eprintln("Failed to insert:", insert_err)
		return
	}
	fmt.println("✓ Successfully inserted UUID with custom writer")

	// Test 2: Read UUID with custom reader
	fmt.println("\nTest 2: Reading UUID with custom reader...")

	// Define custom UUID reader
	uuid_reader := pool.Postgres_Type {
		reader = proc(
			bytes: []byte,
			oid: pq.OID,
			text_mode: bool,
			allocator: mem.Allocator,
		) -> (
			any,
			pool.Error,
		) {
			if text_mode {
				// Text format: UUID as string
				uuid_str := string(bytes)
				return strings.clone(uuid_str, allocator), nil
			} else {
				// Binary format: 16 bytes
				if len(bytes) != 16 {
					return nil, pool.QueryError.InvalidFormat
				}
				// Convert binary UUID to string format
				uuid_str := fmt.aprintf(
					"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
					bytes[0],
					bytes[1],
					bytes[2],
					bytes[3],
					bytes[4],
					bytes[5],
					bytes[6],
					bytes[7],
					bytes[8],
					bytes[9],
					bytes[10],
					bytes[11],
					bytes[12],
					bytes[13],
					bytes[14],
					bytes[15],
					allocator = allocator,
				)
				return uuid_str, nil
			}
		},
	}

	rows, query_err := pool.query("SELECT uuid_field, inet_field FROM test_custom_types")
	if query_err != nil {
		fmt.eprintln("Failed to query:", query_err)
		return
	}
	defer pool.release_query(&rows)

	if pool.next_row(&rows) {
		// Read UUID with custom reader
		uuid_val, uuid_err := pool.scan(&rows, string, 0, custom_type = uuid_reader)
		if uuid_err != nil {
			fmt.eprintln("Failed to scan UUID:", uuid_err)
		} else {
			defer delete(uuid_val)
			fmt.printf("UUID value: %s\n", uuid_val)

			if uuid_val == test_uuid {
				fmt.println("✓ UUID matches original value!")
			} else {
				fmt.println("✗ UUID mismatch!")
			}
		}

		// Read INET normally (no custom reader)
		inet_val, _ := pool.scan(&rows, string, 1)
		defer delete(inet_val)
		fmt.printf("INET value: %s\n", inet_val)
	}

	// Test 3: Custom INET reader
	fmt.println("\nTest 3: Custom INET reader...")

	// Define a struct for INET addresses
	INET_Address :: struct {
		ip:   string,
		mask: int,
	}

	inet_reader := pool.Postgres_Type {
		reader = proc(
			bytes: []byte,
			oid: pq.OID,
			text_mode: bool,
			allocator: mem.Allocator,
		) -> (
			any,
			pool.Error,
		) {
			if text_mode {
				// Text format: "192.168.1.1" or "192.168.1.0/24"
				inet_str := string(bytes)
				// For simplicity, just return as string
				// In real code, you'd parse into INET_Address struct
				return strings.clone(inet_str, allocator), nil
			} else {
				// Binary format would need proper parsing
				// For now, just return an error
				return nil, pool.QueryError.NotImplemented
			}
		},
	}

	rows2, _ := pool.query("SELECT inet_field FROM test_custom_types")
	defer pool.release_query(&rows2)

	if pool.next_row(&rows2) {
		inet_custom, inet_err := pool.scan(&rows2, string, 0, custom_type = inet_reader)
		if inet_err != nil {
			fmt.eprintln("Failed to scan INET with custom reader:", inet_err)
		} else {
			defer delete(inet_custom)
			fmt.printf("INET with custom reader: %s\n", inet_custom)
		}
	}

	fmt.println("\n✅ Custom type readers test complete!")
}

main :: proc() {
	test_custom_types()
}
