package pg_pool

main :: proc() {}

import pq "../vendor/odin-postgresql"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:reflect"
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
	active_connections: [dynamic]^Connection, // allocated by base_allocator
	idle_connections:   [dynamic]^Connection, // allocated by base_allocator
	config:             Config, // allocated by base_allocator
	min_size:           int,
	max_size:           int,
	max_life_time:      time.Duration,
	max_idle_time:      time.Duration,
	text_mode:          bool, // only text-mode atm!
	base_allocator:     mem.Allocator, // what was passed to init
	cnx_backing:        []byte, // allocated by base_allocator
	cnx_allocator:      mem.Buddy_Allocator,
	int_policy: 		Int_Policy, // bitset for uints, allow int etc??
}

Int_Policy::enum { 
	Int_as_Int4,
	Int_as_BigInt,
}

Connection :: struct {
	cnx:         pq.Conn,
	created_at:  time.Time,
	last_active: time.Time,
	arena:       mem.Arena,
	allocator:   mem.Allocator,
	statements:  map[string]Prepared_Statement, // delete me
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
	total_cnx_memory: uint = 16 * mem.Megabyte,
	text_mode := true,
	allocator := context.allocator,
) -> (
	err: Error,
) {
	context.allocator = allocator

	config, config_ok := parse_connection_string(connection_string)
	if !config_ok {return .InvalidConnectionString}

	backing, tcmerr := runtime.make_aligned([]byte, total_cnx_memory, 16)
	if tcmerr != nil {return tcmerr}

	if max_connections < min_connections {return .InvalidPoolArgs}

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
		cnx_backing        = backing,
		base_allocator     = allocator,
	}
	mem.buddy_allocator_init(&POOL.cnx_allocator, POOL.cnx_backing, 16)

	if !rebalance() {fmt.eprintln("failed to rebalance pool during initializaiton")}

	ping_result := pq.ping(POOL.config.connection_string)
	if ping_result != pq.Ping.OK {
		fmt.println("Server did not respond OK to a ping.")
		return .NoResponse
	}

	return nil
}
destroy_pool :: proc() -> Error {
	context.allocator = POOL.base_allocator
	destroy_config(&POOL.config)
	for cnx in POOL.active_connections {destroy_connection(cnx)}
	for cnx in POOL.idle_connections {destroy_connection(cnx)}
	delete(POOL.active_connections)
	delete(POOL.idle_connections)
	delete(POOL.cnx_backing)
	return nil // FIXME: any checks??

}

// postgres://user:password@localhost:5432/mydb?sslmode=disable&application_name=myapp
@(private)
parse_connection_string :: proc(str: string) -> (config: Config, ok: bool) {
	config = Config {
		connection_string = strings.clone_to_cstring(str),
	}
	// scheme, host, path, queries, _ := net.split_url(str)

	// if scheme != "postgres" && scheme != "postgresql" {
	// 	return config, false // Invalid
	// }

	// // Extract userinfo (user:password) and host:port
	// userinfo_host := strings.split(host, "@")
	// assert(len(userinfo_host) == 2) // ensure no anon logins (for now)
	// host = userinfo_host[1]

	// user_password := strings.split(userinfo_host[0], ":")
	// assert(len(user_password) == 2)
	// config.user = user_password[0]
	// config.password = user_password[1]

	// host_port := strings.split(host, ":")
	// config.host = host_port[0]
	// assert(len(host_port) <= 2)
	// if len(host_port) == 2 {
	// 	port_val, port_ok := strconv.parse_int(host_port[1])
	// 	if port_ok {
	// 		config.port = u16(port_val)
	// 	} else {
	// 		return config, false // nfg
	// 	}
	// } else {
	// 	config.port = 5432 // default port
	// }

	// // db name:
	// config.database = path[1:] // Strip leading '/'

	// config.runtime_params = queries

	return config, true
}

@(private)
destroy_config :: proc(config: ^Config) {
	delete(config.connection_string)
	delete(config.runtime_params)

	when ODIN_DEBUG {config^ = {}}
}

@(private)
set_connection_arena :: proc(cnx: ^Connection, allocation_size: uint) -> Error {
	buf, err := mem.buddy_allocator_alloc_bytes(&POOL.cnx_allocator, allocation_size)
	if err != nil {return err}
	mem.arena_init(&cnx.arena, buf)
	cnx.allocator = mem.arena_allocator(&cnx.arena)
	return nil
}

acquire :: proc(allocation_size: uint = 16 * mem.Kilobyte) -> (^Connection, Error) {
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
		err := set_connection_arena(cnx, allocation_size)
		return cnx, err
	}

	if len(POOL.active_connections) < POOL.max_size {
		cnx, ok := create_new_connection()
		if ok {
			append(&POOL.active_connections, cnx)
			err := set_connection_arena(cnx, allocation_size)
			return cnx, err
		} else {
			return nil, PoolError.UnableToAcquireConnection
		}
	}

	// Pool is full, wait 
	for len(POOL.idle_connections) == 0 {
		sync.cond_wait(&POOL.cond, &POOL.lock)
	}
	cnx := pop(&POOL.idle_connections)
	cnx.last_active = time.now()
	append(&POOL.active_connections, cnx)

	err := set_connection_arena(cnx, allocation_size)
	return cnx, err
}
release :: proc(cnx: ^Connection) -> Error {
	sync.lock(&POOL.lock)
	defer sync.unlock(&POOL.lock)
	assert(cnx != nil, "release() on a nil connection")
	err := mem.buddy_allocator_free(&POOL.cnx_allocator, &cnx.arena.data[0])

	did_pop := pop_connection(&POOL.active_connections, cnx)
	assert(did_pop, "released a non-active connection")
	append(&POOL.idle_connections, cnx)

	ok := validate_connection(cnx)
	if ok {
		sync.cond_signal(&POOL.cond)
	} else {
		destroy_connection(cnx)
	}
	return err
}

@(private)
create_new_connection :: proc() -> (cnx: ^Connection, ok: bool) {
	context.allocator = POOL.base_allocator
	pq_conn := pq.connectdb(POOL.config.connection_string)

	if pq.status(pq_conn) != pq.Connection_Status.Ok {
		// FIXME: would like to return a DB_Error, but then the user would need to free it, unlike all other DB_Errors
		pq_error_message := pq.error_message(pq_conn)
		fmt.eprintln("Failed to connect to database:", pq_error_message)
		return nil, false
	}

	cnx = new(Connection)
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
	assert(cnx.cnx != nil, "destroy_connection: attempting to destroy a nil connection")
	pq.finish(cnx.cnx)
	free(cnx, POOL.base_allocator)
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

	// TODO: see if status is good enough or should do simple query..?
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
			destroy_connection(cnx) // TODO: should i destroy or just reset??
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

Exec_Result :: struct {
	result: pq.Result,
	cnx:    ^Connection,
}

exec :: proc(
	sql: string,
	arena_size: uint = 64 * mem.Kilobyte,
	arguments: ..any,
) -> (
	result: Exec_Result,
	err: Error,
) {
	cnx, error := acquire(arena_size)
	context.allocator = cnx.allocator //arena

	if error != nil {
		return {}, .FailedToAcquireConnection
	}
	// Prepare the query with arguments (e.g., using positional placeholders $1, $2, etc.)
	formatted_sql := format_sql_with_args(sql, arguments)
	if formatted_sql == "" {
		return {}, QueryError.FormattingError
	}
	res := pq.exec(cnx.cnx, strings.clone_to_cstring(formatted_sql))
	if res == nil {
		err := db_error_from_msg(cnx)
		return {}, err
	}
	return {res, cnx}, nil
}

prepare :: proc(cnx: ^Connection, name: string, sql: string) -> Error {
	context.allocator = cnx.allocator //arena

	c_stmt_name := strings.clone_to_cstring(name)
	c_sql := strings.clone_to_cstring(sql)

	res := pq.prepare(cnx.cnx, c_stmt_name, c_sql, 2, nil)
	if pq.result_status(res) != pq.Exec_Status.Command_OK {
		err := db_error_from_msg(cnx)
		pq.clear(res)
		return err
	}
	pq.clear(res)
	return nil
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
	result:      pq.Result,
	cnx:         ^Connection,
	current_row: int,
	columns:     []Column_Metadata,
	row_count:   int,
}
Column_Metadata :: struct {
	name:      string,
	oid:       pq.OID,
	text_mode: bool,
}

query2 :: proc(sql: string, arena_size: uint = 64 * mem.Kilobyte, args: ..any) -> (Rows, Error) {
	cnx, err := acquire(arena_size)
	if err != nil {
		fmt.eprintln("query error:", err)
		return {}, .FailedToAcquireConnection
	}
	context.allocator = cnx.allocator // Use the connection's arena

	c_sql := strings.clone_to_cstring(sql)
	n_args:=count_args(sql)
	ep:= make_exec_params(n_args)
	defer delete_exec_params(&ep)

	for arg,i in args{
		set_exec_param(&ep,i,arg)
	}
	
	p_types:= n_args>0 ? &ep.types[0] : nil
	p_lens:= n_args>0 ? &ep.lengths[0]:nil
	p_formats:= n_args>0 ?&ep.formats[0]:nil
	value_ptrs := get_value_ptrs(&ep)
	p_values := n_args>0 ? transmute([^][^]byte)&value_ptrs[0] : nil
	//defer if value_ptrs!=nil {delete(value_ptrs)}

	fmt.println("Parameter Details:")
	for i in 0 ..< len(ep.types) {
		fmt.printf("  Param %d:\n", i)
		fmt.printf("    Type (OID): %d\n", ep.types[i])
		fmt.printf("    Length: %d\n", ep.lengths[i])
		fmt.printf("    Format: %s\n", ep.formats[i] == .Binary ? "Binary" : "Text")
		fmt.printf("    Value (hex): %x\n", ep.values[i:i+ int(ep.lengths[i])])
	}


	result := pq.exec_params(cnx.cnx, c_sql, i32(n_args), p_types, p_values, p_lens, p_formats, .Text)
	fmt.println("After exec")

	if result == nil || pq.result_status(result) != pq.Exec_Status.Tuples_OK {
		err := db_error_from_msg(cnx)
		release(cnx)
		return {}, err
	}
	fmt.println("RC")

	row_count := int(pq.n_tuples(result))

	fmt.println("ROW COUNT", row_count)
	columns := make([]Column_Metadata, int(pq.n_fields(result)))

	for i in 0 ..< len(columns) {
		column_name := cast(string)(pq.f_name(result, i32(i)))
		column_oid := pq.f_type(result, i32(i))
		text_mode := pq.f_format(result, i32(i)) == .Text

		columns[i] = Column_Metadata {
			name      = column_name,
			oid       = column_oid,
			text_mode = text_mode,
		}
	}
	rows:=Rows {
		result = result,
		cnx = cnx,
		current_row = -1,
		row_count = row_count,
		columns = columns,
	}
	// fmt.println("Return Rows-Count", rows.row_count)
	return rows, nil

	// unimplemented("end of q2")
}

Exec_Params :: struct {
	types:	[]pq.OID,
	values:  [dynamic]byte,
	lengths: []i32,
	formats: []pq.Format,
}
make_exec_params::proc(n_params:int,allocator:=context.allocator)->Exec_Params{
	return Exec_Params{
		types=make([]pq.OID,n_params,allocator),
		values=make([dynamic]byte,allocator),
		lengths=make([]i32,n_params,allocator),
		formats=make([]pq.Format,n_params,allocator),
	}
}
delete_exec_params::proc(ep:^Exec_Params){
	assert(ep!=nil)
	delete(ep.types)
	delete(ep.values)
	delete(ep.lengths)
	delete(ep.formats)
}
get_value_ptrs :: proc(ep: ^Exec_Params, allocator:=context.allocator) -> [][^]byte {
    if ep.values==nil || len(ep.values) == 0 {
        return nil // No parameters
    }

    buf := make([dynamic][^]byte, len(ep.values),allocator)

    offset := 0
    for length, i in ep.lengths {
        buf[i] = &ep.values[offset]
        offset += int(length)
    }

    return buf[:]
}



to_bytes :: #force_inline proc(v:$T) -> []byte {
	// NOTE: Must be #force_inline or it needs to allocate
	v:=v
	p:=&v
	bytes:=(transmute([^]byte)p)[:size_of(T)]
	// fmt.println("coverted v to bytes",v,bytes)
	return bytes
}

set_exec_param::proc(ep:^Exec_Params, i:int, param:any) {
	ep.formats[i] = .Binary
	
	switch p in param {
		case bool:
			ep.types[i] = OID_BOOL
			append(&ep.values, ..to_bytes(p))
			ep.lengths[i]=1
		case i8,u8,u16,u32,u64,uint:
			// ERROR - Type Not Supported
		case i16:
			ep.types[i] = OID_INT2 
			append(&ep.values, ..to_bytes(i16be(p)))
			ep.lengths[i]=2
		case i32:
			ep.types[i] = OID_INT4 
			append(&ep.values, ..to_bytes(i32be(p)))
			ep.lengths[i]=4
		case i64:
			ep.types[i] = OID_BIG_INT
			append(&ep.values, ..to_bytes(i64be(p)))
			ep.lengths[i]=8
		case int:			
			if POOL.int_policy == .Int_as_Int4 {
				ep.types[i] = OID_INT4 
				p_bytes:=to_bytes(i32be(p))
				append(&ep.values, ..p_bytes)
				ep.lengths[i]=4
			} else {
				ep.types[i] = OID_BIG_INT
				p_bytes:=to_bytes(i64be(p))
				append(&ep.values, ..p_bytes)
				ep.lengths[i]=8
			}		
		case f32:
			ep.types[i] = OID_FLOAT4 
			append(&ep.values, ..to_bytes(f32be(p)))
			ep.lengths[i]=4	
		case f64:
			ep.types[i] = OID_FLOAT8 
			append(&ep.values, ..to_bytes(f64be(p)))
			ep.lengths[i]=8
		case []byte:
			ep.types[i] = OID_BYTEA 
			append(&ep.values, ..p)
			ep.lengths[i]=i32(len(p))
		case string:
			ep.types[i] = OID_TEXT 
			p_bytes:[]byte= raw_data(p)[:len(p)]
			append(&ep.values, ..p_bytes)
			ep.lengths[i]=i32(len(p))
			ep.formats[i] = .Text
		case:
			ep.formats[i] = .Text

	}
	// fmt.println("EP [types], [values], [lens], [formats]",ep.types,ep.values,ep.lengths,ep.formats)
	// for b in ep.values{fmt.println(b)}
}


query :: proc(sql: string, arena_size: uint = 64 * mem.Kilobyte, args: ..any) -> (Rows, Error) {
	cnx, err := acquire(arena_size)
	if err != nil {
		fmt.eprintln("query error:", err)
		return {}, .FailedToAcquireConnection
	}
	context.allocator = cnx.allocator // Use the connection's arena

	formatted_sql := format_sql_with_args(sql, args)
	c_sql := strings.clone_to_cstring(formatted_sql)
	// defer free_all(context.temp_allocator) // <-- cant do this because we need the columns to persist till the end of the query
	result := pq.exec(cnx.cnx, c_sql)
	if result == nil || pq.result_status(result) != pq.Exec_Status.Tuples_OK {
		err := db_error_from_msg(cnx)
		release(cnx)
		return {}, err
	}

	row_count := int(pq.n_tuples(result))
	columns := make([]Column_Metadata, int(pq.n_fields(result)))

	for i in 0 ..< len(columns) {
		column_name := cast(string)(pq.f_name(result, i32(i)))
		column_oid := pq.f_type(result, i32(i))
		text_mode := pq.f_format(result, i32(i)) == .Text

		columns[i] = Column_Metadata {
			name      = column_name,
			oid       = column_oid,
			text_mode = text_mode,
		}
	}

	return Rows {
			result = result,
			cnx = cnx,
			current_row = -1,
			row_count = row_count,
			columns = columns,
		},
		nil
}

Prepared_Statement :: struct {
	name:        string,
	sql:         string,
	param_types: []pq.OID, // args
	col_types:   []pq.OID, // results
}


prepare_statement :: proc(
	cnx: ^Connection,
	name: string,
	sql: string,
	allocator := context.allocator,
) -> (
	err: Error,
) {
	context.allocator = allocator
	if name in cnx.statements {
		fmt.println("OVER_WRITING STMT")
		return  nil // Already prepared 
	}

	c_name := strings.clone_to_cstring(name)
	c_sql := strings.clone_to_cstring(sql)
	defer {
		delete(c_name)
		delete(c_sql)
	}

	result := pq.prepare(cnx.cnx, c_name, c_sql, 0, nil)
	if result == nil {
		return  db_error_from_msg(cnx)
	}

	status := pq.result_status(result)
	if status != pq.Exec_Status.Command_OK {
		err_msg := pq.error_message(cnx.cnx)
		return  db_error_from_msg(cnx)
	}

	desc := pq.describe_prepared(cnx.cnx, c_name)
	if desc == nil {
		return db_error_from_msg(cnx)
	}

	param_count := pq.n_params(desc)
	fmt.println("Prepared statement params:", param_count) 
	pq.clear(desc)


	param_types := make([]pq.OID, param_count)

	for i in 0 ..< param_count {
		param_types[i] = pq.param_type(result, i32(i))
		fmt.println("PT-i", param_types[i],i)
	}

	cnx.statements[name] = Prepared_Statement {
		name        = name,
		sql         = sql,
		param_types = param_types,
		col_types   = nil, 
	}

	// Clear the result
	pq.clear(result)

	return  nil
}


exec_prepared_statement :: proc(
	cnx: ^Connection,
	name: string,
	args: ..any,
	allocator := context.allocator,
) -> (
	result: pq.Result,
	err: Error,
) {
	if cnx == nil {
		return nil, db_error(.ConnectionError, "Connection is nil")
	}

	if name not_in cnx.statements {
		return nil, db_error(.StatementNotPrepared,fmt.tprintf("Statement '%s' is not prepared", name))
	}

	stmt := cnx.statements[name]
	n_args:= len(args)

	if n_args != len(stmt.param_types) {
		return nil, db_error(.InvalidArgument, fmt.tprintf("Expected '%d' arguments, got '%d' args", len(stmt.param_types), n_args)) 		
	}


	pd, prep_err := prepare_param_data(stmt.param_types, ..args)
	if prep_err != nil {return nil, prep_err}
	defer delete(pd.values)
	defer delete(pd.lengths)
	defer delete(pd.formats)

	c_name := strings.clone_to_cstring(name, allocator)
	defer delete(c_name)



	val_arr := n_args>0 ? transmute([^][^]u8)&(pd.values[:])[0] : nil
	len_arr := n_args>0 ? &pd.lengths[0] : nil
	format_arr := n_args>0 ? &pd.formats[0] : nil

	result = pq.exec_prepared(
		cnx.cnx,
		c_name,
		i32(n_args),
		val_arr,
		len_arr,
		format_arr,
		pq.Format.Binary,
	)

	if result == nil {
		err_msg := pq.error_message(cnx.cnx)
		return nil, db_error(.ExecutionError,
			err_msg != nil ? strings.clone(string(err_msg), allocator) : "Unknown error",) 
	}

	status := pq.result_status(result)
	if status != pq.Exec_Status.Tuples_OK && status != pq.Exec_Status.Command_OK {
		err_msg := pq.result_error_message(result)
		return nil, db_error(.ExecutionError, err_msg != nil ? strings.clone(string(err_msg), allocator) : "Unknown error",) 
	}

	return result, nil

}
Param_Data :: struct {
	values:  [dynamic]byte,
	lengths: []i32,
	formats: []pq.Format,
}

oid_types := map[typeid]pq.OID{
	
	i32 = 23,  // int4
	u32 = 23,  // int4
	i64 = 20,  // bigint
	int = 20,  // bigint
	uint = 20,  // bigint
}


type_cache := map[pq.OID]DB_Type {
	// 23 = {oid = 23, name = "int4", size = 4, proc(arg: any, pd: ^Param_Data, idx: int) -> Error {
	// 		fmt.println("HI TO INT4")
	// 		unimplemented()
	// 	}, proc(arg: any, allocator := context.allocator) -> (int, Error) {
	// 		fmt.println("HI FROM INT4")
	// 		unimplemented()
	// 	}},
}


prepare_param_data :: proc(param_types: []pq.OID, args: ..any) -> (pd: Param_Data, err: Error) {

	if len(args) != len(param_types) {
		return pd, db_error(.InvalidArgument, fmt.tprintf(
			"Mismatched parameter count: expected '%d', got '%d'",
			len(param_types),
			len(args),
		))
	}

	pd = Param_Data {
		values  = make([dynamic]byte),
		lengths = make([]i32, len(args)),
		formats = make([]pq.Format, len(args)),
	}

	for arg, i in args {
		oid := cast(pq.OID)param_types[i]

		// if oid not_in type_cache {
		// 	return pd, DB_Error {
		// 		kind = .InvalidArgument,
		// 		msg = fmt.tprintf(
		// 			"OID '%d' is not a known type in the 'type_cache' for param[%d]",
		// 			oid,
		// 			i,
		// 		),
		// 	}
		// }


		tc := type_cache[oid]
		fmt.println("TC", tc)

		// switch tc.type {
		// case .Integer:

		// a, ok := reflect.as_i64(arg) // FIXME: prob not the fastest way to do this...

		// pd.formats[i] = pq.Format.Binary

		err := tc.to_pg(arg, &pd, i)
		assert(err == nil)
		// switch param_types[i] {
		// case pq.OID_INT2:
		// 	append(&pd.values, cast(i16be)a)
		// 	pd.lengths[i] = 2
		// case pq.OID_INT4:
		// 	append(&pd.values, cast(i32be)a)
		// 	pd.lengths[i] = 4
		// case pq.OID_INT8:
		// 	append(&pd.values, cast(i64be)a)
		// 	pd.lengths[i] = 8
		// case:
		// 	unreachable()
		// }


		// case .Float:
		// 	if tk != .Float {
		// 		delete(pd.values);delete(pd.lengths);delete(pd.formats)
		// 		return pd, DB_Error {
		// 			kind = .InvalidArgument,
		// 			msg = fmt.tprintf("Expected 'Float' for param[%d]", i),
		// 		}
		// 	}
		// 	a, ok := reflect.as_f64(arg) // FIXME: prob not the fastest way to do this...

		// 	pd.formats[i] = pq.Format.Binary

		// 	switch param_types[i] {
		// 	case pq.OID_FLOAT4:
		// 		append(&pd.values, cast(f32be)a)
		// 		pd.lengths[i] = 4
		// 	case pq.OID_FLOAT8:
		// 		append(&pd.values, cast(f64be)a)
		// 		pd.lengths[i] = 8
		// 	case:
		// 		unreachable()
		// 	}

		// case .String:
		// 	// FIXME: prob want to be more relaxed here..? []byte etc?
		// 	if tk != .String {
		// 		delete(pd.values);delete(pd.lengths);delete(pd.formats)
		// 		return pd, DB_Error {
		// 			kind = .InvalidArgument,
		// 			msg = fmt.tprintf("Expected 'String' for param[%d]", i),
		// 		}
		// 	}
		// 	str, ok := arg.(string);if ok {
		// 		append(&pd.values, ..str)
		// 		pd.lengths[i] = i32(len(str))
		// 		pd.formats[i] = pq.Format.Text
		// 	}
		// 	assert(ok, "unreachable")


		// case .Boolean:
		// 	if tk != .Boolean {
		// 		delete(pd.values);delete(pd.lengths);delete(pd.formats)
		// 		return _, DB_Error {
		// 			kind = .InvalidArgument,
		// 			msg = fmt.tprintf("Expected 'Boolean' for param[%d]", i),
		// 		}
		// 	}
		// 	a, ok := reflect.as_bool(arg) // FIXME: prob not the fastest way to do this...
		// 	append(&pd.values, u8(a))

		// 	pd.lengths[i] = 1
		// 	pd.formats[i] = pq.Format.Binary

		// 	case:
		// 		// TODO: other main oids eg bytea, jsonb etc
		// 		delete(pd.values);delete(pd.lengths);delete(pd.formats)
		// 		return pd, DB_Error {
		// 			kind = .UnknownOID,
		// 			msg = fmt.tprintf("Unsupported OID '%d' for param[%d]", param_types[i], i),
		// 		}
		// 	}
	}
	return pd, nil
}


fetch_column_metadata :: proc(rows: ^Rows) {
	column_count := int(pq.n_fields(rows.result))
	rows.columns = make([]Column_Metadata, column_count)

	for i := 0; i < column_count; i += 1 {
		cstr := pq.f_name(rows.result, i32(i))
		name := strings.clone(string(cstr))
		oid := pq.f_type(rows.result, i32(i))

		rows.columns[i] = Column_Metadata {
			name = name,
			oid  = oid,
		}
	}
}

release_query :: proc(rows: ^Rows) {
	if rows == nil {return}
	if rows.result != nil {
		pq.clear(rows.result)
	}
	// delete(rows.columns) // not needed, part of arena
	release(rows.cnx)
}

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
	err: Error,
) {
	context.allocator = allocator

	target_row := i32(rows.current_row)
	// if row != nil {target_row = i32(row.(int))}
	// ensure in-bounds:
	if target_row < 0 || target_row >= i32(rows.row_count) {return nil, .OutOfBounds}
	if col < 0 || col >= len(rows.columns) {return nil, .OutOfBounds}

	if pq.get_is_null(rows.result, i32(rows.current_row), i32(col)) {
		return nil, QueryError.None
	}

	n_bytes := int(pq.f_size(rows.result, i32(col)))

	ptr := pq.get_value(rows.result, target_row, i32(col))

	if rows.columns[col].text_mode {
		str := cast(string)cstring(ptr)
		val, err = parse_text(str, T) // allocator passes in here
	} else {
		unimplemented("Binary Mode Scanning Not Implemented")
	}
	return
}
// unimplemented("needs some more thought, cannot pass a maybe, i think..?")

scan_into :: proc(rows: ^Rows, $T: typeid, allocator := context.allocator) -> T {
	cols := get_pg_columns(T) // get `pg:` tagged columns
	defer delete(cols)

	val := T{}
	struct_ptr := &val

	for row_col, i in rows.columns {
		match := false
		for pg_col in cols {
			if row_col.name == pg_col.name {
				match = true
				field_ptr := mem.ptr_offset(transmute([^]u8)struct_ptr, pg_col.field.offset)

				base := runtime.type_info_base(pg_col.field.type)
				u, is_union := base.variant.(runtime.Type_Info_Union)

				#partial switch ti in base.variant {
				case (runtime.Type_Info_Integer):
					value, err := scan(rows, int, i)
					if err == nil {
						ip := cast(^int)(field_ptr)
						ip^ = value.(int)
					}
				case (runtime.Type_Info_String):
					value, err := scan(rows, string, i)
					if err == nil {
						str := value.(string)
						sp := cast(^string)(field_ptr)
						sp^ = strings.clone(str)
					}
				case (runtime.Type_Info_Union):
					if is_union {
						// Handle union types
						if len(u.variants) == 1 {
							// Single-variant union, treat like a normal field
							variant := u.variants[0]
							switch variant {
							case type_info_of(int):
								value, err := scan(rows, int, i)
								if err == nil {
									ip := cast(^int)(field_ptr)
									ip^ = value.(int)
								}

							case type_info_of(string):
								value, err := scan(rows, string, i)
								if err == nil {
									str := value.(string)
									sp := cast(^any)(field_ptr)
									sp.data = raw_data(strings.clone(str)) // fixme: leaks
									sp.id = string
									fmt.println("str", str)
								}
							}
						} else {
							// Multi-variant union: find the correct variant based on type
							for variant, idx in u.variants {
								tag_ptr := mem.ptr_offset(struct_ptr, u.tag_offset)
								tag := cast(^int)(tag_ptr)

								// Match the variant type
								#partial switch variant in base.variant {
								case runtime.Type_Info_Integer:
									value, err := scan(rows, int, i)
									if err == nil {
										ip := cast(^int)(field_ptr)
										ip^ = value.(int)
										tag^ = idx // Set the tag to indicate the union variant
									}
								case runtime.Type_Info_String:
									value, err := scan(rows, string, i)
									if err == nil {
										str := value.(string)
										sp := cast(^string)(field_ptr)
										sp^ = strings.clone(str)
										tag^ = idx // Set the tag to indicate the union variant
									}
								// Handle other types as needed
								}
							}
						}
					}
				case:
					fmt.eprintln("Unsupported type for field:", pg_col.name)
				}
			}
		}
		if !match {
			fmt.eprintln("No matching field for column:", row_col.name)
		}
	}
	return val
}


import rf "core:reflect"

PG_Col :: struct {
	name:  string, // Field name in struct or custom DB column name
	index: int, // Index of the field in the struct
	field: rf.Struct_Field,
}
get_pg_columns :: proc(T: typeid) -> []PG_Col {
	sfi := rf.struct_field_tags(T)
	pg_cols := make([]PG_Col, len(sfi)) // Preallocate an array for PG_Col

	// Iterate over the fields
	for tag, i in sfi {
		field := rf.struct_field_at(T, i)

		tag_str := string(tag)
		pg_i := strings.index(tag_str, "pg:")
		if pg_i != -1 {
			// Extract the pg tag value
			s_at_pg := tag_str[pg_i + 4:] // Skip "pg:\""
			q_i := strings.index(s_at_pg, "\"")
			if q_i != -1 {
				pg_name := s_at_pg[:q_i]
				pg_cols[i] = PG_Col {
					name  = pg_name,
					index = i,
					field = field,
				}
			}
		} else {
			// If no `pg` tag, use the field name as the default
			pg_cols[i] = PG_Col {
				name  = field.name,
				index = i,
				field = field,
			}
		}
	}

	return pg_cols
}

// Reads text_mode values from Postgres
//
// Allocates [] types
@(private)
parse_text :: proc(str: string, $T: typeid) -> (val: T, err: QueryError) {
	when T == bool {
		val = str[0] == 't' ? true : false
		return val, .None
	}
	when T == int {
		ival, iok := strconv.parse_int(str)
		if !iok {fmt.panicf("Expected int, got: '%v'.", str)}
		val = ival
		return val, .None
	}
	when T == uint {
		ival, uok := strconv.parse_uint(str)
		if !uok {fmt.panicf("Expected uint, got: '%v'.", str)}
		val = ival
		return val, .None
	}
	when T == f32 {
		fval, fok := strconv.parse_f32(str)
		if !fok {fmt.panicf("Expected f32, got: '%v'.", str)}
		val = fval
		return val, .None
	}
	when T == f64 {
		fval, fok := strconv.parse_f64(str)
		if !fok {fmt.panicf("Expected f64, got: '%v'.", str)}
		val = fval
		return val, .None
	}
	when T == string {
		val = strings.clone(str)
		return val, .None
	}

	fmt.println("...")
	return val, .UnknownType // Unsupported type, return false for ok

}

@(private)
format_sql_with_args :: proc(sql: string, args: ..any) -> string {
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
convert_to_sql_value :: proc(arg: any) -> string {
	switch a in arg {
	case string:
		return fmt.aprintf("'%s'", a)
	case int, i8, i16, i32, i64:
		return fmt.aprintf("%d", a)
	case uint, u8, u16, u32, u64:
		return fmt.aprintf("%d", a)
	case f16, f32, f64:
		return fmt.aprintf("%v", a)
	case:
		return "NULL"
	}
}



count_args :: proc(query: string) -> int {
	n_args := 0
	i := 0

	for i < len(query) {
		if query[i] == '$' {
			j := i + 1
			arg_num := 0

			// Try to assmble a number of char seq:
			for j < len(query) && query[j] >= '0' && query[j] <= '9' {
				arg_num = arg_num * 10 + int(query[j] - '0')
				j += 1
			}

			if arg_num > n_args {
				n_args = arg_num
			}

			i = j
		} else {
			i += 1
		}
	}

	return n_args
}
