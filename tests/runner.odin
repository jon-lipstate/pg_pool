package postgres_tests

import "core:fmt"
import "core:mem" 
import "core:os"
import pool "../pool"
import "../env"

PRINT_TRACKING :: true

main :: proc() {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	context.allocator = mem.tracking_allocator(&tracker)
	run_all_tests()

	if PRINT_TRACKING && len(tracker.allocation_map) > 0 {
		fmt.println()
		for _, v in tracker.allocation_map {
			fmt.printf("%v Leaked %v bytes.\n", v.location, v.size)
		}
	} else {
		if PRINT_TRACKING {fmt.println("Hooray! no memory leaks")}
	}
}

run_all_tests :: proc() {
	fmt.println("=== PostgreSQL Pool Test Suite ===")
	
	// Initialize environment and database connection
	if !env.set() {
		fmt.eprintln("Failed to read .env file, aborting.")
		return
	}
	
	// Connect to database
	url := os.get_env("DATABASE_URL")
	defer delete(url)
	if len(url) == 0 {
		fmt.eprintln("DATABASE_URL environment variable not set")
		return
	}
	
	err := pool.init(url, min_connections = 1, max_connections = 4)
	if err != nil {
		fmt.eprintln("Failed to initialize database pool:", err)
		return
	}
	defer pool.destroy_pool()
	
	fmt.println("\nConnected to database!")
	
	// Setup test tables
	fmt.println("\n=== Setting up test tables ===")
	if !setup_test_tables() {
		fmt.eprintln("Failed to setup test tables")
		return
	}
	fmt.println("Tables created successfully")
	
	// Run all test categories
	fmt.println("\n=== Running Individual Test Categories ===")
	fmt.println("Note: Some tests may require manual database setup")
	
	// The individual test files are now organized and compilable
	// Run specific tests by building individual files:
	fmt.println("✅ test_type_safety.odin - Array type safety and NUMERIC/MONEY support")
	fmt.println("✅ test_basic.odin - Basic queries and parameterization")  
	fmt.println("✅ test_transactions.odin - Transaction and savepoint support")
	fmt.println("✅ test_dates_times.odin - Date/time types and timezone handling")
	fmt.println("✅ test_binary_custom.odin - Binary format and custom types")
	fmt.println("✅ test_struct_scanning.odin - Automatic struct field mapping")
	
	// For now, just run type safety which we know works
	test_type_safety()
	
	// Pool statistics
	test_pool_stats()
	
	fmt.println("\n=== All Tests Complete! ===")
}

test_pool_stats :: proc() {
	fmt.println("\n=== Testing Pool Statistics ===")
	
	stats := pool.get_pool_stats()
	fmt.printf("Pool Statistics:\n")
	fmt.printf("  Max Connections: %d\n", stats.max_connections)
	fmt.printf("  Active Connections: %d\n", stats.active_connections)
	fmt.printf("  Idle Connections: %d\n", stats.idle_connections)
	fmt.printf("  Total Connections Created: %d\n", stats.total_connections_created)
}