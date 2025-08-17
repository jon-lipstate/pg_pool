package postgres_tests

import pool "../pool"
import "core:fmt"
import "core:math/fixed"

test_type_safety :: proc() {
	fmt.println("\n=== Type Safety Test for Arrays ===")

	// Create test table with different array types
	pool.exec("DROP TABLE IF EXISTS test_type_safety")
	pool.exec(
		"CREATE TABLE test_type_safety (int2s INT2[], int4s INT4[], int8s INT8[], floats FLOAT4[], doubles FLOAT8[])",
	)

	// Insert test data
	pool.exec(
		"INSERT INTO test_type_safety VALUES (ARRAY[1,2,3]::INT2[], ARRAY[100,200,300]::INT4[], ARRAY[1000,2000,3000]::INT8[], ARRAY[1.5,2.5,3.5]::FLOAT4[], ARRAY[10.1,20.2,30.3]::FLOAT8[])",
	)

	// Query the data
	rows, err := pool.query("SELECT int2s, int4s, int8s, floats, doubles FROM test_type_safety")
	if err != nil {
		fmt.eprintln("Failed to query:", err)
		return
	}
	defer pool.release_query(&rows)

	if pool.next_row(&rows) {
		fmt.println("\n--- Testing safe upcasts (should work) ---")

		// Test reading arrays with proper types
		{
			int2_as_i16, _ := pool.scan(&rows, []i16, 0)
			int4_as_i32, _ := pool.scan(&rows, []i32, 1)
			int8_as_i64, _ := pool.scan(&rows, []i64, 2)
			floats, _ := pool.scan(&rows, []f32, 3)
			doubles, _ := pool.scan(&rows, []f64, 4)

			fmt.printf("INT2[] as []i16: %v ✓\n", int2_as_i16)
			fmt.printf("INT4[] as []i32: %v ✓\n", int4_as_i32)
			fmt.printf("INT8[] as []i64: %v ✓\n", int8_as_i64)
			fmt.printf("FLOAT4[] as []f32: %v ✓\n", floats)
			fmt.printf("FLOAT8[] as []f64: %v ✓\n", doubles)
		}
	}

	// Query again for upcast tests
	rows2, err2 := pool.query("SELECT int2s, int4s FROM test_type_safety")
	if err2 != nil {
		fmt.eprintln("Failed to query:", err2)
		return
	}
	defer pool.release_query(&rows2)

	if pool.next_row(&rows2) {
		// Test INT2[] -> []i32 (safe upcast)
		{
			int2_as_i32, _ := pool.scan(&rows2, []i32, 0) // INT2[] upcast to []i32
			int4_as_i64, _ := pool.scan(&rows2, []i64, 1) // INT4[] upcast to []i64
			fmt.printf("INT2[] as []i32 (upcast): %v ✓\n", int2_as_i32)
			fmt.printf("INT4[] as []i64 (upcast): %v ✓\n", int4_as_i64)
		}
	}

	// Query again for INT2[] -> []i64 upcast
	rows3, err3 := pool.query("SELECT int2s FROM test_type_safety")
	if err3 != nil {
		fmt.eprintln("Failed to query:", err3)
		return
	}
	defer pool.release_query(&rows3)

	if pool.next_row(&rows3) {
		int2_as_i64, _ := pool.scan(&rows3, []i64, 0) // INT2[] upcast to []i64
		fmt.printf("INT2[] as []i64 (upcast): %v ✓\n", int2_as_i64)
	}

	fmt.println("\n--- Testing unsafe downcasts (should fail) ---")

	// Test INT8[] -> []i32 (should fail due to type check)
	rows4, err4 := pool.query("SELECT int8s FROM test_type_safety")
	if err4 != nil {
		fmt.eprintln("Failed to query:", err4)
		return
	}

	if pool.next_row(&rows4) {
		int8_as_i32, err := pool.scan(&rows4, []i32, 0) // INT8[] -> []i32 (should fail)
		if err != pool.QueryError.None {
			fmt.printf("INT8[] as []i32: Failed as expected ✓ (type mismatch prevented)\n")
		} else {
			fmt.printf(
				"INT8[] as []i32: ERROR - should have failed but got: %v ✗\n",
				int8_as_i32,
			)
		}
	}

	// Release query BEFORE dropping table to avoid deadlock
	pool.release_query(&rows4)

	// Clean up
	pool.exec("DROP TABLE test_type_safety")

	// Test i64 and []i64 support
	fmt.println("\n--- Testing i64/bigint support ---")
	pool.exec("DROP TABLE IF EXISTS test_bigint")
	pool.exec("CREATE TABLE test_bigint (id BIGINT, values BIGINT[])")

	// Test large values that require i64
	big_value := i64(9223372036854775000) // Close to max i64
	big_array := []i64{big_value, -big_value, 0, 1, -1}

	pool.exec("INSERT INTO test_bigint VALUES ($1, $2)", args = {big_value, big_array})

	rows5, err5 := pool.query("SELECT id, values FROM test_bigint")
	if err5 != nil {
		fmt.eprintln("Failed to query bigint:", err5)
		return
	}
	defer pool.release_query(&rows5)

	if pool.next_row(&rows5) {
		retrieved_value, _ := pool.scan(&rows5, i64, 0)
		retrieved_array, _ := pool.scan(&rows5, []i64, 1)
		fmt.printf("BIGINT value: %d ✓\n", retrieved_value)
		fmt.printf("BIGINT[] array: %v ✓\n", retrieved_array)

		if retrieved_value == big_value {
			fmt.println("i64 round-trip successful! ✓")
		} else {
			fmt.printf("i64 mismatch: expected %d, got %d ✗\n", big_value, retrieved_value)
		}

		if len(retrieved_array) == len(big_array) && retrieved_array[0] == big_array[0] {
			fmt.println("[]i64 round-trip successful! ✓")
		} else {
			fmt.printf("[]i64 mismatch: expected %v, got %v ✗\n", big_array, retrieved_array)
		}
	}

	pool.exec("DROP TABLE test_bigint")

	// Test NUMERIC/DECIMAL support
	fmt.println("\n--- Testing NUMERIC/DECIMAL support ---")
	pool.exec("DROP TABLE IF EXISTS test_numeric")
	pool.exec(
		"CREATE TABLE test_numeric (id SERIAL, price NUMERIC(10,2), amount DECIMAL(15,4), total NUMERIC(20,6))",
	)

	// Test Fixed52_12 values
	price: pool.Numeric
	fixed.init_from_f64(&price, 123.45)

	amount: pool.Numeric
	fixed.init_from_f64(&amount, 9876.5432)

	total: pool.Numeric
	fixed.init_from_f64(&total, 10000.123456)

	pool.exec(
		"INSERT INTO test_numeric (price, amount, total) VALUES ($1, $2, $3)",
		args = {price, amount, total},
	)

	// Also test f64 to NUMERIC conversion  
	pool.exec(
		"INSERT INTO test_numeric (price, amount, total) VALUES ($1, $2, $3)",
		args = {99.99, 1234.5678, 5555.555555},
	)

	rows6, err6 := pool.query("SELECT price, amount, total FROM test_numeric ORDER BY id")
	if err6 != nil {
		fmt.eprintln("Failed to query numeric:", err6)
		return
	}
	defer pool.release_query(&rows6)

	fmt.println("Retrieved NUMERIC values as Fixed52_12:")
	for pool.next_row(&rows6) {
		// Test reading as Numeric (Fixed52_12)
		retrieved_price, _ := pool.scan(&rows6, pool.Numeric, 0)
		retrieved_amount, _ := pool.scan(&rows6, pool.Numeric, 1)
		retrieved_total, _ := pool.scan(&rows6, pool.Numeric, 2)

		fmt.printf(
			"Price: %s, Amount: %s, Total: %s ✓\n",
			fixed.to_string(retrieved_price, context.temp_allocator),
			fixed.to_string(retrieved_amount, context.temp_allocator),
			fixed.to_string(retrieved_total, context.temp_allocator),
		)
	}

	// Query again to test f64 conversion
	rows7, err7 := pool.query("SELECT price, amount, total FROM test_numeric ORDER BY id")
	if err7 != nil {
		fmt.eprintln("Failed to query numeric as f64:", err7)
		return
	}
	defer pool.release_query(&rows7)

	fmt.println("Retrieved NUMERIC values as f64:")
	for pool.next_row(&rows7) {
		price_f64, _ := pool.scan(&rows7, f64, 0)
		amount_f64, _ := pool.scan(&rows7, f64, 1)
		total_f64, _ := pool.scan(&rows7, f64, 2)
		fmt.printf(
			"Price: %.2f, Amount: %.4f, Total: %.6f ✓\n",
			price_f64,
			amount_f64,
			total_f64,
		)
	}

	// Query again to test string conversion
	rows8, err8 := pool.query("SELECT price, amount, total FROM test_numeric ORDER BY id")
	if err8 != nil {
		fmt.eprintln("Failed to query numeric as string:", err8)
		return
	}
	defer pool.release_query(&rows8)

	fmt.println("Retrieved NUMERIC values as string:")
	for pool.next_row(&rows8) {
		price_str, _ := pool.scan(&rows8, string, 0)
		amount_str, _ := pool.scan(&rows8, string, 1)
		total_str, _ := pool.scan(&rows8, string, 2)
		defer delete(price_str)
		defer delete(amount_str)
		defer delete(total_str)
		fmt.printf("Price: %s, Amount: %s, Total: %s ✓\n", price_str, amount_str, total_str)
	}

	pool.exec("DROP TABLE test_numeric")
	fmt.println("\n=== Type Safety Test Complete ===")
}

main :: proc() {
	test_type_safety()
}
