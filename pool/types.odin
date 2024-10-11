package pg_pool

// import pq "../vendor/odin-postgresql"
// import "core:fmt"
// import "core:strings"

// TypCategory :: enum rune {
// 	Array       = 'A', // Array types
// 	Boolean     = 'B', // Boolean types
// 	Composite   = 'C', // Composite types (e.g., row structures)
// 	DateTime    = 'D', // Date/time types
// 	Enum        = 'E', // Enum types (custom enumerated types)
// 	Geometric   = 'G', // Geometric types
// 	Network     = 'I', // Network address types
// 	Numeric     = 'N', // Numeric types
// 	Pseudo      = 'P', // Pseudo types (e.g., record, void)
// 	String      = 'S', // String types (e.g., text, varchar)
// 	Timespan    = 'T', // Timespan types (e.g., interval)
// 	UserDefined = 'U', // User-defined types
// 	BitString   = 'V', // Bit-string types
// 	Unknown     = 'X', // Unknown types
// 	Polymorphic = 'Z', // Polymorphic types (e.g., anyelement, anyarray)
// }

// @(private)
// type_cache := map[pq.OID]DB_Type {
// 	16 = {oid = 16, name = "bool", n_bytes = 1, category = .Boolean},
// 	17 = {oid = 17, name = "bytea", n_bytes = -1, category = .UserDefined},
// 	18 = {oid = 18, name = "char", n_bytes = 1, category = .Polymorphic},
// 	19 = {oid = 19, name = "name", n_bytes = 64, category = .String},
// 	20 = {oid = 20, name = "int8", n_bytes = 8, category = .Numeric},
// 	21 = {oid = 21, name = "int2", n_bytes = 2, category = .Numeric},
// 	23 = {oid = 23, name = "int4", n_bytes = 4, category = .Numeric},
// 	25 = {oid = 25, name = "text", n_bytes = -1, category = .String},
// 	26 = {oid = 26, name = "oid", n_bytes = 4, category = .Numeric},
// 	700 = {oid = 700, name = "float4", n_bytes = 4, category = .Numeric},
// 	701 = {oid = 701, name = "float8", n_bytes = 8, category = .Numeric},
// 	1042 = {oid = 1042, name = "bpchar", n_bytes = -1, category = .String},
// 	1043 = {oid = 1043, name = "varchar", n_bytes = -1, category = .String},
// 	1082 = {oid = 1082, name = "date", n_bytes = 4, category = .DateTime},
// 	1114 = {oid = 1114, name = "timestamp", n_bytes = 8, category = .DateTime},
// 	1184 = {oid = 1184, name = "timestamptz", n_bytes = 8, category = .DateTime},
// }


// DB_Type :: struct {
// 	oid:      pq.OID,
// 	name:     string,
// 	n_bytes:  int,
// 	category: TypCategory,
// 	// odin_type: typeid,
// }


// describe_prepared_statement :: proc(cnx: ^Connection, name: string) -> bool {
// 	c_stmt_name := strings.clone_to_cstring(name, context.temp_allocator)
// 	defer free_all(context.temp_allocator)

// 	desc_res := pq.describe_prepared(cnx.cnx, c_stmt_name)
// 	if pq.result_status(desc_res) != pq.Exec_Status.Command_OK {
// 		fmt.eprintln("Describe failed:", pq.error_message(cnx.cnx))
// 		pq.clear(desc_res)
// 		return false
// 	}

// 	n_params := pq.n_params(desc_res)
// 	fmt.println("Number of parameters:", n_params)

// 	n_fields := pq.n_fields(desc_res)
// 	fmt.println("Number of result columns:", n_fields)

// 	for i in 0 ..< n_params {
// 		param_type := pq.param_type(desc_res, i)
// 		fmt.println("Parameter", i, "is of type OID", param_type)
// 	}

// 	for i in 0 ..< n_fields {
// 		field_type := pq.f_type(desc_res, i)
// 		fmt.println("Field", i, "is of type OID", field_type)
// 	}

// 	pq.clear(desc_res)

// 	return true
// }

// load_type_cache :: proc() {
// 	rows, ok := query("SELECT oid, typname, typlen, typcategory FROM pg_type")
// 	defer release_query(&rows)
// 	if !ok {
// 		fmt.eprintln("Failed to load type cache")
// 		return
// 	}

// 	for next_row(&rows) {
// 		oid: int
// 		type_name: string
// 		type_size: int
// 		type_category: rune
// 		scan_row(&rows, &oid, &type_name, &type_size, &type_category)
// 		OID := pq.OID(oid)
// 		type_cache[OID] = DB_Type{OID, type_name, type_size, transmute(TypCategory)type_category}
// 		fmt.println(type_cache[OID])
// 	}
// }

// fetch_type_info_from_db :: proc(oid: pq.OID) -> (name: string, n_bytes: int) {
// 	sql := fmt.tprintf("SELECT typname, typlen FROM pg_type WHERE oid = %v", oid)
// 	rows, ok := query(sql);defer release_query(&rows)
// 	if !ok {
// 		return "unknown", -1
// 	}

// 	type_name: string
// 	type_size: int
// 	scan_row(&rows, &type_name, &type_size)


// 	return type_name, type_size
// }
