package pg_pool

main :: proc() {}

import pq "../vendor/odin-postgresql"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

// Global / Singleton
POOL: Connection_Pool

Config :: struct {
	host:              string,
	port:              u16,
	database:          string,
	user:              string,
	password:          string,
	connect_timeout:   time.Duration,
	runtime_params:    map[string]string,
	connection_string: cstring,
}

Connection_Pool :: struct {
	lock:               sync.Mutex,
	cond:               sync.Cond,
	active_connections: [dynamic]^Connection,
	idle_connections:   [dynamic]^Connection,
	config:             Config,
	min_size:           int,
	max_size:           int,
	max_life_time:      time.Duration,
	max_idle_time:      time.Duration,
	text_mode:          bool, // only text-mode atm!
}

Connection :: struct {
	cnx:         pq.Conn,
	created_at:  time.Time,
	last_active: time.Time,
}

// Basic_Types :: union {
// 	^bool,
// 	// u8,
// 	// u16,
// 	// u32,
// 	// u64,
// 	^uint,
// 	// i8,
// 	// i16,
// 	// i32,
// 	// i64,
// 	^int,
// 	^f32,
// 	^f64,
// 	^rune,
// 	^string,
// 	^time.Time,
// 	^time.DateTime,
// 	^time.Date,
// 	^[]bool,
// 	^[]byte, // bytea
// 	^[]uint,
// 	^[]int,
// 	^[]f32,
// 	^[]f64,
// 	^[]string,
// }

// Postgres integers: 
//
// `INTEGER: i32`, `BIGINT: i64`, `SMALLINT: i16`. There are NO `uint` types. 
//
init :: proc(
	connection_string: string,
	min_connections: uint = 4,
	max_connections: uint = 64,
	max_idle_mins: uint = 5,
	text_mode := true,
) -> (
	ok: bool,
) {
	fmt.println("start init")
	config, config_ok := parse_connection_string(connection_string)
	if !config_ok {
		fmt.eprintln("Invalid connection string")
		return false
	}

	if max_connections < min_connections {
		fmt.eprintln("Invalid pool configuration : max_connections < min_connections")
		return false
	}

	POOL = Connection_Pool {
		config             = config,
		min_size           = int(min_connections),
		max_size           = int(max_connections),
		max_idle_time      = time.Minute * cast(time.Duration)(max_idle_mins),
		max_life_time      = time.Minute * 30, // Default connection lifetime
		active_connections = make([dynamic]^Connection),
		idle_connections   = make([dynamic]^Connection),
		lock               = sync.Mutex{},
		cond               = sync.Cond{},
	}

	if !rebalance() {fmt.eprintln("failed to rebalance pool during initializaiton")}

	ping_result := pq.ping(POOL.config.connection_string)
	if ping_result != pq.Ping.OK {
		fmt.println("Server did not respond OK to a ping.")
		return false
	}

	return true
}
destroy_pool :: proc() -> (ok: bool) {
	destroy_config(&POOL.config)
	unimplemented()
}

// postgres://user:password@localhost:5432/mydb?sslmode=disable&application_name=myapp
@(private)
parse_connection_string :: proc(
	str: string,
	allocator := context.allocator,
) -> (
	config: Config,
	ok: bool,
) {
	context.allocator = allocator

	config = Config {
		connection_string = strings.clone_to_cstring(str),
	}
	scheme, host, path, queries, _ := net.split_url(str)

	if scheme != "postgres" && scheme != "postgresql" {
		return config, false // Invalid
	}

	// Extract userinfo (user:password) and host:port
	userinfo_host := strings.split(host, "@")
	assert(len(userinfo_host) == 2) // ensure no anon logins (for now)
	host = userinfo_host[1]

	user_password := strings.split(userinfo_host[0], ":")
	assert(len(user_password) == 2)
	config.user = user_password[0]
	config.password = user_password[1]

	host_port := strings.split(host, ":")
	config.host = host_port[0]
	assert(len(host_port) <= 2)
	if len(host_port) == 2 {
		port_val, port_ok := strconv.parse_int(host_port[1])
		if port_ok {
			config.port = u16(port_val)
		} else {
			return config, false // nfg
		}
	} else {
		config.port = 5432 // default port
	}

	// db name:
	config.database = path[1:] // Strip leading '/'

	config.runtime_params = queries

	return config, true
}
@(private)

destroy_config :: proc(config: ^Config) {
	delete(config.connection_string)
	delete(config.runtime_params)

	when ODIN_DEBUG {config^ = {}}
}

acquire :: proc() -> ^Connection {
	sync.lock(&POOL.lock)
	defer sync.unlock(&POOL.lock)

	for len(POOL.idle_connections) > 0 {
		cnx := pop(&POOL.idle_connections)

		time_elapsed := time.since(cnx.created_at)
		if time_elapsed > POOL.max_life_time {
			destroy_connection(cnx)
			continue
		}

		append(&POOL.active_connections, cnx)
		cnx.last_active = time.now()
		return cnx
	}

	if len(POOL.active_connections) < POOL.max_size {
		cnx, ok := create_new_connection()
		if ok {
			append(&POOL.active_connections, cnx)
			return cnx
		} else {
			panic("Failed to create a new connection")
		}
	}

	// Pool is full, wait 
	for len(POOL.idle_connections) == 0 {
		sync.cond_wait(&POOL.cond, &POOL.lock)
	}
	cnx := pop(&POOL.idle_connections)
	cnx.last_active = time.now()
	append(&POOL.active_connections, cnx)

	return cnx
}
release :: proc(cnx: ^Connection) {
	sync.lock(&POOL.lock)
	defer sync.unlock(&POOL.lock)

	did_pop := pop_connection(&POOL.active_connections, cnx)
	assert(did_pop)
	append(&POOL.idle_connections, cnx)

	ok := validate_connection(cnx)
	if ok {
		sync.cond_signal(&POOL.cond)
	} else {
		destroy_connection(cnx)
	}
}

@(private)
create_new_connection :: proc(allocator := context.allocator) -> (cnx: ^Connection, ok: bool) {
	pq_conn := pq.connectdb(POOL.config.connection_string)

	if pq.status(pq_conn) != pq.Connection_Status.Ok {
		pq_error_message := pq.error_message(pq_conn)
		fmt.eprintln("Failed to connect to database:", pq_error_message)
		return nil, false
	}

	cnx = new(Connection, allocator)
	cnx^ = {
		cnx         = pq_conn,
		created_at  = time.now(),
		last_active = time.now(),
	}

	return cnx, true
}
@(private)
pop_connection :: proc(list: ^[dynamic]^Connection, cnx: ^Connection) -> (ok: bool) {
	index := -1
	for c, i in list {
		if c == cnx {index = i;break}
	}
	if index < 0 {return false}
	unordered_remove(list, index)
	return true
}
@(private)
destroy_connection :: proc(cnx: ^Connection) {
	sync.lock(&POOL.lock)
	defer sync.unlock(&POOL.lock)

	removed := pop_connection(&POOL.idle_connections, cnx)
	if !removed {
		removed = pop_connection(&POOL.active_connections, cnx)
		if !removed {
			fmt.eprintln("Connection not found in either active or idle pools")
			return
		}
	}
	assert(cnx.cnx != nil)
	pq.finish(cnx.cnx)
}

@(private)
validate_connection :: proc(cnx: ^Connection) -> bool {
	time_elapsed := time.since(cnx.created_at)
	if time_elapsed > POOL.max_life_time {
		return false
	}
	if pq.status(cnx.cnx) != pq.Connection_Status.Ok {
		return false
	}

	// TODO: see if status is good enough or should do simple query:
	// result := pq.exec(cnx.cnx, "SELECT 1;")
	// if result == nil || pq.result_status(result) != pq.Exec_Status.Tuples_OK {
	// 	pq.clear(result)
	// 	return false // Connection is not responsive
	// }
	// pq.clear(result)
	return true
}

health_check :: proc() {
	sync.lock(&POOL.lock)
	defer sync.unlock(&POOL.lock)
	#reverse for cnx in POOL.idle_connections {
		time_elapsed := time.since(cnx.last_active)
		if time_elapsed > POOL.max_idle_time {
			destroy_connection(cnx)
		}
	}
	if !rebalance() {fmt.eprintln("failed to rebalance pool after health_check")}
}


resize_pool :: proc(new_min_size: int, new_max_size: int) {
	sync.lock(&POOL.lock)
	defer sync.unlock(&POOL.lock)

	POOL.min_size = new_min_size
	POOL.max_size = new_max_size

	if !rebalance() {fmt.eprintln("failed to rebalance pool after resizing")}
}
@(private)
rebalance :: proc() -> (ok: bool) {
	total_connections := len(POOL.active_connections) + len(POOL.idle_connections)

	downsize: for total_connections > POOL.max_size {
		if len(POOL.idle_connections) > 0 {
			cnx := pop(&POOL.idle_connections)
			destroy_connection(cnx)
		} else {break downsize}
	}
	upsize: for i := total_connections; i < POOL.min_size; i += 1 {
		cnx, ok := create_new_connection()
		if !ok {
			return false
		}
		append(&POOL.idle_connections, cnx)
	}
	return true
}


exec :: proc(sql: string, arguments: ..any) -> (result: pq.Result, ok: bool) {
	cnx := acquire()
	if cnx == nil {
		fmt.eprintln("Failed to acquire a connection from the pool")
		return nil, false
	}
	defer release(cnx)
	defer free_all(context.temp_allocator) // TODO: pass in allocator or free here? feels nicer here...

	// Prepare the query with arguments (e.g., using positional placeholders $1, $2, etc.)
	formatted_sql := format_sql_with_args(sql, arguments, context.temp_allocator)
	if formatted_sql == "" {
		fmt.eprintln("Failed to format SQL with arguments")
		return nil, false
	}

	result = pq.exec(cnx.cnx, strings.clone_to_cstring(formatted_sql, context.temp_allocator))
	if result == nil {
		fmt.eprintln("Failed to execute SQL query")
		return nil, false
	}

	return result, true
}

prepare :: proc(cnx: ^Connection, name: string, sql: string) -> (ok: bool) {
	c_stmt_name := strings.clone_to_cstring(name, context.temp_allocator)
	c_sql := strings.clone_to_cstring(sql, context.temp_allocator)
	defer free_all(context.temp_allocator)

	res := pq.prepare(cnx.cnx, c_stmt_name, c_sql, 2, nil)
	if pq.result_status(res) != pq.Exec_Status.Command_OK {
		fmt.println("Preparation failed:", pq.error_message(cnx.cnx))
		pq.clear(res)
		return false
	}
	pq.clear(res)
	return true
}

// exec_prepared :: proc(cnx: ^Connection, name: string, args: ..any) -> (res: pq.Result, ok: bool) {
// 	c_stmt_name := strings.clone_to_cstring(name, context.temp_allocator)
// 	defer free_all(context.temp_allocator)

// 	param_values := []^byte{}
// 	for param in params {
// 		c_param := strings.clone_to_cstring(param, context.temp_allocator)
// 		append(&param_values, c_param)
// 	}

// 	res := pq.exec_prepared(cnx.cnx, c_stmt_name, len(param_values), param_values, nil, nil, .Text)

// 	if pq.result_status(res) != pq.Exec_Status.Tuples_OK {
// 		fmt.println("Execution failed:", pq.error_message(cnx.cnx))
// 		pq.clear(res)
// 		return nil, false
// 	}

// 	return res, true
// }


Rows :: struct {
	result:       pq.Result,
	cnx:          ^Connection,
	current_row:  int,
	// columns:     []Column_Metadata,
	column_count: int,
	row_count:    int,
}
Column_Metadata :: struct {
	name: string,
	oid:  pq.OID,
}

query :: proc(sql: string, args: ..any) -> (Rows, bool) {
	cnx := acquire()
	if cnx == nil {
		fmt.eprintln("Failed to acquire connection from pool")
		return {}, false
	}

	formatted_sql := format_sql_with_args(sql, args, context.temp_allocator)
	c_sql := strings.clone_to_cstring(formatted_sql, context.temp_allocator)
	defer free_all(context.temp_allocator)

	result := pq.exec(cnx.cnx, c_sql)
	if result == nil || pq.result_status(result) != pq.Exec_Status.Tuples_OK {
		release(cnx)
		fmt.eprintln("Query failed:", pq.error_message(cnx.cnx))
		return {}, false
	}
	return Rows {
			result = result,
			cnx = cnx,
			current_row = -1,
			column_count = int(pq.n_fields(result)),
			row_count = int(pq.n_tuples(result)),
		},
		true
}

// query_bin :: proc(sql: string, args: ..any) -> (Rows, bool) {
// 	unimplemented("todo - switch to binary execs")
// 	cnx := acquire()
// 	if cnx == nil {
// 		fmt.eprintln("Failed to acquire connection from pool")
// 		return {}, false
// 	}

// 	formatted_sql := format_sql_with_args(sql, args, context.temp_allocator)
// 	c_sql := strings.clone_to_cstring(formatted_sql, context.temp_allocator)
// 	defer free_all(context.temp_allocator)

// 	param_count := len(args)
// 	param_values := make([]cstring, param_count, context.temp_allocator)
// 	param_lengths := make([]int, param_count, context.temp_allocator)
// 	param_formats := make([]int, param_count, context.temp_allocator)

// 	for i, arg in args {
// 		param_values[i] = format_sql_argument(arg, context.temp_allocator)
// SET BIN / TEXT HERE
// 		param_lengths[i] = len(param_values[i])
// 		param_formats[i] = 0 // 0 = text, 1 = binary
// 	}

// 	result_format := 1 
// 	result := pq.exec_params(
// 		cnx.cnx,
// 		c_sql,
// 		param_count,
// 		nil,
// 		param_values,
// 		param_lengths,
// 		param_formats,
// 		result_format, 
// 	)

// 	if result == nil || pq.result_status(result) != pq.Exec_Status.Tuples_OK {
// 		release(cnx)
// 		fmt.eprintln("Query failed:", pq.error_message(cnx.cnx))
// 		return {}, false
// 	}

// 	return Rows {
// 			result = result,
// 			conn = cnx,
// 			current_row = 0,
// 			column_count = int(pq.n_fields(result)),
// 		},
// 		true
// }


// fetch_column_metadata :: proc(rows: ^Rows) {
// 	column_count := int(pq.n_fields(rows.result))
// 	rows.columns = make([]Column_Metadata, column_count)

// 	for i := 0; i < column_count; i += 1 {
// 		cstr := pq.f_name(rows.result, i32(i))
// 		name := strings.clone(string(cstr))
// 		oid := pq.f_type(rows.result, i32(i))

// 		rows.columns[i] = Column_Metadata {
// 			name = name,
// 			oid  = oid,
// 		}
// 	}
// }


release_query :: proc(rows: ^Rows) {
	if rows.result != nil {
		pq.clear(rows.result)
	}
	release(rows.cnx)
}

// TODO: should next_row be moved into scan row??
next_row :: proc(rows: ^Rows) -> (ok: bool) {
	if rows.current_row >= rows.row_count - 1 {
		return false
	}
	rows.current_row += 1
	return true
}
// Will allocate when T is a [] type, including strings
scan :: proc(
	rows: ^Rows,
	$T: typeid,
	col: int,
	row: Maybe(int) = nil,
	allocator := context.allocator,
) -> (
	val: Maybe(T),
	ok: bool,
) #optional_ok {
	target_row := i32(rows.current_row)
	if row != nil {target_row = i32(row.(int))}
	// ensure in-bounds:
	if target_row < 0 || target_row >= i32(rows.row_count) {return nil, false}

	// Check if the column is null
	if pq.get_is_null(rows.result, i32(rows.current_row), i32(col)) {
		return nil, true
	}

	// Get the size of the column value
	n_bytes := int(pq.f_size(rows.result, i32(col)))

	ptr := pq.get_value(rows.result, target_row, i32(col))
	str := cast(string)cstring(ptr)

	return parse_text(str, T, allocator)
}

// read text-return value from Postgres
@(private)
parse_text :: proc(
	str: string,
	$T: typeid,
	allocator := context.allocator,
) -> (
	val: T,
	ok: bool,
) #optional_ok {
	when T == bool {
		val = str[0] == 't' ? true : false
		return val, true
	}
	when T == int {
		ival, iok := strconv.parse_int(str)
		if !iok {fmt.panicf("Expected int, got: '%v'.", str)}
		val = ival
		return val, true
	}
	when T == uint {
		ival, uok := strconv.parse_uint(str)
		if !uok {fmt.panicf("Expected uint, got: '%v'.", str)}
		val = ival
		return val, true
	}
	when T == f32 {
		fval, fok := strconv.parse_f32(str)
		if !fok {fmt.panicf("Expected f32, got: '%v'.", str)}
		val = fval
		return val, true
	}
	when T == f64 {
		fval, fok := strconv.parse_f64(str)
		if !fok {fmt.panicf("Expected f64, got: '%v'.", str)}
		val = fval
		return val, true
	}
	when T == string {
		val = strings.clone(str, allocator)
		return val, true
	}


	fmt.println("...")
	return val, false // Unsupported type, return false for ok

}

@(private)
format_sql_with_args :: proc(
	sql: string,
	args: ..any,
	allocator := context.temp_allocator,
) -> string {
	allocator := context.allocator

	sb := strings.builder_make()

	arg_index := 0
	start := 0

	for i := 1;; i += 1 {
		placeholder := fmt.tprintf("$%d", i)
		dollar := strings.index(sql[start:], placeholder)
		end := start + dollar

		if dollar < 0 {
			strings.write_string(&sb, sql[start:])
			break
		}

		strings.write_string(&sb, sql[start:end])

		if arg_index >= len(args) {
			fmt.eprintln("Not enough arguments for placeholders")
			return ""
		}
		strings.write_string(&sb, convert_to_sql_value(args[arg_index]))
		arg_index += 1

		start += dollar + len(placeholder)
	}

	return strings.to_string(sb)
}

@(private)
convert_to_sql_value :: proc(arg: any, allocator := context.temp_allocator) -> string {
	context.allocator = allocator

	switch a in arg {
	case string:
		return fmt.tprintf("'%s'", a)
	case int, i8, i16, i32, i64:
		return fmt.tprintf("%d", a)
	case uint, u8, u16, u32, u64:
		return fmt.tprintf("%d", a)
	case f16, f32, f64:
		return fmt.tprintf("%v", a)
	case:
		return "NULL"
	}
}
