package pg_pool

import pq "../vendor/odin-postgresql"
import "base:intrinsics"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:time"


// Scan column - handles both nullable and non-nullable types
// For pointer types: returns nil for NULL
// For non-pointer types: errors on NULL
//
// IMPORTANT: Memory allocation behavior
// - Strings and slices are allocated using the allocator parameter (defaults to context.allocator)
// - These allocations are NOT tied to the query/connection lifetime
// - Caller is responsible for freeing allocated memory or using an arena allocator
//
// Example with arena allocator (recommended for web handlers):
//   arena: mem.Arena
//   defer mem.arena_destroy(&arena)
//   context.allocator = mem.arena_allocator(&arena)
//   
//   rows := pool.query("SELECT name FROM users")
//   defer pool.release_query(&rows)
//   name, _ := pool.scan(&rows, string, 0)  // allocated in arena
//   // name is valid until arena is destroyed
//
scan :: proc(
	rows: ^Rows,
	$T: typeid,
	col: int,
	allocator := context.allocator,
) -> (
	val: T,
	err: Error,
) {
	context.allocator = allocator

	// Auto-advance on first scan if still at -1
	if rows.current_row == -1 {
		if !next_row(rows) {
			return {}, .NoRows
		}
	}

	target_row := i32(rows.current_row)

	// ensure in-bounds:
	if target_row < 0 || target_row >= i32(rows.row_count) {return {}, .OutOfBounds}
	if col < 0 || col >= len(rows.columns) {return {}, .OutOfBounds}

	if pq.get_is_null(rows.result, i32(rows.current_row), i32(col)) {
		// For pointer types and slices, return nil
		// For value types, return error
		when intrinsics.type_is_pointer(
			T,
		) || intrinsics.type_is_slice(T) || intrinsics.type_is_string(T) {
			return {}, QueryError.None // nil is valid for these types
		} else {
			return {}, QueryError.UnexpectedNullValue // Can't represent NULL in value type
		}
	}

	n_bytes := int(pq.f_size(rows.result, i32(col)))

	ptr := pq.get_value(rows.result, target_row, i32(col))

	if rows.columns[col].text_mode {
		str := cast(string)cstring(ptr)
		return parse_text(str, T, allocator)
	} else {
		if true do unimplemented("Binary Mode Scanning Not Implemented")
		return {}, .UnknownType
	}
}

// Utilizes RTTI to automatically match types by name; use `pg:` tags to otherwise match the names
scan_into :: proc(rows: ^Rows, $T: typeid, allocator := context.allocator) -> T {
	cols := get_pg_columns(T) // get `pg:` tagged columns, or use struct field names
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
				case runtime.Type_Info_Integer:
					// Handle different integer sizes
					if ti.signed {
						switch base.size {
						case 2:
							value, err := scan(rows, i16, i)
							if err == nil {
								p := cast(^i16)(field_ptr)
								p^ = value
							}
						case 4:
							value, err := scan(rows, i32, i)
							if err == nil {
								p := cast(^i32)(field_ptr)
								p^ = value
							}
						case 8:
							value, err := scan(rows, i64, i)
							if err == nil {
								p := cast(^i64)(field_ptr)
								p^ = value
							}
						case:
							value, err := scan(rows, int, i)
							if err == nil {
								p := cast(^int)(field_ptr)
								p^ = value
							}
						}
					} else {
						// Unsigned integers - convert from signed
						value, err := scan(rows, int, i)
						if err == nil {
							up := cast(^uint)(field_ptr)
							up^ = uint(value)
						}
					}
				case runtime.Type_Info_Float:
					switch base.size {
					case 4:
						value, err := scan(rows, f32, i)
						if err == nil {
							p := cast(^f32)(field_ptr)
							p^ = value
						}
					case 8:
						value, err := scan(rows, f64, i)
						if err == nil {
							p := cast(^f64)(field_ptr)
							p^ = value
						}
					}
				case runtime.Type_Info_Boolean:
					value, err := scan(rows, bool, i)
					if err == nil {
						bp := cast(^bool)(field_ptr)
						bp^ = value
					}
				case runtime.Type_Info_String:
					value, err := scan(rows, string, i)
					if err == nil {
						sp := cast(^string)(field_ptr)
						sp^ = value
					}
				case runtime.Type_Info_Pointer:
					unimplemented("Pointer fields in structs not yet supported in scan_into")
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
									ip^ = value
								}

							case type_info_of(string):
								value, err := scan(rows, string, i)
								if err == nil {
									sp := cast(^any)(field_ptr)
									sp.data = raw_data(strings.clone(value)) // fixme: leaks
									sp.id = string
									fmt.println("str", value)
								}
							}
						} else {
							// Multi-variant union: find the correct variant based on type
							for variant, idx in u.variants {
								tag_ptr := mem.ptr_offset(struct_ptr, u.tag_offset)
								tag := cast(^int)(tag_ptr)

								#partial switch variant in base.variant {
								case runtime.Type_Info_Integer:
									value, err := scan(rows, int, i)
									if err == nil {
										ip := cast(^int)(field_ptr)
										ip^ = value
										tag^ = idx
									}
								case runtime.Type_Info_String:
									value, err := scan(rows, string, i)
									if err == nil {
										sp := cast(^string)(field_ptr)
										sp^ = strings.clone(value)
										tag^ = idx
									}
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

// Reads .Text mode returned values
//
// Allocates [] types incl strings
@(private)
parse_text :: proc(
	str: string,
	$T: typeid,
	allocator := context.allocator,
) -> (
	val: T,
	err: QueryError,
) {
	when T == bool {
		val = str[0] == 't' ? true : false
		return val, .None
	}
	when T == int || T == i32 || T == i64 || T == i16 || T == i8 {
		ival, iok := strconv.parse_int(str)
		if !iok {fmt.panicf("Expected int, got: '%v'.", str)}
		val = T(ival)
		return val, .None
	}
	when T == uint || T == u32 || T == u64 || T == u16 || T == u8 {
		ival, uok := strconv.parse_uint(str)
		if !uok {fmt.panicf("Expected uint, got: '%v'.", str)}
		val = T(ival)
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
		val = strings.clone(str, allocator)
		return val, .None
	}
	fmt.eprintln("Unknown type in parse_text:", typeid_of(T))
	return val, .UnknownType
}

@(private)
copy_into_buf :: proc(
	buf: ^[dynamic]byte,
	arg: any,
	oid: pq.OID,
	format: pq.Format,
	tid: ^Postgres_Type = nil,
) -> (
	size: i32,
	err: Error,
) {
	// First check for nil-able types
	actual_arg := arg
	ti := type_info_of(actual_arg.id)
	#partial switch info in ti.variant {
	case runtime.Type_Info_Pointer:
		// Check if pointer is nil
		ptr := (^rawptr)(arg.data)^
		if ptr == nil {
			return -1, nil // NULL
		}
		// Dereference and continue with the pointed-to value
		// Create an any from the dereferenced value
		actual_arg = any{ptr, info.elem.id}
	case runtime.Type_Info_Slice:
		// Check if slice is nil
		slice_ptr := cast(^runtime.Raw_Slice)arg.data
		if slice_ptr.data == nil {
			return -1, nil // NULL
		}
	// Non-nil slice, continue to encode it
	case runtime.Type_Info_Map:
		// Check if map is nil
		map_ptr := cast(^runtime.Raw_Map)arg.data
		if uintptr(map_ptr.data) == 0 {
			return -1, nil // NULL
		}
	// Non-nil map, continue to encode it
	case runtime.Type_Info_Dynamic_Array:
		// Check if dynamic array is nil
		dyn_ptr := cast(^runtime.Raw_Dynamic_Array)arg.data
		if dyn_ptr.data == nil {
			return -1, nil // NULL
		}
	// Non-nil dynamic array, continue
	}

	// Special case: rawptr
	if _, ok := ti.variant.(runtime.Type_Info_Pointer); ok {
		if ti.id == typeid_of(rawptr) {
			ptr := cast(^rawptr)arg.data
			if ptr^ == nil {
				return -1, nil // NULL
			}
		}
	}

	// For text format, convert to string representation
	if format == .Text {
		str: string
		switch v in actual_arg {
		case string:
			str = v
		case int, i32, i64, i16, i8:
			str = fmt.tprintf("%d", extract_int(actual_arg))
		case uint, u32, u64, u16, u8:
			str = fmt.tprintf("%d", actual_arg)
		case f32:
			str = fmt.tprintf("%f", v)
		case f64:
			str = fmt.tprintf("%f", v)
		case bool:
			str = v ? "t" : "f"
		case []byte:
			// For bytea type
			str = string(v)
		case:
			return 0, .UnknownType
		}
		p_bytes := transmute([]byte)str
		append(buf, ..p_bytes)
		// Add null terminator for text format - PostgreSQL expects C strings
		append(buf, 0)
		// Return length WITHOUT the null terminator
		return i32(len(str)), nil
	}

	// Binary format encoding
	switch oid {
	case OID_BOOL:
		append(buf, transmute(byte)extract_bool(actual_arg))
		size = 1
	case OID_INT2:
		p_bytes := to_bytes(i16be(extract_int(actual_arg)))
		append(buf, ..p_bytes)
		size = 2
	case OID_INT4:
		p_bytes := to_bytes(i32be(extract_int(actual_arg)))
		append(buf, ..p_bytes)
		size = 4
	case OID_INT8:
		p_bytes := to_bytes(i64be(extract_int(actual_arg)))
		append(buf, ..p_bytes)
		size = 8
	case OID_FLOAT4:
		p_bytes := to_bytes(f32be(actual_arg.(f32)))
		append(buf, ..p_bytes)
		size = 4
	case OID_FLOAT8:
		p_bytes := to_bytes(f64be(actual_arg.(f64)))
		append(buf, ..p_bytes)
		size = 8
	case OID_BYTEA:
		bytes := actual_arg.([]byte)
		append(buf, ..bytes)
		size = i32(len(bytes))
	case OID_TEXT, OID_VARCHAR:
		str := actual_arg.(string)
		p_bytes := transmute([]byte)str
		append(buf, ..p_bytes)
		size = i32(len(str))
	case:
		err = .UnknownType
	}
	return
}


//   Custom_Type_Handler :: struct {
//       oid: pq.OID,
//       encoder: proc(any) -> []byte,
//       decoder: proc([]byte) -> any,
//   }

//   custom_handlers: map[pq.OID]Custom_Type_Handler

get_oid :: proc(tid: typeid) -> (oid: pq.OID) {
	//   if handler, ok := custom_handlers[tid]; ok {
	//       return handler.oid
	//   }

	// Check if it's a pointer type and recursively get the underlying type
	ti := type_info_of(tid)
	if info, ok := ti.variant.(runtime.Type_Info_Pointer); ok {
		// For pointer types, recursively get the OID of the underlying type
		return get_oid(info.elem.id)
	}

	switch tid {
	case bool:
		return OID_BOOL
	case i16:
		return OID_INT2
	case i32, int:
		return OID_INT4
	case i64:
		return OID_INT8
	case f32:
		return OID_FLOAT4
	case f64:
		return OID_FLOAT8
	case string:
		return OID_TEXT
	case []byte:
		return OID_BYTEA
	case time.Time:
		return OID_TIMESTAMPTZ // OR  OID_TIMESTAMP
	// case time.Date:
	// 	return OID_DATE
	case json.Value:
		return OID_JSONB
	// case []bool:
	// 	return OID_ARR_BOOL
	case []i16:
		return OID_ARR_INT2
	case []int, []i32:
		return OID_ARR_INT4
	case []i64:
		return OID_ARR_INT8
	case []f32:
		return OID_ARR_FLOAT4
	case []f64:
		return OID_ARR_FLOAT8
	case []string:
		return OID_ARR_TEXT
	}
	fmt.println("Err - Unknown OID for typeid:", tid) // Handle unsupported types gracefully
	return OID_UNKNOWN
}

@(private)
extract_bool :: #force_inline proc(arg: any) -> bool {
	switch a in arg {
	case bool:
		return bool(a)
	case b16:
		return bool(a)
	case b32:
		return bool(a)
	case b64:
		return bool(a)
	case:
		panic("Invalid Type Cast - bool") // Fixme: turn to error?
	}
}

@(private)
extract_int :: #force_inline proc(arg: any) -> int {
	switch a in arg {
	case i8:
		return int(a)
	case i16:
		return int(a)
	case i32:
		return int(a)
	case i64:
		return int(a)
	case int:
		return int(a)
	// case u8, u16, u32, u64, uint:
	// 	return int(a)
	case:
		panic("Invalid Type Cast - int") // Fixme: turn to error?
	}
}
