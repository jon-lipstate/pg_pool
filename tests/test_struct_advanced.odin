package postgres_tests

import "core:fmt"
import "core:time"
import pool "../pool"

// Test structure with slices and pointers
AdvancedUser :: struct {
	id:           int          `pg:"id"`,
	email:        string       `pg:"email"`,
	tags:         []string     `pg:"tags"`,         // Array field
	scores:       []int        `pg:"scores"`,       // Integer array
	preferences:  []string     `pg:"preferences"`,  // Another array
	bio:          ^string      `pg:"bio"`,          // Nullable text field
	age:          ^int         `pg:"age"`,          // Nullable integer
	verified_at:  ^time.Time   `pg:"verified_at"`,  // Nullable timestamp
	rating:       ^f64         `pg:"rating"`,       // Nullable float
}

test_struct_advanced :: proc() {
	fmt.println("\n=== Testing Advanced Struct Scanning (Slices & Pointers) ===")
	
	// Create test table
	pool.exec("DROP TABLE IF EXISTS test_advanced_users")
	_, err := pool.exec(`
		CREATE TABLE test_advanced_users (
			id SERIAL PRIMARY KEY,
			email TEXT NOT NULL,
			tags TEXT[],
			scores INT[],
			preferences TEXT[],
			bio TEXT,
			age INT,
			verified_at TIMESTAMP,
			rating FLOAT8
		)
	`)
	if err != nil {
		fmt.eprintln("Failed to create table:", err)
		return
	}
	defer pool.exec("DROP TABLE test_advanced_users")
	
	// Insert test data with arrays and NULLs
	fmt.println("\nInserting test data...")
	
	// User 1: All fields populated
	_, err1 := pool.exec(`
		INSERT INTO test_advanced_users (email, tags, scores, preferences, bio, age, verified_at, rating)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
		args = {
			"alice@example.com",
			[]string{"admin", "moderator", "verified"},
			[]int{100, 95, 88},
			[]string{"dark-mode", "notifications"},
			"Alice is a software engineer",
			30,
			"2025-01-15 14:30:00",
			4.8,
		},
	)
	if err1 != nil {
		fmt.eprintln("Failed to insert user 1:", err1)
		return
	}
	
	// User 2: Some NULL fields
	_, err2 := pool.exec(`
		INSERT INTO test_advanced_users (email, tags, scores, preferences, bio, age, verified_at, rating)
		VALUES ($1, $2, $3, $4, NULL, NULL, NULL, $5)`,
		args = {
			"bob@example.com",
			[]string{"user"},
			[]int{75, 80},
			[]string{},  // Empty array
			3.5,
		},
	)
	if err2 != nil {
		fmt.eprintln("Failed to insert user 2:", err2)
		return
	}
	
	// Query and scan into struct
	fmt.println("\nQuerying users with advanced struct scanning...")
	rows, query_err := pool.query(`
		SELECT id, email, tags, scores, preferences, bio, age, verified_at, rating
		FROM test_advanced_users
		ORDER BY id
	`)
	if query_err != nil {
		fmt.eprintln("Failed to query:", query_err)
		return
	}
	defer pool.release_query(&rows)
	
	user_num := 1
	for pool.next_row(&rows) {
		user := pool.scan_into(&rows, AdvancedUser)
		
		fmt.printf("\n--- User %d ---\n", user_num)
		fmt.printf("ID: %d\n", user.id)
		fmt.printf("Email: %s\n", user.email)
		fmt.printf("Tags: %v\n", user.tags)
		fmt.printf("Scores: %v\n", user.scores)
		fmt.printf("Preferences: %v\n", user.preferences)
		
		// Handle nullable fields
		if user.bio != nil {
			fmt.printf("Bio: %s\n", user.bio^)
		} else {
			fmt.println("Bio: NULL")
		}
		
		if user.age != nil {
			fmt.printf("Age: %d\n", user.age^)
		} else {
			fmt.println("Age: NULL")
		}
		
		if user.verified_at != nil {
			year, month, day := time.date(user.verified_at^)
			hour, min, sec := time.clock(user.verified_at^)
			fmt.printf("Verified: %04d-%02d-%02d %02d:%02d:%02d\n",
				year, int(month), day, hour, min, sec)
		} else {
			fmt.println("Verified: NULL")
		}
		
		if user.rating != nil {
			fmt.printf("Rating: %.1f\n", user.rating^)
		} else {
			fmt.println("Rating: NULL")
		}
		
		// Clean up allocated memory
		delete(user.email)
		for tag in user.tags {
			delete(tag)
		}
		delete(user.tags)
		delete(user.scores)
		for pref in user.preferences {
			delete(pref)
		}
		delete(user.preferences)
		if user.bio != nil {
			delete(user.bio^)
			free(user.bio)
		}
		if user.age != nil {
			free(user.age)
		}
		if user.verified_at != nil {
			free(user.verified_at)
		}
		if user.rating != nil {
			free(user.rating)
		}
		
		user_num += 1
	}
	
	fmt.println("\n✅ Advanced struct scanning test complete!")
}

main :: proc() {
	test_struct_advanced()
}