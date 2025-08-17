#+feature dynamic-literals
package postgres_tests

import pool "../pool"
import "core:encoding/json"
import "core:fmt"

test_json :: proc() {
	fmt.println("\n=== Testing JSON/JSONB Support ===")

	// Create test table with both JSON and JSONB
	pool.exec("DROP TABLE IF EXISTS test_json")
	_, err := pool.exec(
		`
		CREATE TABLE test_json (
			id SERIAL PRIMARY KEY,
			metadata JSON,
			settings JSONB,
			description TEXT
		)
	`,
	)
	if err != nil {
		fmt.eprintln("Failed to create table:", err)
		return
	}
	defer pool.exec("DROP TABLE test_json")

	// Test 1: Insert json.Value objects
	fmt.println("\nTest 1: Inserting json.Value objects...")

	metadata := json.Object {
		"version" = json.Float(1.0),
		"author"  = json.String("Alice"),
		"tags"    = json.Array{json.String("important"), json.String("reviewed")},
		"active"  = json.Boolean(true),
	}

	settings := json.Object {
		"theme" = json.String("dark"),
		"notifications" = json.Object {
			"email" = json.Boolean(true),
			"push" = json.Boolean(false),
			"frequency" = json.String("daily"),
		},
		"limits" = json.Object{"max_size" = json.Float(1024), "timeout" = json.Float(30)},
	}

	_, insert_err := pool.exec(
		"INSERT INTO test_json (metadata, settings, description) VALUES ($1, $2, $3)",
		args = {metadata, settings, "First test record"},
	)
	if insert_err != nil {
		fmt.eprintln("Failed to insert JSON values:", insert_err)
		return
	}
	fmt.println("✓ Successfully inserted json.Value objects")

	// Test 2: Insert JSON as strings
	fmt.println("\nTest 2: Inserting JSON as strings...")

	json_str := `{"type": "string-based", "count": 42, "nested": {"key": "value"}}`
	jsonb_str := `{"enabled": false, "items": [1, 2, 3], "name": "test"}`

	_, str_err := pool.exec(
		"INSERT INTO test_json (metadata, settings, description) VALUES ($1::json, $2::jsonb, $3)",
		args = {json_str, jsonb_str, "String-based JSON"},
	)
	if str_err != nil {
		fmt.eprintln("Failed to insert string JSON:", str_err)
		return
	}
	fmt.println("✓ Successfully inserted JSON strings")

	// Test 3: Query and read back as json.Value
	fmt.println("\nTest 3: Reading JSON columns as json.Value...")

	rows, query_err := pool.query(
		"SELECT id, metadata, settings, description FROM test_json ORDER BY id",
	)
	if query_err != nil {
		fmt.eprintln("Failed to query:", query_err)
		return
	}
	defer pool.release_query(&rows)

	record_num := 1
	for pool.next_row(&rows) {
		fmt.printf("\n--- Record %d ---\n", record_num)

		id, _ := pool.scan(&rows, int, 0)

		// Read JSON column as json.Value
		metadata_val, metadata_err := pool.scan(&rows, json.Value, 1)
		if metadata_err != nil {
			fmt.eprintln("Failed to scan metadata as json.Value:", metadata_err)
		} else {
			fmt.println("Metadata (json.Value):")
			print_json_value(metadata_val, "  ")
			json.destroy_value(metadata_val)
		}

		// Read JSONB column as json.Value
		settings_val, settings_err := pool.scan(&rows, json.Value, 2)
		if settings_err != nil {
			fmt.eprintln("Failed to scan settings as json.Value:", settings_err)
		} else {
			fmt.println("Settings (json.Value):")
			print_json_value(settings_val, "  ")
			json.destroy_value(settings_val)
		}

		desc, _ := pool.scan(&rows, string, 3)
		defer delete(desc)
		fmt.printf("Description: %s\n", desc)

		record_num += 1
	}

	// Test 4: Read JSON as strings for comparison
	fmt.println("\nTest 4: Reading JSON columns as strings...")

	str_rows, _ := pool.query("SELECT metadata, settings FROM test_json ORDER BY id")
	defer pool.release_query(&str_rows)

	record_num = 1
	for pool.next_row(&str_rows) {
		fmt.printf("\n--- Record %d (as strings) ---\n", record_num)

		metadata_str, _ := pool.scan(&str_rows, string, 0)
		settings_str, _ := pool.scan(&str_rows, string, 1)
		defer delete(metadata_str)
		defer delete(settings_str)

		fmt.printf("Metadata: %s\n", metadata_str)
		fmt.printf("Settings: %s\n", settings_str)

		record_num += 1
	}

	// Test 5: Query with JSON operators
	fmt.println("\nTest 5: Using PostgreSQL JSON operators...")

	// Query for specific JSON field
	field_rows, _ := pool.query("SELECT metadata->>'author' as author FROM test_json WHERE id = 1")
	defer pool.release_query(&field_rows)

	if pool.next_row(&field_rows) {
		author, _ := pool.scan(&field_rows, string, 0)
		defer delete(author)
		fmt.printf("Author from first record: %s\n", author)
	}

	// Query with JSONB containment
	contains_rows, _ := pool.query(
		"SELECT id FROM test_json WHERE settings @> $1::jsonb",
		args = {`{"theme": "dark"}`},
	)
	defer pool.release_query(&contains_rows)

	fmt.print("Records with dark theme: ")
	for pool.next_row(&contains_rows) {
		id, _ := pool.scan(&contains_rows, int, 0)
		fmt.printf("%d ", id)
	}
	fmt.println()

	fmt.println("\n✅ JSON/JSONB test complete!")
}

// Helper to print json.Value recursively
print_json_value :: proc(val: json.Value, indent: string) {
	switch v in val {
	case json.Object:
		fmt.println("{")
		for key, value in v {
			fmt.printf("%s  %s: ", indent, key)
			new_indent := fmt.aprintf("%s  ", indent)
			defer delete(new_indent)
			print_json_value(value, new_indent)
		}
		fmt.printf("%s}\n", indent)
	case json.Array:
		fmt.print("[")
		for elem, i in v {
			if i > 0 {fmt.print(", ")}
			print_json_value(elem, indent)
		}
		fmt.println("]")
	case json.String:
		fmt.printf("\"%s\"\n", v)
	case json.Float:
		fmt.printf("%f\n", v)
	case json.Integer:
		fmt.printf("%d\n", v)
	case json.Boolean:
		fmt.printf("%v\n", v)
	case json.Null:
		fmt.println("null")
	}
}

main :: proc() {
	test_json()
}
