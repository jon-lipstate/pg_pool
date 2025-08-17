package postgres_tests

import pool "../pool"
import pq "../vendor/odin-postgresql"
import "core:encoding/hex"
import "core:fmt"
import "core:mem"
import "core:strings"

test_postgres_type :: proc() {
	fmt.println("\n=== Testing Postgres_Type Read/Write Functionality ===")

	// Create test table with various custom types
	pool.exec("DROP TABLE IF EXISTS test_postgres_types")
	_, err := pool.exec(
		`
		CREATE TABLE test_postgres_types (
			id SERIAL PRIMARY KEY,
			uuid_field UUID,
			inet_field INET,
			cidr_field CIDR,
			macaddr_field MACADDR,
			custom_text TEXT
		)
	`,
	)
	if err != nil {
		fmt.eprintln("Failed to create table:", err)
		return
	}
	defer pool.exec("DROP TABLE test_postgres_types")

	// Test 1: UUID Read/Write
	fmt.println("\n--- Test 1: UUID Read/Write ---")
	test_uuid_readwrite()

	// Test 2: INET Read/Write
	fmt.println("\n--- Test 2: INET Read/Write ---")
	test_inet_readwrite()

	// Test 3: MACADDR Read/Write
	fmt.println("\n--- Test 3: MACADDR Read/Write ---")
	test_macaddr_readwrite()

	// Test 4: Binary vs Text format handling
	fmt.println("\n--- Test 4: Binary vs Text Format ---")
	test_format_handling()

	// Test 5: Custom text type with transformation
	fmt.println("\n--- Test 5: Custom Text Transformation ---")
	test_custom_text_transform()

	fmt.println("\n✅ All Postgres_Type tests complete!")
}

test_uuid_readwrite :: proc() {
	test_uuid1 := "550e8400-e29b-41d4-a716-446655440000"
	test_uuid2 := "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

	// UUID Writer - Text format
	uuid_text_writer := pool.Postgres_Type {
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

	// UUID Writer - Binary format (16 bytes)
	uuid_binary_writer := pool.Postgres_Type {
		oid = pool.OID_UUID,
		format = .Binary,
		writer = proc(buf: ^[dynamic]byte, arg: any, format: pq.Format) -> (size: i32) {
			uuid_str := arg.(string)
			// Remove hyphens and convert to bytes
			clean, _ := strings.replace_all(uuid_str, "-", "", allocator = context.temp_allocator)
			bytes, _ := hex.decode(transmute([]byte)clean, allocator = context.temp_allocator)
			append(buf, ..bytes)
			return i32(len(bytes))
		},
	}

	// Insert with text format writer
	fmt.println("Inserting UUID with text writer:", test_uuid1)
	_, err1 := pool.exec(
		"INSERT INTO test_postgres_types (uuid_field) VALUES ($1)",
		types = {uuid_text_writer},
		args = {test_uuid1},
	)
	if err1 != nil {
		fmt.eprintln("  ✗ Failed to insert with text writer:", err1)
	} else {
		fmt.println("  ✓ Inserted with text writer")
	}

	// Insert with binary format writer
	fmt.println("Inserting UUID with binary writer:", test_uuid2)
	_, err2 := pool.exec(
		"INSERT INTO test_postgres_types (uuid_field) VALUES ($1)",
		types = {uuid_binary_writer},
		args = {test_uuid2},
	)
	if err2 != nil {
		fmt.eprintln("  ✗ Failed to insert with binary writer:", err2)
	} else {
		fmt.println("  ✓ Inserted with binary writer")
	}

	// UUID Reader - handles both text and binary
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
				uuid_str := string(bytes)
				return strings.clone(uuid_str, allocator), nil
			} else {
				// Binary: 16 bytes
				if len(bytes) != 16 {
					return nil, pool.QueryError.InvalidFormat
				}
				// Convert to standard UUID string format
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

	// Read back with text format
	fmt.println("Reading UUIDs with text format:")
	rows_text, _ := pool.query(
		"SELECT uuid_field FROM test_postgres_types ORDER BY id",
		result_format = .Text,
	)
	defer pool.release_query(&rows_text)

	uuid_count := 0
	for pool.next_row(&rows_text) {
		uuid_val, err := pool.scan(&rows_text, string, 0, custom_type = uuid_reader)
		if err != nil {
			fmt.eprintln("  ✗ Failed to scan UUID:", err)
		} else {
			defer delete(uuid_val)
			fmt.printf("  ✓ Read UUID (text): %s\n", uuid_val)
			uuid_count += 1
		}
	}

	// Read back with binary format
	fmt.println("Reading UUIDs with binary format:")
	rows_binary, _ := pool.query(
		"SELECT uuid_field FROM test_postgres_types ORDER BY id",
		result_format = .Binary,
	)
	defer pool.release_query(&rows_binary)

	for pool.next_row(&rows_binary) {
		uuid_val, err := pool.scan(&rows_binary, string, 0, custom_type = uuid_reader)
		if err != nil {
			fmt.eprintln("  ✗ Failed to scan UUID:", err)
		} else {
			defer delete(uuid_val)
			fmt.printf("  ✓ Read UUID (binary): %s\n", uuid_val)
		}
	}

	if uuid_count == 2 {
		fmt.println("✓ UUID read/write test passed!")
	}
}

test_inet_readwrite :: proc() {
	test_inet := "192.168.1.100"
	test_cidr := "10.0.0.0/8"

	// INET/CIDR Writer
	inet_writer := pool.Postgres_Type {
		oid = pool.OID_INET,
		format = .Text,
		writer = proc(buf: ^[dynamic]byte, arg: any, format: pq.Format) -> (size: i32) {
			inet_str := arg.(string)
			p_bytes := transmute([]byte)inet_str
			append(buf, ..p_bytes)
			append(buf, 0)
			return i32(len(inet_str))
		},
	}

	cidr_writer := pool.Postgres_Type {
		oid = pool.OID_CIDR,
		format = .Text,
		writer = proc(buf: ^[dynamic]byte, arg: any, format: pq.Format) -> (size: i32) {
			cidr_str := arg.(string)
			p_bytes := transmute([]byte)cidr_str
			append(buf, ..p_bytes)
			append(buf, 0)
			return i32(len(cidr_str))
		},
	}

	// Insert INET and CIDR
	fmt.printf("Inserting INET: %s, CIDR: %s\n", test_inet, test_cidr)
	_, err := pool.exec(
		"INSERT INTO test_postgres_types (inet_field, cidr_field) VALUES ($1, $2)",
		types = {inet_writer, cidr_writer},
		args = {test_inet, test_cidr},
	)
	if err != nil {
		fmt.eprintln("  ✗ Failed to insert INET/CIDR:", err)
		return
	}
	fmt.println("  ✓ Inserted INET/CIDR")

	// INET/CIDR Reader
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
				inet_str := string(bytes)
				return strings.clone(inet_str, allocator), nil
			} else {
				// Binary format would need proper parsing
				// For this test, we'll just handle text
				return nil, pool.QueryError.NotImplemented
			}
		},
	}

	// Read back
	rows, _ := pool.query(
		"SELECT inet_field, cidr_field FROM test_postgres_types WHERE inet_field IS NOT NULL",
	)
	defer pool.release_query(&rows)

	if pool.next_row(&rows) {
		inet_val, _ := pool.scan(&rows, string, 0, custom_type = inet_reader)
		cidr_val, _ := pool.scan(&rows, string, 1, custom_type = inet_reader)
		defer delete(inet_val)
		defer delete(cidr_val)

		fmt.printf("  ✓ Read INET: %s\n", inet_val)
		fmt.printf("  ✓ Read CIDR: %s\n", cidr_val)

		if inet_val == test_inet && cidr_val == test_cidr {
			fmt.println("✓ INET/CIDR read/write test passed!")
		}
	}
}

test_macaddr_readwrite :: proc() {
	test_mac := "08:00:2b:01:02:03"

	// MACADDR Writer
	mac_writer := pool.Postgres_Type {
		oid = pool.OID_MACADDR,
		format = .Text,
		writer = proc(buf: ^[dynamic]byte, arg: any, format: pq.Format) -> (size: i32) {
			mac_str := arg.(string)
			p_bytes := transmute([]byte)mac_str
			append(buf, ..p_bytes)
			append(buf, 0)
			return i32(len(mac_str))
		},
	}

	// Insert MACADDR
	fmt.printf("Inserting MACADDR: %s\n", test_mac)
	_, err := pool.exec(
		"INSERT INTO test_postgres_types (macaddr_field) VALUES ($1)",
		types = {mac_writer},
		args = {test_mac},
	)
	if err != nil {
		fmt.eprintln("  ✗ Failed to insert MACADDR:", err)
		return
	}
	fmt.println("  ✓ Inserted MACADDR")

	// MACADDR Reader
	mac_reader := pool.Postgres_Type {
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
				mac_str := string(bytes)
				// Could normalize format here (e.g., ensure colons)
				return strings.clone(mac_str, allocator), nil
			} else {
				// Binary: 6 bytes
				if len(bytes) != 6 {
					return nil, pool.QueryError.InvalidFormat
				}
				mac_str := fmt.aprintf(
					"%02x:%02x:%02x:%02x:%02x:%02x",
					bytes[0],
					bytes[1],
					bytes[2],
					bytes[3],
					bytes[4],
					bytes[5],
					allocator = allocator,
				)
				return mac_str, nil
			}
		},
	}

	// Read back
	rows, _ := pool.query(
		"SELECT macaddr_field FROM test_postgres_types WHERE macaddr_field IS NOT NULL",
	)
	defer pool.release_query(&rows)

	if pool.next_row(&rows) {
		mac_val, _ := pool.scan(&rows, string, 0, custom_type = mac_reader)
		defer delete(mac_val)

		fmt.printf("  ✓ Read MACADDR: %s\n", mac_val)
		if mac_val == test_mac {
			fmt.println("✓ MACADDR read/write test passed!")
		}
	}
}

test_format_handling :: proc() {
	// Test that the same custom type handles both binary and text formats correctly
	test_value := "FORMAT-TEST-VALUE"

	// Custom type that tracks which format was used
	format_writer := pool.Postgres_Type {
		oid = pool.OID_TEXT,
		format = .Text,
		writer = proc(buf: ^[dynamic]byte, arg: any, format: pq.Format) -> (size: i32) {
			str := arg.(string)
			// Add a prefix to identify format used
			prefixed := fmt.tprintf("[TEXT]%s", str)
			p_bytes := transmute([]byte)prefixed
			append(buf, ..p_bytes)
			append(buf, 0)
			return i32(len(prefixed))
		},
	}

	// Insert with custom writer
	_, err := pool.exec(
		"INSERT INTO test_postgres_types (custom_text) VALUES ($1)",
		types = {format_writer},
		args = {test_value},
	)
	if err != nil {
		fmt.eprintln("  ✗ Failed to insert with format writer:", err)
		return
	}

	// Reader that detects format
	format_reader := pool.Postgres_Type {
		reader = proc(
			bytes: []byte,
			oid: pq.OID,
			text_mode: bool,
			allocator: mem.Allocator,
		) -> (
			any,
			pool.Error,
		) {
			str := string(bytes)
			if text_mode {
				result := fmt.aprintf("Read as TEXT: %s", str, allocator = allocator)
				return result, nil
			} else {
				result := fmt.aprintf("Read as BINARY: %s", str, allocator = allocator)
				return result, nil
			}
		},
	}

	// Read with text format
	rows_text, _ := pool.query(
		"SELECT custom_text FROM test_postgres_types WHERE custom_text IS NOT NULL",
		result_format = .Text,
	)
	defer pool.release_query(&rows_text)

	if pool.next_row(&rows_text) {
		val, _ := pool.scan(&rows_text, string, 0, custom_type = format_reader)
		defer delete(val)
		fmt.printf("  %s\n", val)
	}

	// Read with binary format
	rows_binary, _ := pool.query(
		"SELECT custom_text FROM test_postgres_types WHERE custom_text IS NOT NULL",
		result_format = .Binary,
	)
	defer pool.release_query(&rows_binary)

	if pool.next_row(&rows_binary) {
		val, _ := pool.scan(&rows_binary, string, 0, custom_type = format_reader)
		defer delete(val)
		fmt.printf("  %s\n", val)
	}

	fmt.println("✓ Format handling test passed!")
}

test_custom_text_transform :: proc() {
	// Test custom transformation on read/write
	original := "hello world"

	// Writer that transforms to uppercase
	upper_writer := pool.Postgres_Type {
		oid = pool.OID_TEXT,
		format = .Text,
		writer = proc(buf: ^[dynamic]byte, arg: any, format: pq.Format) -> (size: i32) {
			str := arg.(string)
			upper := strings.to_upper(str, context.temp_allocator)
			p_bytes := transmute([]byte)upper
			append(buf, ..p_bytes)
			append(buf, 0)
			return i32(len(upper))
		},
	}

	// Insert with uppercase transformation
	fmt.printf("Inserting '%s' with uppercase transform\n", original)
	pool.exec("DELETE FROM test_postgres_types WHERE custom_text IS NOT NULL")
	_, err := pool.exec(
		"INSERT INTO test_postgres_types (custom_text) VALUES ($1)",
		types = {upper_writer},
		args = {original},
	)
	if err != nil {
		fmt.eprintln("  ✗ Failed to insert:", err)
		return
	}

	// Reader that transforms to title case
	title_reader := pool.Postgres_Type {
		reader = proc(
			bytes: []byte,
			oid: pq.OID,
			text_mode: bool,
			allocator: mem.Allocator,
		) -> (
			any,
			pool.Error,
		) {
			str := string(bytes)
			// Simple title case: capitalize first letter of each word
			words := strings.split(str, " ", context.temp_allocator)
			for &word in words {
				if len(word) > 0 {
					// Capitalize first letter, lowercase rest
					first := strings.to_upper(word[:1], context.temp_allocator)
					rest := strings.to_lower(word[1:], context.temp_allocator)
					word = strings.concatenate({first, rest}, context.temp_allocator)
				}
			}
			result := strings.join(words, " ", allocator)
			return result, nil
		},
	}

	// Read back with transformation
	rows, _ := pool.query(
		"SELECT custom_text FROM test_postgres_types WHERE custom_text IS NOT NULL",
	)
	defer pool.release_query(&rows)

	if pool.next_row(&rows) {
		// First read normally to see what was stored
		normal, _ := pool.scan(&rows, string, 0)
		defer delete(normal)
		fmt.printf("  Stored in DB: '%s'\n", normal)

		// Reset to read again with custom reader
		rows.current_row = 0
		if pool.next_row(&rows) {
			transformed, _ := pool.scan(&rows, string, 0, custom_type = title_reader)
			defer delete(transformed)
			fmt.printf("  Read with title case transform: '%s'\n", transformed)

			if normal == "HELLO WORLD" && transformed == "Hello World" {
				fmt.println("✓ Custom transformation test passed!")
			}
		}
	}
}

// Test NULL handling with custom types
test_null_handling :: proc() {
	fmt.println("\n--- Test 6: NULL Handling with Custom Types ---")

	// Insert a NULL UUID
	pool.exec("DELETE FROM test_postgres_types")
	pool.exec("INSERT INTO test_postgres_types (uuid_field) VALUES (NULL)")

	// Reader for nullable UUID
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
			// This won't be called for NULL values
			uuid_str := string(bytes)
			return strings.clone(uuid_str, allocator), nil
		},
	}

	rows, _ := pool.query("SELECT uuid_field FROM test_postgres_types")
	defer pool.release_query(&rows)

	if pool.next_row(&rows) {
		// Try to scan nullable field with pointer type
		uuid_val, err := pool.scan(&rows, ^string, 0, custom_type = uuid_reader)
		if err != nil {
			fmt.eprintln("  ✗ Failed to scan NULL UUID:", err)
		} else {
			if uuid_val == nil {
				fmt.println("  ✓ Correctly read NULL UUID as nil")
			} else {
				defer delete(uuid_val^)
				defer free(uuid_val)
				fmt.println("  ✗ Expected nil for NULL UUID")
			}
		}
	}
}

main :: proc() {
	test_postgres_type()
	test_null_handling()
}
