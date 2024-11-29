package postgres

import "core:fmt"
import "core:mem"
import "core:os"
import "env"
import "pool"

main :: proc() {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	context.allocator = mem.tracking_allocator(&tracker)
	_main()

	if len(tracker.allocation_map) > 0 {
		fmt.println()
		for _, v in tracker.allocation_map {
			fmt.printf("%v Leaked %v bytes.\n", v.location, v.size)
		}
	} else {
		fmt.println("Hooray! no memory leaks")
	}
}

User :: struct {
	user_id:    int,
	// first_name: Maybe(string),
	first_name: string,
	last_name:  string,
}
_main :: proc() {
	if !env.set() {panic("Failed to read .env file, aborting.")}
	url := os.get_env("DATABASE_URL"); defer delete(url)

	pool.init(url, min_connections=1); defer pool.destroy_pool()
	pool.health_check()

// 	cnx, _:=pool.acquire()
// 	defer pool.release(cnx)
// 	ps_err:= pool.prepare_statement(cnx,"uid", "SELECT user_id, first_name, last_name from users WHERE user_id = $1;")
// fmt.println("ps-err",ps_err)
// 	result,ex_err:=pool.exec_prepared_statement(cnx,"uid", 1)
// fmt.println("ex-err",ex_err)
// SELECT $1::int
	rows, err:= pool.query2("SELECT user_id, first_name, last_name from users WHERE user_id = $1;",args={3})
	// rows, err:= pool.query2("SELECT 1;")
	defer pool.release_query(&rows)
	fmt.println("rows",rows.row_count, err)

	if err == nil {
		for pool.next_row(&rows) {
			user := pool.scan_into(&rows, User)
			fmt.println("USER", user)
			break
			// uid, u_err := pool.scan(&rows, int, 0)
			// first, f_err := pool.scan(&rows, string, 1)
			// last, l_err := pool.scan(&rows, string, 2)
			// fmt.printf("user_id: %v, name: '%v %v'\n", uid, first, last)

			// delete(first.(string))
			// delete(last.(string))
		}
	} else {
		fmt.println("POOL ERROR", err)
	}


	// cnx := pool.acquire();defer pool.release(cnx)
	// pok := pool.prepare(cnx, "abc", "SELECT first_name from users where user_id=$1;")
	// dok := pool.describe_prepared_statement(cnx, "abc")
	// fmt.println(pok, dok)

	// pool.load_type_cache()
}
