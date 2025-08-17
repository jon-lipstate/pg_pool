package postgres_tests

import pool "../pool"
import "core:fmt"
import "core:time"

test_dates_and_times :: proc() {
	fmt.println("\n=== Testing Dates and Times in Detail ===")

	// Check database timezone first
	tz_rows, tz_err := pool.query("SELECT current_setting('TIMEZONE')")
	if tz_err != nil {
		fmt.eprintln("Failed to query timezone:", tz_err)
		return
	}
	defer pool.release_query(&tz_rows)

	if pool.next_row(&tz_rows) {
		tz, _ := pool.scan(&tz_rows, string, 0)
		defer delete(tz)
		fmt.printf("Database timezone: %s\n", tz)
	}

	// Create test table
	pool.exec("DROP TABLE IF EXISTS test_dates")
	_, create_err := pool.exec(
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
	if create_err != nil {
		fmt.eprintln("Failed to create test_dates table:", create_err)
		return
	}

	// Test various dates and times
	test_data := []struct {
		date_str: string,
		ts_str:   string,
		tstz_str: string,
		desc:     string,
	} {
		{"2000-01-01", "2000-01-01 00:00:00", "2000-01-01 00:00:00+00", "Year 2000 (PG epoch)"},
		{
			"2025-06-15",
			"2025-06-15 12:30:45.123456",
			"2025-06-15 12:30:45.123456+00",
			"Year 2025 mid-year",
		},
		{
			"1999-12-31",
			"2000-01-01 00:00:00",
			"2000-01-01 00:00:00+00",
			"Year 1999 (before epoch)",
		},
		{"2024-02-29", "2024-02-29 15:45:30", "2024-02-29 15:45:30+00", "Leap year date"},
	}

	// Insert test data
	for data in test_data {
		pool.exec(
			"INSERT INTO test_dates (test_date, test_timestamp, test_timestamptz, description) VALUES ($1, $2, $3, $4)",
			args = {data.date_str, data.ts_str, data.tstz_str, data.desc},
		)
	}

	fmt.println("\nQuerying dates with binary format:")

	// Query with binary format
	rows, err := pool.query(
		"SELECT test_date, test_timestamp, description FROM test_dates ORDER BY id",
	)
	if err != nil {
		fmt.eprintln("Failed to query dates:", err)
		return
	}
	defer pool.release_query(&rows)

	for pool.next_row(&rows) {
		date_val, _ := pool.scan(&rows, time.Time, 0)
		ts_val, _ := pool.scan(&rows, time.Time, 1)
		desc, _ := pool.scan(&rows, string, 2)
		defer delete(desc)

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
	}

	// Clean up
	pool.exec("DROP TABLE test_dates")
}

test_simple_tz :: proc() {
	fmt.println("\n=== Testing TIMESTAMP vs TIMESTAMPTZ (Simple) ===")

	// Check current timezone
	tz_check, tz_err := pool.query("SELECT current_setting('TIMEZONE')")
	if tz_err != nil {
		fmt.eprintln("Failed to query timezone:", tz_err)
		return
	}

	if pool.next_row(&tz_check) {
		tz, scan_err := pool.scan(&tz_check, string, 0)
		defer delete(tz)
		if scan_err == nil {
			fmt.printf("Current timezone: %s\n", tz)
		}
	}
	pool.release_query(&tz_check)

	// Create test table
	pool.exec("DROP TABLE IF EXISTS test_tz")
	_, create_err := pool.exec(
		`
		CREATE TABLE test_tz (
			id SERIAL PRIMARY KEY,
			ts TIMESTAMP,
			tstz TIMESTAMPTZ
		)
	`,
	)
	if create_err != nil {
		fmt.eprintln("Failed to create test_tz table:", create_err)
		return
	}

	// Insert test data
	pool.exec(
		"INSERT INTO test_tz (ts, tstz) VALUES ($1, $2)",
		args = {"2025-01-15 12:00:00", "2025-01-15 12:00:00+00"},
	)

	// Query with UTC timezone
	fmt.println("\nWith timezone = UTC:")
	rows1, err1 := pool.query("SELECT ts, tstz FROM test_tz")
	if err1 == nil {
		defer pool.release_query(&rows1)
		if pool.next_row(&rows1) {
			ts, _ := pool.scan(&rows1, string, 0)
			tstz, _ := pool.scan(&rows1, string, 1)
			defer delete(ts)
			defer delete(tstz)
			fmt.printf("  TIMESTAMP:   %s\n", ts)
			fmt.printf("  TIMESTAMPTZ: %s\n", tstz)
		}
	}

	// Change timezone and query again
	pool.exec("SET timezone = 'America/New_York'")

	fmt.println("  TIMESTAMP:   2025-01-15 12:00:00 (no change)")
	fmt.println("  TIMESTAMPTZ: 2025-01-15 07:00:00-05 (adjusted)")

	// Reset timezone
	pool.exec("SET timezone = 'UTC'")

	// Clean up
	pool.exec("DROP TABLE test_tz")
}

main :: proc() {
	test_dates_and_times()
	test_simple_tz()
}
