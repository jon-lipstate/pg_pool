package postgres_tests

import "core:fmt"
import pool "../pool"

test_transactions :: proc() {
	fmt.println("\n=== Testing Transactions ===")
	
	// Start a transaction
	tx, tx_err := pool.begin()
	if tx_err != nil {
		fmt.eprintln("Failed to start transaction:", tx_err)
		return
	}
	
	// Get current stock within transaction
	stock_rows, stock_err := pool.query("SELECT stock FROM products WHERE name = $1", tx, args = {"Laptop"})
	if stock_err != nil {
		fmt.eprintln("Failed to query stock:", stock_err)
		pool.rollback(tx)
		return
	}
	
	current_stock: int
	if pool.next_row(&stock_rows) {
		current_stock, _ = pool.scan(&stock_rows, int, 0)
	}
	pool.release_query(&stock_rows)
	fmt.printf("Current stock for Laptop: %d\n", current_stock)
	
	// Update stock within transaction
	new_stock := current_stock - 2
	_, update_err := pool.exec("UPDATE products SET stock = $1 WHERE name = $2", tx, args = {new_stock, "Laptop"})
	if update_err != nil {
		fmt.eprintln("Failed to update stock:", update_err)
		pool.rollback(tx)
		return
	}
	
	// Verify the update within the transaction
	verify_rows, verify_err := pool.query("SELECT stock FROM products WHERE name = $1", tx, args = {"Laptop"})
	if verify_err != nil {
		fmt.eprintln("Failed to verify stock:", verify_err)
		pool.rollback(tx)
		return
	}
	
	if pool.next_row(&verify_rows) {
		updated_stock, _ := pool.scan(&verify_rows, int, 0)
		fmt.printf("New stock (in tx): %d\n", updated_stock)
	}
	pool.release_query(&verify_rows)
	
	// Commit the transaction
	commit_err := pool.commit(tx)
	if commit_err != nil {
		fmt.eprintln("Failed to commit transaction:", commit_err)
		return
	}
	
	fmt.println("Transaction committed successfully")
}

test_nested_transactions :: proc() {
	fmt.println("\n=== Testing Nested Transactions (Savepoints) ===")
	
	// Start outer transaction
	tx, tx_err := pool.begin()
	if tx_err != nil {
		fmt.eprintln("Failed to start outer transaction:", tx_err)
		return
	}
	
	// Insert a user in the outer transaction
	_, outer_err := pool.exec("INSERT INTO users (email, name, age) VALUES ($1, $2, $3)", tx, args = {"charlie@example.com", "Charlie", 35})
	if outer_err != nil {
		fmt.eprintln("Failed to insert Charlie:", outer_err)
		pool.rollback(tx)
		return
	}
	fmt.println("Inserted Charlie in outer transaction")
	
	// Create a savepoint (nested transaction)
	sp, sp_err := pool.begin(tx)
	if sp_err != nil {
		fmt.eprintln("Failed to create savepoint:", sp_err)
		pool.rollback(tx)
		return
	}
	
	// Insert another user in the nested transaction
	_, nested_err := pool.exec("INSERT INTO users (email, name, age) VALUES ($1, $2, $3)", sp, args = {"david@example.com", "David", 40})
	if nested_err != nil {
		fmt.eprintln("Failed to insert David:", nested_err)
		pool.rollback(sp)
		// Continue with outer transaction
	} else {
		fmt.println("Inserted David in nested transaction")
	}
	
	// Rollback the nested transaction (David should be removed, Charlie should remain)
	rollback_err := pool.rollback(sp)
	if rollback_err != nil {
		fmt.eprintln("Failed to rollback to savepoint:", rollback_err)
		pool.rollback(tx)
		return
	}
	fmt.println("Rolled back nested transaction (David)")
	
	// Commit the outer transaction (only Charlie should be committed)
	commit_err := pool.commit(tx)
	if commit_err != nil {
		fmt.eprintln("Failed to commit outer transaction:", commit_err)
		return
	}
	fmt.println("Committed outer transaction (Charlie)")
	
	// Verify the results
	rows, query_err := pool.query("SELECT name FROM users WHERE email IN ($1, $2) ORDER BY name", args = {"charlie@example.com", "david@example.com"})
	if query_err != nil {
		fmt.eprintln("Failed to verify nested transaction results:", query_err)
		return
	}
	defer pool.release_query(&rows)
	
	fmt.println("Users after nested transaction test:")
	for pool.next_row(&rows) {
		name, _ := pool.scan(&rows, string, 0)
		defer delete(name)
		fmt.printf("  - %s\n", name)
	}
}

main :: proc() {
	test_transactions()
	test_nested_transactions()
}