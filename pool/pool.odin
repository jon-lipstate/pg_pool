package pg_pool

import pq "../vendor/odin-postgresql"
import "base:intrinsics"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:reflect"
import rf "core:reflect"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import dt "core:time/datetime"

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
	//
	base_allocator:     mem.Allocator, // what was passed to init
	cnx_backing:        []byte, // allocated by base_allocator
	cnx_allocator:      mem.Buddy_Allocator,
}

Connection :: struct {
	cnx:               pq.Conn,
	created_at:        time.Time,
	last_active:       time.Time,
	arena:             mem.Arena,
	allocator:         mem.Allocator,
	// Memory tracking
	arena_size:        uint, // Total arena size allocated
	peak_used:         uint, // High water mark for this connection
	last_used:         uint, // Memory used by last query
	// Transaction state
	transaction_depth: int, // 0 = no tx, 1 = BEGIN, 2+ = savepoints
	in_use_by_tx:      bool, // True when connection is held by a transaction
}

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
	
	// Free all connections directly without trying to remove from lists
	for cnx in POOL.active_connections {
		if cnx != nil && cnx.cnx != nil {
			pq.finish(cnx.cnx)
		}
		free(cnx, POOL.base_allocator)
	}
	for cnx in POOL.idle_connections {
		if cnx != nil && cnx.cnx != nil {
			pq.finish(cnx.cnx)
		}
		free(cnx, POOL.base_allocator)
	}
	
	delete(POOL.active_connections)
	delete(POOL.idle_connections)
	delete(POOL.cnx_backing)
	return nil
}

// postgres://user:password@localhost:5432/mydb?sslmode=disable&application_name=myapp
@(private)
parse_connection_string :: proc(str: string) -> (config: Config, ok: bool) {
	config = Config {
		connection_string = strings.clone_to_cstring(str),
		runtime_params    = make(map[string]string),
	}

	scheme, host, path, queries, fragment := net.split_url(str)
	// Only queries map is allocated, other strings are slices into the original

	if scheme != "postgres" && scheme != "postgresql" {
		delete(queries) // Clean up queries if we're returning early
		return config, false
	}

	// Extract userinfo (user:password) and host:port
	userinfo_host := strings.split(host, "@")
	defer delete(userinfo_host)
	if len(userinfo_host) != 2 {
		delete(queries) // Clean up queries if we're returning early
		return config, false // Missing authentication
	}
	remaining_host := userinfo_host[1]

	user_password := strings.split(userinfo_host[0], ":")
	defer delete(user_password)
	if len(user_password) >= 1 {
		config.user = strings.clone(user_password[0])
		if len(user_password) >= 2 {
			config.password = strings.clone(user_password[1])
		}
	}

	host_port := strings.split(remaining_host, ":")
	defer delete(host_port)
	config.host = strings.clone(host_port[0])
	if len(host_port) == 2 {
		port_val, port_ok := strconv.parse_int(host_port[1])
		if !port_ok || port_val < 0 || port_val > 65535 {
			delete(queries) // Clean up queries if we're returning early
			return config, false
		}
		config.port = u16(port_val)
	} else {
		config.port = 5432 // default port
	}

	// Database name
	if len(path) > 1 {
		config.database = strings.clone(path[1:]) // Strip leading '/'
	}

	// Copy query parameters to config
	for key, value in queries {
		config.runtime_params[strings.clone(key)] = strings.clone(value)
	}
	delete(queries)

	return config, true
}

@(private)
destroy_config :: proc(config: ^Config) {
	delete(config.connection_string)
	delete(config.host)
	delete(config.database)
	delete(config.user)
	delete(config.password)

	// Free all keys and values in runtime_params
	for key, value in config.runtime_params {
		delete(key)
		delete(value)
	}
	delete(config.runtime_params)

	when ODIN_DEBUG {config^ = {}}
}

@(private)
set_connection_arena :: proc(cnx: ^Connection, allocation_size: uint) -> Error {
	buf, err := mem.buddy_allocator_alloc_bytes(&POOL.cnx_allocator, allocation_size)
	if err != nil {return err}
	mem.arena_init(&cnx.arena, buf)
	cnx.allocator = mem.arena_allocator(&cnx.arena)
	cnx.arena_size = allocation_size
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
	if cnx == nil || cnx.cnx == nil {
		// Already released or nil connection
		return nil
	}

	sync.lock(&POOL.lock)
	defer sync.unlock(&POOL.lock)

	// Track memory usage before clearing
	cnx.last_used = uint(cnx.arena.offset)
	if cnx.last_used > cnx.peak_used {
		cnx.peak_used = cnx.last_used
	}

	err := mem.buddy_allocator_free(&POOL.cnx_allocator, &cnx.arena.data[0])

	did_pop := pop_connection(&POOL.active_connections, cnx)
	assert(did_pop, "released a non-active connection")
	append(&POOL.idle_connections, cnx)

	ok := validate_connection(cnx)
	if ok {
		sync.cond_signal(&POOL.cond)
	} else {
		destroy_connection_unlocked(cnx)
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
	destroy_connection_unlocked(cnx)
}

@(private)
destroy_connection_unlocked :: proc(cnx: ^Connection) {
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
// Pool statistics for monitoring and tuning
Pool_Stats :: struct {
	active_connections: int,
	idle_connections:   int,
	total_connections:  int,
	min_size:           int,
	max_size:           int,
	// Memory stats from all connections
	total_memory:       uint, // Total memory allocated to all arenas
	peak_memory_used:   uint, // Highest peak across all connections
	avg_last_used:      uint, // Average memory used in recent queries
}

get_pool_stats :: proc() -> Pool_Stats {
	sync.lock(&POOL.lock)
	defer sync.unlock(&POOL.lock)

	stats := Pool_Stats {
		active_connections = len(POOL.active_connections),
		idle_connections   = len(POOL.idle_connections),
		min_size           = POOL.min_size,
		max_size           = POOL.max_size,
	}
	stats.total_connections = stats.active_connections + stats.idle_connections

	// Gather memory stats
	total_last_used: uint = 0
	query_count := 0

	for cnx in POOL.active_connections {
		stats.total_memory += cnx.arena_size
		if cnx.peak_used > stats.peak_memory_used {
			stats.peak_memory_used = cnx.peak_used
		}
		if cnx.last_used > 0 {
			total_last_used += cnx.last_used
			query_count += 1
		}
	}

	for cnx in POOL.idle_connections {
		stats.total_memory += cnx.arena_size
		if cnx.peak_used > stats.peak_memory_used {
			stats.peak_memory_used = cnx.peak_used
		}
		if cnx.last_used > 0 {
			total_last_used += cnx.last_used
			query_count += 1
		}
	}

	if query_count > 0 {
		stats.avg_last_used = total_last_used / uint(query_count)
	}

	return stats
}

// Get memory info for a specific query result
get_query_memory :: proc(rows: ^Rows) -> (used: uint, allocated: uint) {
	if rows.cnx != nil {
		used = uint(rows.cnx.arena.offset)
		allocated = rows.cnx.arena_size
	}
	return
}

// Call for periodic pool maintainance 
maintainance :: proc() {
	sync.lock(&POOL.lock)
	defer sync.unlock(&POOL.lock)
	#reverse for cnx in POOL.idle_connections {
		time_elapsed := time.since(cnx.last_active)
		if time_elapsed > POOL.max_idle_time {
			destroy_connection_unlocked(cnx) // TODO: should i destroy or just reset??
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
	// NOTE: Expects caller to already have locked the pool
	total_connections := len(POOL.active_connections) + len(POOL.idle_connections)

	downsize: for total_connections > POOL.max_size {
		if len(POOL.idle_connections) > 0 {
			cnx := pop(&POOL.idle_connections)
			destroy_connection_unlocked(cnx)
		} else {break downsize}
	}
	upsize: for i := total_connections; i < POOL.min_size; i += 1 {
		cnx, ok := create_new_connection()
		if !ok {return false}
		append(&POOL.idle_connections, cnx)
	}
	return true
}

Rows :: struct {
	result:          pq.Result,
	cnx:             ^Connection,
	current_row:     int,
	columns:         []Column_Metadata,
	row_count:       int,
	owns_connection: bool, // If true, release connection when done
}
Column_Metadata :: struct {
	name:      string,
	oid:       pq.OID,
	text_mode: bool,
}


query :: proc(
	sql: string,
	cnx: ^Connection = nil,
	arena_size: uint = 64 * mem.Kilobyte,
	types: []Postgres_Type = nil,
	args: ..any,
) -> (
	Rows,
	Error,
) {
	// Check if connection was already released
	if cnx != nil && cnx.cnx == nil {
		return {}, db_error(.ConnectionError, "Connection already released")
	}

	should_release := false
	actual_cnx := cnx
	if actual_cnx == nil {
		// No connection provided, acquire from pool
		err: Error
		actual_cnx, err = acquire(arena_size)
		if err != nil {
			fmt.eprintln("query error:", err)
			return {}, .FailedToAcquireConnection
		}
		should_release = true
	} else {
		actual_cnx = cnx
	}

	// Always use the connection's arena allocator
	context.allocator = actual_cnx.allocator

	c_sql := strings.clone_to_cstring(sql)
	n_args := count_args(sql)
	ep := make_exec_params(n_args)
	defer delete_exec_params(&ep)

	for arg, i in args {
		type := types != nil ? &types[i] : nil
		set_exec_param(&ep, i, arg, type)
	}

	p_types := n_args > 0 ? &ep.types[0] : nil
	p_lens := n_args > 0 ? &ep.lengths[0] : nil
	p_formats := n_args > 0 ? &ep.formats[0] : nil
	value_ptrs := get_value_ptrs(ep.values, ep.lengths)
	p_values := n_args > 0 ? transmute([^][^]byte)&value_ptrs[0] : nil
	defer if value_ptrs != nil {delete(value_ptrs)}

	result := pq.exec_params(
		actual_cnx.cnx,
		c_sql,
		i32(n_args),
		p_types,
		p_values,
		p_lens,
		p_formats,
		.Text,
	) // FIXME: SWITCH TO BINARY RETURNS

	if result == nil || pq.result_status(result) != pq.Exec_Status.Tuples_OK {
		err := db_error_from_msg(actual_cnx)
		if should_release {
			release(actual_cnx)
		}
		return {}, err
	}

	rows, rows_err := result_into_rows(actual_cnx, result)
	if rows_err != nil {
		if should_release {
			release(actual_cnx)
		}
		return {}, rows_err
	}
	// If we acquired from pool, mark rows to release connection when done
	if should_release {
		rows.owns_connection = true
	}
	return rows, nil
}

Exec_Params :: struct {
	types:   []pq.OID,
	values:  [dynamic]byte, // this is backing buffer; exec_params uses [] of ptrs
	lengths: []i32,
	formats: []pq.Format,
}
@(private)
make_exec_params :: proc(n_params: int, allocator := context.allocator) -> Exec_Params {
	return Exec_Params {
		types = make([]pq.OID, n_params, allocator),
		values = make([dynamic]byte, allocator),
		lengths = make([]i32, n_params, allocator),
		formats = make([]pq.Format, n_params, allocator),
	}
}
@(private)
delete_exec_params :: proc(ep: ^Exec_Params) {
	assert(ep != nil)
	delete(ep.types)
	delete(ep.values)
	delete(ep.lengths)
	delete(ep.formats)
}


set_exec_param :: proc(
	ep: ^Exec_Params,
	i: int,
	param: any,
	type: ^Postgres_Type = nil,
) -> (
	err: Error,
) {
	oid: pq.OID
	// Use text format for all types until binary encoding is debugged
	format: pq.Format = .Text
	if type != nil {
		oid = type.oid
		format = type.format
	} else {
		oid = get_oid(param.id)
	}
	ep.types[i] = oid
	ep.formats[i] = format
	ep.lengths[i], err = copy_into_buf(&ep.values, param, oid, format, type)
	if err != nil {return}

	return
}
get_value_ptrs :: proc(
	backing: [dynamic]byte,
	lens: []i32,
	allocator := context.allocator,
) -> [][^]byte {
	if len(lens) == 0 {
		return nil // No parameters
	}

	buf := make([dynamic][^]byte, len(lens), allocator)

	offset := 0
	for length, i in lens {
		if length == -1 {
			// NULL parameter
			buf[i] = nil
		} else if length == 0 {
			// Empty string - still needs a pointer to empty buffer
			// PostgreSQL distinguishes between NULL and empty string
			if offset < len(backing) {
				buf[i] = &backing[offset]
				offset += 1 // Just the null terminator
			} else {
				buf[i] = nil
			}
		} else {
			if offset >= len(backing) {
				fmt.eprintln(
					"ERROR: offset",
					offset,
					">= backing len",
					len(backing),
					"at param",
					i,
				)
				fmt.eprintln("Lengths:", lens)
				panic("Buffer overflow in get_value_ptrs")
			}
			buf[i] = &backing[offset]
			// Skip past the data AND the null terminator for text format
			// The length doesn't include the null terminator, but it's in the buffer
			offset += int(length) + 1 // +1 for null terminator
		}
	}

	return buf[:]
}

to_bytes :: #force_inline proc(v: $T) -> []byte {
	// NOTE: Must be #force_inline, or it needs to allocate
	v := v
	p := &v
	bytes := (transmute([^]byte)p)[:size_of(T)]
	// fmt.println("coverted v to bytes",v,bytes)
	return bytes
}

@(private)
extract_oids :: proc(types: []Type_Decl) -> []pq.OID {
	if len(types) == 0 {return nil}

	oids := make([]pq.OID, len(types))
	for type, i in types {
		switch t in type {
		case typeid:
			oids[i] = get_oid(t)
		case Postgres_Type:
			oids[i] = t.oid
		case pq.OID:
			oids[i] = t
		}
	}
	return oids
}

@(private)
result_into_rows :: proc(cnx: ^Connection, result: pq.Result) -> (rows: Rows, err: Error) {
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
	rows = Rows {
		result      = result,
		cnx         = cnx,
		current_row = -1, // Start before first row; call next_row() to advance
		row_count   = row_count,
		columns     = columns,
	}
	return rows, nil
}

@(private)
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
	// Only release connection if we own it (acquired from pool for this query)
	if rows.owns_connection {
		release(rows.cnx)
	}
}

// Advance to the next row. Must be called before first scan.
// Usage:
//   rows, _ := query("SELECT ...")
//   defer release_query(&rows)
//   for next_row(&rows) {
//       val, _ := scan(&rows, int, 0)
//   }
// NOTE: scan() allocates strings/slices using context.allocator, not the connection's arena.
//       Use an arena allocator in your handler for automatic cleanup.
next_row :: proc(rows: ^Rows) -> (ok: bool) {
	if rows.current_row >= rows.row_count - 1 {
		return false
	}
	rows.current_row += 1
	return true
}
// QueryRow-style API that returns a single row result into a struct
// Usage: user := pool.query_row_into("SELECT * FROM users WHERE id = $1", User, args={1})
query_row_into :: proc(
	sql: string,
	$T: typeid,
	cnx: ^Connection = nil,
	arena_size: uint = 16 * mem.Kilobyte,
	types: []Postgres_Type = nil,
	args: ..any,
) -> (
	result: T,
	err: Error,
) {
	rows, qerr := query(sql, cnx, arena_size, types, args = args)
	if qerr != nil {return {}, qerr}
	defer release_query(&rows)

	if rows.row_count == 0 {return {}, .NoRows}
	if !next_row(&rows) {return {}, .NoRows}

	return scan_into(&rows, T), nil
}


PG_Col :: struct {
	name:  string, // Field name in struct or custom DB column name specified by tag `pg:the_name`
	index: int, // Index of the field in the struct
	field: rf.Struct_Field,
}
// Extract either the tag `pg:the_name`, or the struct field's name
@(private)
get_pg_columns :: proc(T: typeid) -> []PG_Col {
	sfi := rf.struct_field_tags(T)
	pg_cols := make([]PG_Col, len(sfi))

	for tag, i in sfi {
		field := rf.struct_field_at(T, i)

		tag_str := string(tag)
		pg_i := strings.index(tag_str, "pg:\"")
		if pg_i != -1 {
			s_at_pg := tag_str[pg_i + 4:] // Skip "pg:\""
			q_i := strings.index(s_at_pg, "\"")
			if q_i != -1 {
				pg_name := s_at_pg[:q_i]
				pg_cols[i] = PG_Col {
					name  = pg_name,
					index = i,
					field = field,
				}
			} else {
				// Malformed tag, use field name
				pg_cols[i] = PG_Col {
					name  = field.name,
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


// Helper for single-row queries
query_row :: proc(
	sql: string,
	cnx: ^Connection = nil,
	arena_size: uint = 16 * mem.Kilobyte,
	types: []Postgres_Type = nil,
	args: ..any,
) -> (
	Rows,
	Error,
) {
	rows, err := query(sql, cnx, arena_size, types, args = args)
	if err != nil {return {}, err}
	if rows.row_count == 0 {
		release_query(&rows)
		return {}, .NoRows
	}
	if !next_row(&rows) {
		release_query(&rows)
		return {}, .NoRows
	}
	return rows, nil
}

// Execute a query that doesn't return rows (INSERT/UPDATE/DELETE)
exec :: proc(
	sql: string,
	cnx: ^Connection = nil,
	types: []Postgres_Type = nil,
	args: ..any,
) -> (
	affected_rows: int,
	err: Error,
) {
	// Check if connection was already released
	if cnx != nil && cnx.cnx == nil {
		return 0, db_error(.ConnectionError, "Connection already released")
	}

	should_release := false
	actual_cnx := cnx
	if actual_cnx == nil {
		// No connection provided, acquire from pool
		acq_err: Error
		actual_cnx, acq_err = acquire()
		if acq_err != nil {
			return 0, acq_err
		}
		should_release = true
		defer if should_release {release(actual_cnx)}
	} else {
		actual_cnx = cnx
	}

	// Always use the connection's arena allocator
	context.allocator = actual_cnx.allocator

	c_sql := strings.clone_to_cstring(sql)
	n_args := count_args(sql)
	ep := make_exec_params(n_args)
	defer delete_exec_params(&ep)

	for arg, i in args {
		type := types != nil ? &types[i] : nil
		set_exec_param(&ep, i, arg, type)
	}

	p_types := n_args > 0 ? &ep.types[0] : nil
	p_lens := n_args > 0 ? &ep.lengths[0] : nil
	p_formats := n_args > 0 ? &ep.formats[0] : nil
	value_ptrs := get_value_ptrs(ep.values, ep.lengths)
	p_values := n_args > 0 ? transmute([^][^]byte)&value_ptrs[0] : nil
	defer if value_ptrs != nil {delete(value_ptrs)}


	result := pq.exec_params(
		actual_cnx.cnx,
		c_sql,
		i32(n_args),
		p_types,
		p_values,
		p_lens,
		p_formats,
		.Text,
	)

	if result == nil {
		err = db_error_from_msg(cnx)
		return 0, err
	}
	defer pq.clear(result)

	status := pq.result_status(result)
	if status != pq.Exec_Status.Command_OK {
		err = db_error_from_msg(cnx)
		return 0, err
	}

	cmd_tag := pq.cmd_tuples(result)
	if cmd_tag != nil {
		affected, _ := strconv.parse_int(string(cmd_tag))
		return affected, nil
	}
	return 0, nil
}

// Begin a transaction, or create a savepoint if already in a transaction
begin :: proc(cnx: ^Connection = nil) -> (^Connection, Error) {
	if cnx == nil {
		// New transaction - acquire connection and BEGIN
		err: Error
		new_cnx: ^Connection
		new_cnx, err = acquire()
		if err != nil {
			return nil, err
		}

		result := pq.exec(new_cnx.cnx, "BEGIN")
		if result == nil {
			release(new_cnx)
			return nil, db_error_from_msg(new_cnx)
		}
		pq.clear(result)

		new_cnx.transaction_depth = 1
		new_cnx.in_use_by_tx = true
		return new_cnx, nil
	} else if cnx.transaction_depth > 0 {
		// Nested transaction - use savepoint
		cnx.transaction_depth += 1
		savepoint_name := fmt.tprintf("sp_%d", cnx.transaction_depth)

		c_sql := strings.clone_to_cstring(fmt.tprintf("SAVEPOINT %s", savepoint_name))
		defer delete(c_sql)
		result := pq.exec(cnx.cnx, c_sql)
		if result == nil {
			return nil, db_error_from_msg(cnx)
		}
		pq.clear(result)

		return cnx, nil
	} else {
		// Connection exists but not in transaction - start one
		result := pq.exec(cnx.cnx, "BEGIN")
		if result == nil {
			return nil, db_error_from_msg(cnx)
		}
		pq.clear(result)

		cnx.transaction_depth = 1
		cnx.in_use_by_tx = true
		return cnx, nil
	}
}

// Commit a transaction or release a savepoint
commit :: proc(cnx: ^Connection) -> Error {
	if cnx == nil || cnx.cnx == nil {
		return db_error(.ConnectionError, "Connection already released")
	}
	if !cnx.in_use_by_tx {
		return db_error(.ConnectionError, "Connection not owned by transaction")
	}
	if cnx.transaction_depth == 0 {
		return db_error(.ConnectionError, "Not in a transaction")
	}

	if cnx.transaction_depth > 1 {
		// Release savepoint
		savepoint_name := fmt.tprintf("sp_%d", cnx.transaction_depth)
		c_sql := strings.clone_to_cstring(fmt.tprintf("RELEASE SAVEPOINT %s", savepoint_name))
		defer delete(c_sql)
		result := pq.exec(cnx.cnx, c_sql)
		if result == nil {
			return db_error_from_msg(cnx)
		}
		pq.clear(result)
		cnx.transaction_depth -= 1
	} else {
		// Commit actual transaction
		result := pq.exec(cnx.cnx, "COMMIT")
		if result == nil {
			return db_error_from_msg(cnx)
		}
		pq.clear(result)
		cnx.transaction_depth = 0
		cnx.in_use_by_tx = false
		release(cnx)
	}
	return nil
}

// Rollback a transaction or to a savepoint
// Safe to call after commit (will be a no-op)
rollback :: proc(cnx: ^Connection) -> Error {
	if cnx == nil || cnx.cnx == nil || !cnx.in_use_by_tx || cnx.transaction_depth == 0 {
		return nil // Safe no-op for defer pattern
	}

	if cnx.transaction_depth > 1 {
		// Rollback to savepoint
		savepoint_name := fmt.tprintf("sp_%d", cnx.transaction_depth)
		c_sql := strings.clone_to_cstring(fmt.tprintf("ROLLBACK TO SAVEPOINT %s", savepoint_name))
		defer delete(c_sql)
		result := pq.exec(cnx.cnx, c_sql)
		if result == nil {
			return db_error_from_msg(cnx)
		}
		pq.clear(result)
		cnx.transaction_depth -= 1
	} else {
		// Rollback entire transaction
		result := pq.exec(cnx.cnx, "ROLLBACK")
		// Even if this fails, we still release the connection
		if result != nil {
			pq.clear(result)
		}
		cnx.transaction_depth = 0
		cnx.in_use_by_tx = false
		release(cnx)
	}
	return nil
}

// Search Query-String for the highest value of $i
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
