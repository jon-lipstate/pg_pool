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

// GLOBAL POOL
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
	// init_sql runs once on every freshly-created libpq connection. Used
	// to set per-pool defaults like statement_timeout. Empty = no init.
	// Allocated by base_allocator (cloned from caller's string).
	init_sql:           string,
	//
	base_allocator:     mem.Allocator, // what was passed to init
	cnx_backing:        []byte, // allocated by base_allocator
	cnx_allocator:      mem.Buddy_Allocator,
}

Connection :: struct {
	cnx:                pq.Conn,
	created_at:         time.Time,
	last_active:        time.Time,
	arena:              mem.Arena,
	allocator:          mem.Allocator,
	// Memory tracking
	arena_size:         uint, // Total arena size allocated
	peak_used:          uint, // High water mark for this connection
	last_used:          uint, // Memory used by last query
	// Transaction state
	transaction_depth:  int, // 0 = no tx, 1 = BEGIN, 2+ = savepoints
	in_use_by_tx:       bool, // True when connection is held by a transaction
	// Query tracking to prevent deadlocks
	active_query_count: int, // Number of unreleased query results
}

/*
Initialize the global connection pool

Creates a pool of PostgreSQL connections that are reused across queries.
The pool maintains between min_connections and max_connections active connections.

Inputs:
- connection_string: PostgreSQL connection URL (e.g., "postgresql://user:pass@host/db")
- min_connections: Minimum number of idle connections to maintain (default: 4)
- max_connections: Maximum total connections allowed (default: 64)
- max_idle_mins: Minutes before closing idle connections (default: 5)
- total_cnx_memory: Total memory budget for all connection arenas (default: 16MB)
- connect_timeout_sec: How long libpq waits to establish a connection. Injected
  into the DSN as connect_timeout=N if not already present. 0 = libpq default
  (~∞, will hang on dead networks). Recommended: 10s.
- keepalives_idle_sec: TCP keepalive idle interval. When non-zero and the DSN
  doesn't already specify keepalives, injects keepalives=1 + keepalives_idle=N
  + keepalives_interval=10 + keepalives_count=3. Prevents cloud load balancers
  and server idle timeouts from closing connections beneath the pool.
  Recommended: 60s.
- tcp_user_timeout_ms: kernel-level TCP_USER_TIMEOUT — if any in-flight write
  goes unacknowledged for this many ms, the kernel kills the connection so
  libpq's poll() returns instead of hanging forever. Catches the gap that
  keepalives + PQstatus miss: a connection that LOOKED alive and accepted a
  write, then went silent mid-conversation. Linux libpq 12+ only; on other
  platforms this param is ignored. 0 = libpq default (kernel inherits, often
  many minutes). Recommended: 30000 (30s).
- init_sql: SQL to run once on every newly-created libpq connection. Used to
  set per-pool session defaults like `SET statement_timeout = '60s'`. Persists
  for the lifetime of that libpq session — releases/re-acquires keep it.
- allocator: Memory allocator for pool structures (default: context.allocator)

Returns:
- err: Error if initialization fails

Example:
	err := pool.init("postgresql://localhost/mydb", min_connections = 2, max_connections = 10)
	defer pool.destroy_pool()
*/
init :: proc(
	connection_string: string,
	min_connections: uint = 4,
	max_connections: uint = 64,
	max_idle_mins: uint = 5,
	total_cnx_memory: uint = 16 * mem.Megabyte,
	connect_timeout_sec: uint = 0,
	keepalives_idle_sec: uint = 0,
	tcp_user_timeout_ms: uint = 0,
	init_sql: string = "",
	allocator := context.allocator,
) -> (
	err: Error,
) {
	context.allocator = allocator

	// Inject DSN params if caller asked for non-default values and they
	// aren't already in the DSN. Done before parse so the stored config
	// has the augmented string.
	dsn := connection_string
	if connect_timeout_sec > 0 && !strings.contains(dsn, "connect_timeout") {
		sep := "?"
		if strings.contains(dsn, "?") do sep = "&"
		dsn = fmt.aprintf("%s%sconnect_timeout=%d", dsn, sep, connect_timeout_sec)
	}
	if keepalives_idle_sec > 0 && !strings.contains(dsn, "keepalives") {
		sep := "?"
		if strings.contains(dsn, "?") do sep = "&"
		// keepalives=1 enables TCP keepalive probes; idle=N is how long
		// the connection sits silent before the first probe; interval/count
		// control retry behavior — sane defaults for cloud DBs.
		dsn = fmt.aprintf("%s%skeepalives=1&keepalives_idle=%d&keepalives_interval=10&keepalives_count=3",
			dsn, sep, keepalives_idle_sec)
	}
	if tcp_user_timeout_ms > 0 && !strings.contains(dsn, "tcp_user_timeout") {
		sep := "?"
		if strings.contains(dsn, "?") do sep = "&"
		dsn = fmt.aprintf("%s%stcp_user_timeout=%d", dsn, sep, tcp_user_timeout_ms)
	}

	config, config_ok := parse_connection_string(dsn)
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
		init_sql           = strings.clone(init_sql),
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

/*
Destroy the global connection pool and release all resources.

Closes all active and idle connections, frees memory allocators.
This should be called when the application shuts down.

Returns:
- nil on success
- Error if cleanup fails

Usage:
    defer pool.destroy_pool()
*/
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

/*
Acquire a connection from the pool.

Returns an idle connection if available, or creates a new one if under max_size.
The connection's arena is sized according to allocation_size.

Inputs:
- allocation_size: Size of the arena allocator for this connection (default: 16KB)

Returns:
- ^Connection: Active connection ready for use
- Error: UnableToAcquireConnection if pool is exhausted or connection fails

Usage:
    cnx, err := pool.acquire()
    if err != nil { return err }
    defer pool.release(cnx)
*/
acquire :: proc(allocation_size: uint = 16 * mem.Kilobyte) -> (^Connection, Error) {
	sync.lock(&POOL.lock)
	defer sync.unlock(&POOL.lock)

	for len(POOL.idle_connections) > 0 {
		cnx := pop(&POOL.idle_connections)
		time_elapsed := time.since(cnx.created_at)
		if time_elapsed > POOL.max_life_time {
			destroy_connection_unlocked(cnx) // Use unlocked version since we hold lock
			continue
		}
		// Health-check before handing out: cloud LBs / server idle timeouts
		// can kill an idle connection without us noticing. Without this, the
		// next operation hangs in poll() waiting on a dead socket. PQstatus
		// is a local check (no network); PQconsumeInput + PQstatus catches
		// connections the server has closed.
		if pq.status(cnx.cnx) != pq.Connection_Status.Ok {
			destroy_connection_unlocked(cnx)
			continue
		}
		append(&POOL.active_connections, cnx)
		cnx.last_active = time.now()
		err := set_connection_arena(cnx, allocation_size) // Still inside lock
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

/*
Release a connection back to the pool.

Resets the connection state and returns it to the idle pool for reuse.
Safe to call with nil connections (no-op).

Inputs:
- cnx: Connection to release

Returns:
- nil on success
- Error if release fails
*/
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

	// Run init_sql once on every fresh libpq session. Used to set
	// per-pool session defaults (statement_timeout, search_path, etc).
	// Best-effort: if it fails we log and proceed — the session will
	// just run with libpq defaults.
	if POOL.init_sql != "" {
		c_init := strings.clone_to_cstring(POOL.init_sql)
		defer delete(c_init)
		init_result := pq.exec(pq_conn, c_init)
		if init_result == nil ||
		   pq.result_status(init_result) != pq.Exec_Status.Command_OK {
			fmt.eprintln("init_sql failed:", string(pq.error_message(pq_conn)))
		}
		if init_result != nil do pq.clear(init_result)
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
	}
	// Note: removed=false is fine — caller may have already popped the
	// connection out (e.g. acquire()'s idle-validation loop). What matters
	// is the libpq handle gets finished and the Odin struct freed; that
	// happens unconditionally below.
	if cnx.cnx != nil {
		pq.finish(cnx.cnx)
	}
	free(cnx, POOL.base_allocator)
}

@(private)
validate_connection :: proc(cnx: ^Connection) -> bool {
	if cnx == nil || cnx.cnx == nil {
		// Already torn down (or never initialised). Caller treats this
		// as "invalid" and routes through destroy — same effect as a
		// failed PQstatus, but without dereferencing a bad pointer.
		return false
	}
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

/*
Get current statistics about the connection pool.

Provides insight into pool utilization and memory usage.

Returns:
- Pool_Stats containing:
  - active_connections: Currently in use
  - idle_connections: Available for use
  - total_connections: Active + idle
  - min_size/max_size: Pool size limits
  - total_memory: Total allocated memory
  - peak_memory_used: Maximum memory ever used
  - avg_last_used: Average memory used in recent queries
*/
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

/*
Get memory usage information for a specific query result.

Useful for monitoring memory consumption of large result sets.

Inputs:
- rows: Query result to inspect

Returns:
- used: Bytes currently used by the result
- allocated: Total bytes allocated for the connection arena
*/
get_query_memory :: proc(rows: ^Rows) -> (used: uint, allocated: uint) {
	if rows.cnx != nil {
		used = uint(rows.cnx.arena.offset)
		allocated = rows.cnx.arena_size
	}
	return
}

/*
Perform periodic maintenance on the connection pool.

Removes idle connections that have exceeded max_idle_time.
Should be called periodically (e.g., every minute) to prevent stale connections.
*/
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

/*
Dynamically resize the connection pool limits.

Adjusts minimum and maximum pool size and rebalances connections.

Inputs:
- new_min_size: New minimum number of idle connections
- new_max_size: New maximum total connections

Note: Will attempt to rebalance the pool to meet new requirements.
*/
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
	formats: []pq.Format = nil,
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
				// Text format has null terminator, binary doesn't
				is_text := formats == nil || formats[i] == .Text
				offset += 1 if is_text else 0
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
			// Text format has null terminator, binary doesn't
			is_text := formats == nil || formats[i] == .Text
			offset += int(length) + (1 if is_text else 0)
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

	// Track active query on the connection
	cnx.active_query_count += 1

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

/*
Release resources associated with a query result.

Frees the result set and decrements the connection's active query count.
Should always be called when done with query results.

Inputs:
- rows: Query result to release

Usage:
    rows, err := pool.query("SELECT * FROM users")
    defer pool.release_query(&rows)
*/
release_query :: proc(rows: ^Rows) {
	if rows == nil {return}

	// Decrement active query count on the connection
	if rows.cnx != nil {
		rows.cnx.active_query_count -= 1
	}

	if rows.result != nil {
		pq.clear(rows.result)
	}
	// Only release connection if we own it (acquired from pool for this query)
	if rows.owns_connection {
		release(rows.cnx)
	}
}

/*
Advance to the next row in a query result set.

**Must be called before scanning the first row**

Inputs:
- rows: Query result to advance

Returns:
- true if a row is available
- false if no more rows

Usage:
    for pool.next_row(&rows) {
        id, _ := pool.scan(&rows, int, 0)
        // Process row...
    }
*/
next_row :: proc(rows: ^Rows) -> (ok: bool) {
	if rows.current_row >= rows.row_count - 1 {
		return false
	}
	rows.current_row += 1
	return true
}

/*
Execute a query and scan the first row directly into a struct.

Convenience function that combines query(), next_row(), and scan_into() for
single-row queries. Automatically maps columns to struct fields using reflection.

Inputs:
- sql: SQL query string with optional $1, $2... placeholders
- T: Struct type to scan into
- cnx: Optional connection (uses pool if nil)
- arena_size: Size for result arena (default: 16KB)
- types: Optional type hints for parameters
- args: Query parameters

Returns:
- result: Instance of T with fields populated from the row
- err: NoRows if empty, or other query/scanning errors

Field Mapping:
- Uses `pg:"column_name"` tags to map columns to fields
- Falls back to field name if no tag present
- Supports basic types, time.Time, arrays, and pointers

Usage:
    User :: struct {
        id:    int    `pg:"id"`,
        email: string `pg:"email"`,
        name:  string `pg:"name"`,
    }
    
    user, err := pool.query_row_into(
        "SELECT id, email, name FROM users WHERE id = $1",
        User,
        args = {42},
    )
    if err != nil { return err }
    defer delete(user.email)
    defer delete(user.name)

Note: Caller must free allocated strings and slices in the returned struct
*/
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

/*
Executes a query and returns a result set. The query uses binary format by default. Results must be released after use.

*Uses Connection Arena for Allocations*

Inputs:
- sql: SQL query string with optional $1, $2... placeholders
- cnx: Optional connection to use (default: acquires from pool)
- arena_size: Size of arena for result data (default: 64KB)
- types: Optional type hints for parameters
- result_format: Binary or Text format (default: Binary)
- args: Variadic arguments matching $1, $2... placeholders

Returns:
- Rows: Result set that must be released with release_query()
- Error: Query execution error

Example:
	rows, err := pool.query("SELECT id, name FROM users WHERE age > $1", args = {18})
	defer pool.release_query(&rows)
	
	for pool.next_row(&rows) {
	    id, _ := pool.scan(&rows, int, 0)
	    name, _ := pool.scan(&rows, string, 1)
	    defer delete(name)
	}

Thread Safety: Connection should not be shared between threads
*/
query :: proc(
	sql: string,
	cnx: ^Connection = nil,
	arena_size: uint = 64 * mem.Kilobyte,
	types: []Postgres_Type = nil,
	result_format: pq.Format = .Binary,
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
	value_ptrs := get_value_ptrs(ep.values, ep.lengths, ep.formats)
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
		result_format,
	)

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
	rows.owns_connection = should_release

	return rows, nil
}

/*
Execute a query expected to return exactly one row.

Convenience wrapper around query() for single-row results.

Inputs:
- sql: SQL query string
- cnx: Optional connection (uses pool if nil)
- arena_size: Size for result arena (default: 16KB)
- types: Optional type hints for parameters
- args: Query parameters

Returns:
- Rows: Result set positioned at first row
- Error: Query error or NoRows if empty

Usage:
    row, err := pool.query_row("SELECT * FROM users WHERE id = $1", args = {42})
    defer pool.release_query(&row)
*/
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

/*
Use for INSERT, UPDATE, DELETE, or DDL statements that don't return a result set.
Returns the number of affected rows for DML statements.

Inputs:
- sql: SQL statement with optional $1, $2... placeholders
- cnx: Optional connection to use (default: acquires from pool)
- types: Optional type hints for parameters
- args: Variadic arguments matching $1, $2... placeholders

Returns:
- affected_rows: Number of rows affected by the statement
- err: Execution error

Example:
	affected, err := pool.exec("UPDATE users SET active = $1 WHERE age < $2", args = {false, 18})
	fmt.printf("Updated %d users\n", affected)

Thread Safety: Connection should not be shared between threads
*/
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
		// Only warn for potentially dangerous operations, not normal DML in transactions
		if actual_cnx.active_query_count > 0 {
			// Check if this looks like a command that could cause deadlocks or issues
			sql_upper := strings.to_upper(strings.trim_space(sql), context.temp_allocator)

			// DDL commands that can lock tables
			is_ddl :=
				strings.has_prefix(sql_upper, "DROP") ||
				strings.has_prefix(sql_upper, "CREATE") ||
				strings.has_prefix(sql_upper, "ALTER") ||
				strings.has_prefix(sql_upper, "TRUNCATE") ||
				strings.has_prefix(sql_upper, "VACUUM") ||
				strings.has_prefix(sql_upper, "REINDEX") ||
				strings.has_prefix(sql_upper, "CLUSTER")

			// SET commands that affect transaction state (but not session settings like timezone)
			is_problematic_set :=
				strings.has_prefix(sql_upper, "SET TRANSACTION") ||
				strings.has_prefix(sql_upper, "SET CONSTRAINTS")

			if is_ddl {
				fmt.eprintln(
					"WARNING: Executing DDL command while there are",
					actual_cnx.active_query_count,
					"unreleased query results. This may cause deadlocks.",
				)
				fmt.eprintln(
					"         Make sure to call pool.release_query() before DDL commands.",
				)
			}

			when ODIN_DEBUG {
				// Only warn about these in debug mode as they're less critical
				if is_problematic_set {
					fmt.eprintln(
						"DEBUG WARNING: Executing SET command that affects transaction state while there are",
						actual_cnx.active_query_count,
						"unreleased query results.",
					)
					fmt.eprintln("              This may cause unexpected behavior.")
				}
			}
		}
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
	value_ptrs := get_value_ptrs(ep.values, ep.lengths, ep.formats)
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
		err = db_error_from_msg(actual_cnx)
		return 0, err
	}
	defer pq.clear(result)

	status := pq.result_status(result)
	if status != pq.Exec_Status.Command_OK {
		err = db_error_from_msg(actual_cnx)
		return 0, err
	}

	cmd_tag := pq.cmd_tuples(result)
	if cmd_tag != nil {
		affected, _ := strconv.parse_int(string(cmd_tag))
		return affected, nil
	}
	return 0, nil
}

/*
Begin a database transaction or create a savepoint.

If no connection provided, acquires one and starts a transaction.
If connection already in transaction, creates a nested savepoint.

Inputs:
- cnx: Optional existing connection (for nested transactions)

Returns:
- ^Connection: Connection with active transaction
- Error: If transaction start fails

Usage:
    tx, err := pool.begin()
    if err != nil { return err }
    defer pool.rollback(tx)  // Safe to defer - no-op after commit
    
    // Do work...
    pool.commit(tx)
*/
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
			// Capture the libpq error BEFORE release: if the BEGIN failed
			// because the connection went bad, release() will see it as
			// invalid via validate_connection() and call destroy_connection_unlocked()
			// which pq.finish()es the libpq handle and free()s the Odin
			// Connection struct. Reading new_cnx.cnx after that is UAF.
			err := db_error_from_msg(new_cnx)
			release(new_cnx)
			return nil, err
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

/*
Commit a transaction or release a savepoint.

For top-level transactions, commits all changes.
For nested savepoints, releases the savepoint.

Inputs:
- cnx: Connection with active transaction

Returns:
- nil on success
- Error if commit fails or not in transaction
*/
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

/*
Rollback a transaction or to a savepoint.

For top-level transactions, undoes all changes.
For nested savepoints, rolls back to the savepoint.
Safe to call after commit (no-op).

Inputs:
- cnx: Connection with active transaction

Returns:
- nil on success or if already committed
- Error if rollback fails

Note: Designed for defer pattern - always safe to defer.
*/
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
