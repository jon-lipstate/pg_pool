package postgres

import "core:fmt"
import "core:os"
import "env"
import "pool"

main :: proc() {
	fmt.println("Hi")
	env_ok := env.set()
	if !env_ok {panic("Failed to read .env file, aborting.")}
	fmt.println("calling init")
	url := os.get_env("DATABASE_URL")
	fmt.println("url", url)
	// pool.init(url)
	// fmt.println("init ok")

	// pool.health_check()
	// fmt.println("health ok")
	// rows, ok := pool.query("select 1;")
	// fmt.println("query ok")

	// i: int
	// scan_ok, did_alloc := pool.scan_row(&rows, &i)
	// fmt.println("scan ok", scan_ok)


}
