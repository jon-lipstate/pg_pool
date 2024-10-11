package postgres

import "core:fmt"
import "core:os"
import "env"
import "pool"

main :: proc() {
	env_ok := env.set()
	if !env_ok {panic("Failed to read .env file, aborting.")}
	url := os.get_env("DATABASE_URL")
	pool.init(url)
	pool.health_check()
	rows, ok := pool.query("SELECT first_name, last_name from users;")
	defer pool.release_query(&rows)

	for pool.next_row(&rows) {
		first := pool.scan(&rows, string, 0)
		last := pool.scan(&rows, string, 1)
		fmt.printf("Result '%v' '%v'\n", first, last)
	}


	// cnx := pool.acquire();defer pool.release(cnx)
	// pok := pool.prepare(cnx, "abc", "SELECT first_name from users where user_id=$1;")
	// dok := pool.describe_prepared_statement(cnx, "abc")
	// fmt.println(pok, dok)

	// pool.load_type_cache()
}
