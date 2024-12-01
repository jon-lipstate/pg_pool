package postgres

import "core:fmt"
import "core:mem"
import "core:os"
import "env"
import "pool"
import pq "./vendor/odin-postgresql"


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

Int_PG_Type := pool.Postgres_Type {
	oid=pool.OID_INT4,
	format = .Binary,
	writer=proc(buf:^[dynamic]byte, arg:any, format: pq.Format) -> (size:i32) {
		p_bytes:=pool.to_bytes(i32be(pool.extract_int(arg)))
		append(buf, ..p_bytes)
		return 4
	}
}

_main :: proc() {
	if !env.set() {panic("Failed to read .env file, aborting.")}
	url := os.get_env("DATABASE_URL"); defer delete(url)

	pool.init(url, min_connections=1); defer pool.destroy_pool()
	// pool.health_check()
	
	cnx, _:=pool.acquire()
	defer pool.release(cnx)
	stmt, p_err:= pool.prepare(cnx,"get_user", "SELECT user_id, first_name, last_name from users WHERE user_id = $1;", {typeid_of(i32)}) // alt: {pg_type(.Int4)}
	fmt.println("p_err", p_err)
	rows, err:=pool.exec_prepared(&stmt, 3)	
	fmt.println("err",err)

	// SELECT $1::int

	// rows, err:= pool.query("SELECT user_id, first_name, last_name from users WHERE user_id = $1;", types={Int_PG_Type}, args={3} )
	// defer pool.release_query(&rows)

	if err == nil {
		for pool.next_row(&rows) {
			user := pool.scan_into(&rows, User)
			fmt.println("USER", user)
			delete(user.first_name)
			delete(user.last_name)
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
