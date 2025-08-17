package pg_pool

import pq "../vendor/odin-postgresql"
import "base:intrinsics"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math/fixed"
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

	n_bytes := int(pq.get_length(rows.result, target_row, i32(col)))
	ptr := pq.get_value(rows.result, target_row, i32(col))

	if rows.columns[col].text_mode {
		str := cast(string)cstring(ptr)
		return parse_text(str, T, allocator)
	} else {
		// Binary format - handle negative n_bytes (shouldn't happen after NULL check)
		if n_bytes < 0 {
			n_bytes = 0
		}
		bytes := ([^]byte)(ptr)[:n_bytes]
		return parse_binary(bytes, rows.columns[col].oid, T, allocator)
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
				case runtime.Type_Info_Slice:
					// Handle slices - []int, []string, etc.
					elem_type := ti.elem
					elem_id := elem_type.id
					
					switch elem_id {
					case typeid_of(i16):
						value, err := scan(rows, []i16, i)
						if err == nil {
							sp := cast(^[]i16)(field_ptr)
							sp^ = value
						}
					case typeid_of(i32):
						value, err := scan(rows, []i32, i)
						if err == nil {
							sp := cast(^[]i32)(field_ptr)
							sp^ = value
						}
					case typeid_of(i64):
						value, err := scan(rows, []i64, i)
						if err == nil {
							sp := cast(^[]i64)(field_ptr)
							sp^ = value
						}
					case typeid_of(int):
						value, err := scan(rows, []int, i)
						if err == nil {
							sp := cast(^[]int)(field_ptr)
							sp^ = value
						}
					case typeid_of(f32):
						value, err := scan(rows, []f32, i)
						if err == nil {
							sp := cast(^[]f32)(field_ptr)
							sp^ = value
						}
					case typeid_of(f64):
						value, err := scan(rows, []f64, i)
						if err == nil {
							sp := cast(^[]f64)(field_ptr)
							sp^ = value
						}
					case typeid_of(bool):
						value, err := scan(rows, []bool, i)
						if err == nil {
							sp := cast(^[]bool)(field_ptr)
							sp^ = value
						}
					case typeid_of(string):
						value, err := scan(rows, []string, i)
						if err == nil {
							sp := cast(^[]string)(field_ptr)
							sp^ = value
						}
					case typeid_of(byte):
						// Handle []byte for BYTEA
						value, err := scan(rows, []byte, i)
						if err == nil {
							sp := cast(^[]byte)(field_ptr)
							sp^ = value
						}
					case:
						fmt.eprintln("Unsupported slice element type:", elem_id)
					}
				case runtime.Type_Info_Named:
					// Handle named types like time.Time, json.Value, etc.
					type_id := pg_col.field.type.id
					switch type_id {
					case typeid_of(time.Time):
						value, err := scan(rows, time.Time, i)
						if err == nil {
							tp := cast(^time.Time)(field_ptr)
							tp^ = value
						}
					case typeid_of(json.Value):
						value, err := scan(rows, json.Value, i)
						if err == nil {
							jp := cast(^json.Value)(field_ptr)
							jp^ = value
						}
					case typeid_of(fixed.Fixed52_12):
						value, err := scan(rows, fixed.Fixed52_12, i)
						if err == nil {
							fp := cast(^fixed.Fixed52_12)(field_ptr)
							fp^ = value
						}
					case typeid_of(Interval):
						value, err := scan(rows, Interval, i)
						if err == nil {
							ip := cast(^Interval)(field_ptr)
							ip^ = value
						}
					case:
						// Try to handle as the underlying type by recursing with base type
						// This handles type aliases like: UserID :: int
						// ti is already Type_Info_Named in this context
						base_type := runtime.type_info_base(ti.base)
						#partial switch bt in base_type.variant {
							case runtime.Type_Info_Integer:
								// Handle as integer
								value, err := scan(rows, int, i)
								if err == nil {
									// Use memcpy since we know the size matches
									mem.copy(field_ptr, &value, base_type.size)
								}
							case runtime.Type_Info_String:
								value, err := scan(rows, string, i)
								if err == nil {
									sp := cast(^string)(field_ptr)
									sp^ = value
								}
						case:
							fmt.eprintln(
								"Unsupported named type with base:",
								pg_col.field.type,
								base_type,
							)
						}
					}
				case runtime.Type_Info_Pointer:
					// Handle pointers for nullable fields
					ptr_type := ti.elem
					
					// Check if the column is NULL first
					if pq.get_is_null(rows.result, i32(rows.current_row), i32(i)) {
						// Set pointer to nil for NULL values
						pp := cast(^rawptr)(field_ptr)
						pp^ = nil
					} else {
						// Allocate and scan the value
						ptr_elem_id := ptr_type.id
						
						switch ptr_elem_id {
						case typeid_of(int):
							value, err := scan(rows, int, i)
							if err == nil {
								ptr := new(int)
								ptr^ = value
								pp := cast(^(^int))(field_ptr)
								pp^ = ptr
							}
						case typeid_of(i32):
							value, err := scan(rows, i32, i)
							if err == nil {
								ptr := new(i32)
								ptr^ = value
								pp := cast(^(^i32))(field_ptr)
								pp^ = ptr
							}
						case typeid_of(i64):
							value, err := scan(rows, i64, i)
							if err == nil {
								ptr := new(i64)
								ptr^ = value
								pp := cast(^(^i64))(field_ptr)
								pp^ = ptr
							}
						case typeid_of(string):
							value, err := scan(rows, string, i)
							if err == nil {
								ptr := new(string)
								ptr^ = value
								pp := cast(^(^string))(field_ptr)
								pp^ = ptr
							}
						case typeid_of(bool):
							value, err := scan(rows, bool, i)
							if err == nil {
								ptr := new(bool)
								ptr^ = value
								pp := cast(^(^bool))(field_ptr)
								pp^ = ptr
							}
						case typeid_of(f32):
							value, err := scan(rows, f32, i)
							if err == nil {
								ptr := new(f32)
								ptr^ = value
								pp := cast(^(^f32))(field_ptr)
								pp^ = ptr
							}
						case typeid_of(f64):
							value, err := scan(rows, f64, i)
							if err == nil {
								ptr := new(f64)
								ptr^ = value
								pp := cast(^(^f64))(field_ptr)
								pp^ = ptr
							}
						case typeid_of(time.Time):
							value, err := scan(rows, time.Time, i)
							if err == nil {
								ptr := new(time.Time)
								ptr^ = value
								pp := cast(^(^time.Time))(field_ptr)
								pp^ = ptr
							}
						case:
							fmt.eprintln("Unsupported pointer element type:", ptr_elem_id)
						}
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

@(private)
hex_char_to_byte :: proc(c: u8) -> u8 {
	switch c {
	case '0' ..= '9':
		return c - '0'
	case 'a' ..= 'f':
		return c - 'a' + 10
	case 'A' ..= 'F':
		return c - 'A' + 10
	}
	return 0
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
		// For i64, try money format first if it looks like currency
		when T == i64 {
			if strings.contains(str, "$") ||
			   strings.contains(str, "¢") ||
			   strings.contains(str, "£") ||
			   strings.contains(str, "€") ||
			   strings.contains(str, "¥") {
				money_val, ok := parse_money_text(str)
				if ok {
					val = money_val
					return val, .None
				}
			}
		}
		// Regular integer parsing
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
	when T == []byte {
		// PostgreSQL returns bytea in hex format like '\xDEADBEEF'
		if len(str) >= 2 && str[0:2] == "\\x" {
			// Hex encoded - skip the \x prefix
			hex_str := str[2:]
			byte_count := len(hex_str) / 2
			val = make([]byte, byte_count, allocator)
			for i := 0; i < byte_count; i += 1 {
				high := hex_char_to_byte(hex_str[i * 2])
				low := hex_char_to_byte(hex_str[i * 2 + 1])
				val[i] = high * 16 + low
			}
		} else {
			// Plain bytes or empty
			val = make([]byte, len(str), allocator)
			copy(val, transmute([]byte)str)
		}
		return val, .None
	}
	when T == Numeric {
		// Parse NUMERIC from text format (e.g., "123.456")
		numeric_val, ok := string_to_numeric(str)
		if !ok {
			fmt.eprintln("Failed to parse NUMERIC from text:", str)
			return val, .UnknownType
		}
		val = numeric_val
		return val, .None
	}
	when T == Interval {
		// Parse INTERVAL from text format (e.g., "1 year 2 days 03:04:05")
		// For now, basic parsing - could be enhanced with full PostgreSQL interval parsing
		if strings.contains(str, ":") {
			// Simple time-only format like "03:04:05" or "03:04:05.123456"
			parts := strings.split(str, ":", context.temp_allocator)
			defer delete(parts, context.temp_allocator)

			if len(parts) >= 3 {
				hours, h_ok := strconv.parse_i64(parts[0])
				minutes, m_ok := strconv.parse_i64(parts[1])

				// Handle seconds with possible fractional part
				sec_parts := strings.split(parts[2], ".", context.temp_allocator)
				defer delete(sec_parts, context.temp_allocator)

				seconds, s_ok := strconv.parse_i64(sec_parts[0])
				microseconds: i64 = 0

				if len(sec_parts) > 1 {
					// Parse fractional seconds (up to 6 digits for microseconds)
					frac_str := sec_parts[1]
					if len(frac_str) > 6 {
						frac_str = frac_str[:6]
					}
					// Pad with zeros if needed
					for len(frac_str) < 6 {
						frac_str = fmt.aprintf("%s0", frac_str, allocator = context.temp_allocator)
					}
					us, us_ok := strconv.parse_i64(frac_str)
					if us_ok {
						microseconds = us
					}
				}

				if h_ok && m_ok && s_ok {
					total_us := ((hours * 60 + minutes) * 60 + seconds) * 1000000 + microseconds
					val = Interval {
						months       = 0,
						days         = 0,
						microseconds = total_us,
					}
					return val, .None
				}
			}
		}
		// For complex interval strings, return a simple zero interval for now
		// Could be enhanced to parse full PostgreSQL interval syntax
		val = Interval {
			months       = 0,
			days         = 0,
			microseconds = 0,
		}
		return val, .None
	}
	// Note: UUID in text format is just the string representation
	// If the caller wants a UUID string, they can use string type
	fmt.eprintln("Unknown type in parse_text:", typeid_of(T))
	return val, .UnknownType
}

// Reads binary format returned values
@(private)
parse_binary :: proc(
	bytes: []byte,
	oid: pq.OID,
	$T: typeid,
	allocator := context.allocator,
) -> (
	val: T,
	err: QueryError,
) {
	// Debug
	// fmt.printf("parse_binary: oid=%d, len=%d, T=%v\n", oid, len(bytes), typeid_of(T))

	switch oid {
	case OID_BOOL:
		when T == bool {
			val = bytes[0] != 0
			return val, .None
		}
	case OID_INT2:
		when T == i16 || T == int || T == i32 || T == i64 {
			// Read 2 bytes as big-endian i16
			v := i16(bytes[0]) << 8 | i16(bytes[1])
			val = T(v)
			return val, .None
		}
	case OID_INT4:
		when T == i32 || T == int || T == i64 {
			// Read 4 bytes as big-endian i32
			v := i32(bytes[0]) << 24 | i32(bytes[1]) << 16 | i32(bytes[2]) << 8 | i32(bytes[3])
			val = T(v)
			return val, .None
		}
	case OID_INT8:
		when T == i64 || T == int {
			// Read 8 bytes as big-endian i64
			v :=
				i64(bytes[0]) << 56 |
				i64(bytes[1]) << 48 |
				i64(bytes[2]) << 40 |
				i64(bytes[3]) << 32 |
				i64(bytes[4]) << 24 |
				i64(bytes[5]) << 16 |
				i64(bytes[6]) << 8 |
				i64(bytes[7])
			val = T(v)
			return val, .None
		}
	case OID_FLOAT4:
		when T == f32 {
			// Read 4 bytes as big-endian u32, then transmute to f32
			u := u32(bytes[0]) << 24 | u32(bytes[1]) << 16 | u32(bytes[2]) << 8 | u32(bytes[3])
			val = transmute(f32)u
			return val, .None
		}
	case OID_FLOAT8:
		when T == f64 {
			// Read 8 bytes as big-endian u64, then transmute to f64
			u :=
				u64(bytes[0]) << 56 |
				u64(bytes[1]) << 48 |
				u64(bytes[2]) << 40 |
				u64(bytes[3]) << 32 |
				u64(bytes[4]) << 24 |
				u64(bytes[5]) << 16 |
				u64(bytes[6]) << 8 |
				u64(bytes[7])
			val = transmute(f64)u
			return val, .None
		}
	case OID_TEXT, OID_VARCHAR, OID_BPCHAR:
		when T == string {
			// Binary format for text is just UTF-8 bytes without null terminator
			val = strings.clone(string(bytes), allocator)
			return val, .None
		}
	case OID_BYTEA:
		when T == []byte {
			val = make([]byte, len(bytes), allocator)
			copy(val, bytes)
			return val, .None
		}
	case OID_DATE:
		// PostgreSQL date: 4 bytes, days since 2000-01-01
		when T == time.Time {
			if len(bytes) != 4 {
				return val, .UnknownType
			}
			// Read 4 bytes as big-endian i32
			days := i32(
				u32(bytes[0]) << 24 | u32(bytes[1]) << 16 | u32(bytes[2]) << 8 | u32(bytes[3]),
			)
			// fmt.printf("  Date bytes: %02x, days=%d\n", bytes, days)
			// PostgreSQL epoch is 2000-01-01
			pg_epoch := time.components_to_time(2000, 1, 1, 0, 0, 0, 0) or_else time.Time{}
			duration := time.Duration(i64(days) * 24 * i64(time.Hour))
			val = time.Time{pg_epoch._nsec + i64(duration)}
			return val, .None
		}
	case OID_TIMESTAMP, OID_TIMESTAMPTZ:
		// PostgreSQL timestamp: 8 bytes, microseconds since 2000-01-01
		// TIMESTAMP: microseconds since 2000-01-01 00:00:00 (no timezone)
		// TIMESTAMPTZ: microseconds since 2000-01-01 00:00:00 UTC
		// 
		// Note: Currently we treat both the same - as UTC timestamps.
		// For proper TIMESTAMP support, we'd need to know the database's timezone
		// and interpret TIMESTAMP values in that timezone rather than UTC.
		// For TIMESTAMPTZ, the value is always UTC which matches our handling.
		when T == time.Time {
			if len(bytes) != 8 {
				return val, .UnknownType
			}
			// Read 8 bytes as big-endian i64
			microseconds := i64(
				u64(bytes[0]) << 56 |
				u64(bytes[1]) << 48 |
				u64(bytes[2]) << 40 |
				u64(bytes[3]) << 32 |
				u64(bytes[4]) << 24 |
				u64(bytes[5]) << 16 |
				u64(bytes[6]) << 8 |
				u64(bytes[7]),
			)
			// fmt.printf("  Timestamp bytes: %02x, microseconds=%d\n", bytes, microseconds)
			pg_epoch := time.components_to_time(2000, 1, 1, 0, 0, 0, 0) or_else time.Time{}
			duration := time.Duration(microseconds * 1000) // Convert microseconds to nanoseconds
			val = time.Time{pg_epoch._nsec + i64(duration)}
			return val, .None
		}
	case OID_UUID:
		// UUID is 16 bytes in binary format
		when T == string {
			// Convert 16 bytes to standard UUID string
			if len(bytes) == 16 {
				// Format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
				val = fmt.aprintf(
					"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
					bytes[0],
					bytes[1],
					bytes[2],
					bytes[3],
					bytes[4],
					bytes[5],
					bytes[6],
					bytes[7],
					bytes[8],
					bytes[9],
					bytes[10],
					bytes[11],
					bytes[12],
					bytes[13],
					bytes[14],
					bytes[15],
					allocator = allocator,
				)
				return val, .None
			}
		}
		when T == [16]byte {
			// Return raw UUID bytes
			if len(bytes) == 16 {
				copy(val[:], bytes)
				return val, .None
			}
		}
	case OID_ARR_BOOL,
	     OID_ARR_INT2,
	     OID_ARR_INT4,
	     OID_ARR_INT8,
	     OID_ARR_FLOAT4,
	     OID_ARR_FLOAT8,
	     OID_ARR_TEXT:
		// PostgreSQL array binary format
		when intrinsics.type_is_slice(T) {
			if len(bytes) < 12 {
				return val, .UnknownType
			}

			// Read array header
			ndim := i32(bytes[0]) << 24 | i32(bytes[1]) << 16 | i32(bytes[2]) << 8 | i32(bytes[3])
			// flags := i32(bytes[4]) << 24 | i32(bytes[5]) << 16 | i32(bytes[6]) << 8 | i32(bytes[7])
			element_oid := pq.OID(
				i32(bytes[8]) << 24 | i32(bytes[9]) << 16 | i32(bytes[10]) << 8 | i32(bytes[11]),
			)

			if ndim != 1 {
				// We only support 1D arrays for now
				return val, .UnknownType
			}

			// Read dimension info
			dim_size :=
				i32(bytes[12]) << 24 | i32(bytes[13]) << 16 | i32(bytes[14]) << 8 | i32(bytes[15])
			// lower_bound := i32(bytes[16]) << 24 | i32(bytes[17]) << 16 | i32(bytes[18]) << 8 | i32(bytes[19])

			// Start reading elements at byte 20
			offset := 20

			switch oid {
			case OID_ARR_BOOL:
				when T == []bool {
					// Verify element type
					if element_oid != OID_BOOL {
						return val, .UnknownType
					}
					result := make([dynamic]bool, 0, dim_size, allocator)
					for i := i32(0); i < dim_size; i += 1 {
						// Read element length
						elem_len :=
							i32(bytes[offset]) << 24 |
							i32(bytes[offset + 1]) << 16 |
							i32(bytes[offset + 2]) << 8 |
							i32(bytes[offset + 3])
						offset += 4

						if elem_len == -1 {
							// NULL element - append false
							append(&result, false)
						} else if elem_len == 1 {
							// Read the boolean
							append(&result, bytes[offset] != 0)
							offset += 1
						}
					}
					val = result[:]
					return val, .None
				}
			case OID_ARR_INT2:
				when T == []i16 || T == []int || T == []i32 || T == []i64 {
					// Verify element type
					if element_oid != OID_INT2 {
						return val, .UnknownType
					}
					result := make([dynamic]i16, 0, dim_size, allocator)
					for i := i32(0); i < dim_size; i += 1 {
						// Read element length
						elem_len :=
							i32(bytes[offset]) << 24 |
							i32(bytes[offset + 1]) << 16 |
							i32(bytes[offset + 2]) << 8 |
							i32(bytes[offset + 3])
						offset += 4

						if elem_len == -1 {
							// NULL element - append 0
							append(&result, 0)
						} else if elem_len == 2 {
							// Read the i16
							v := i16(bytes[offset]) << 8 | i16(bytes[offset + 1])
							append(&result, v)
							offset += 2
						}
					}
					when T == []int {
						// Convert to []int
						int_result := make([]int, len(result), allocator)
						for v, i in result {
							int_result[i] = int(v)
						}
						val = int_result
					} else when T == []i32 {
						// Convert to []i32 (safe upcast)
						i32_result := make([]i32, len(result), allocator)
						for v, i in result {
							i32_result[i] = i32(v)
						}
						val = i32_result
					} else when T == []i64 {
						// Convert to []i64 (safe upcast)
						i64_result := make([]i64, len(result), allocator)
						for v, i in result {
							i64_result[i] = i64(v)
						}
						val = i64_result
					} else {
						val = result[:]
					}
					return val, .None
				}
			case OID_ARR_INT4:
				when T == []i32 || T == []int || T == []i64 {
					// Verify element type
					if element_oid != OID_INT4 {
						return val, .UnknownType
					}
					result := make([dynamic]i32, 0, dim_size, allocator)
					for i := i32(0); i < dim_size; i += 1 {
						// Read element length
						elem_len :=
							i32(bytes[offset]) << 24 |
							i32(bytes[offset + 1]) << 16 |
							i32(bytes[offset + 2]) << 8 |
							i32(bytes[offset + 3])
						offset += 4

						if elem_len == -1 {
							// NULL element - append 0
							append(&result, 0)
						} else if elem_len == 4 {
							// Read the integer
							v :=
								i32(bytes[offset]) << 24 |
								i32(bytes[offset + 1]) << 16 |
								i32(bytes[offset + 2]) << 8 |
								i32(bytes[offset + 3])
							append(&result, v)
							offset += 4
						}
					}
					when T == []int {
						// Convert to []int
						int_result := make([]int, len(result), allocator)
						for v, i in result {
							int_result[i] = int(v)
						}
						val = int_result
					} else when T == []i64 {
						// Convert to []i64 (safe upcast)
						i64_result := make([]i64, len(result), allocator)
						for v, i in result {
							i64_result[i] = i64(v)
						}
						val = i64_result
					} else {
						val = result[:]
					}
					return val, .None
				}
			case OID_ARR_INT8:
				when T == []i64 || T == []int {
					// Verify element type
					if element_oid != OID_INT8 {
						return val, .UnknownType
					}
					result := make([dynamic]i64, 0, dim_size, allocator)
					for i := i32(0); i < dim_size; i += 1 {
						// Read element length
						elem_len :=
							i32(bytes[offset]) << 24 |
							i32(bytes[offset + 1]) << 16 |
							i32(bytes[offset + 2]) << 8 |
							i32(bytes[offset + 3])
						offset += 4

						if elem_len == -1 {
							// NULL element - append 0
							append(&result, 0)
						} else if elem_len == 8 {
							// Read the i64
							v :=
								i64(bytes[offset]) << 56 |
								i64(bytes[offset + 1]) << 48 |
								i64(bytes[offset + 2]) << 40 |
								i64(bytes[offset + 3]) << 32 |
								i64(bytes[offset + 4]) << 24 |
								i64(bytes[offset + 5]) << 16 |
								i64(bytes[offset + 6]) << 8 |
								i64(bytes[offset + 7])
							append(&result, v)
							offset += 8
						}
					}
					when T == []int {
						// Convert to []int
						int_result := make([]int, len(result), allocator)
						for v, i in result {
							int_result[i] = int(v)
						}
						val = int_result
					} else {
						val = result[:]
					}
					return val, .None
				}
			case OID_ARR_FLOAT4:
				when T == []f32 {
					// Verify element type
					if element_oid != OID_FLOAT4 {
						return val, .UnknownType
					}
					result := make([dynamic]f32, 0, dim_size, allocator)
					for i := i32(0); i < dim_size; i += 1 {
						// Read element length
						elem_len :=
							i32(bytes[offset]) << 24 |
							i32(bytes[offset + 1]) << 16 |
							i32(bytes[offset + 2]) << 8 |
							i32(bytes[offset + 3])
						offset += 4

						if elem_len == -1 {
							// NULL element - append NaN
							append(&result, transmute(f32)u32(0x7FC00000)) // NaN
						} else if elem_len == 4 {
							// Read the float
							u :=
								u32(bytes[offset]) << 24 |
								u32(bytes[offset + 1]) << 16 |
								u32(bytes[offset + 2]) << 8 |
								u32(bytes[offset + 3])
							append(&result, transmute(f32)u)
							offset += 4
						}
					}
					val = result[:]
					return val, .None
				}
			case OID_ARR_FLOAT8:
				when T == []f64 {
					// Verify element type
					if element_oid != OID_FLOAT8 {
						return val, .UnknownType
					}
					result := make([dynamic]f64, 0, dim_size, allocator)
					for i := i32(0); i < dim_size; i += 1 {
						// Read element length
						elem_len :=
							i32(bytes[offset]) << 24 |
							i32(bytes[offset + 1]) << 16 |
							i32(bytes[offset + 2]) << 8 |
							i32(bytes[offset + 3])
						offset += 4

						if elem_len == -1 {
							// NULL element - append NaN
							append(&result, transmute(f64)u64(0x7FF8000000000000)) // NaN
						} else if elem_len == 8 {
							// Read the double
							u :=
								u64(bytes[offset]) << 56 |
								u64(bytes[offset + 1]) << 48 |
								u64(bytes[offset + 2]) << 40 |
								u64(bytes[offset + 3]) << 32 |
								u64(bytes[offset + 4]) << 24 |
								u64(bytes[offset + 5]) << 16 |
								u64(bytes[offset + 6]) << 8 |
								u64(bytes[offset + 7])
							append(&result, transmute(f64)u)
							offset += 8
						}
					}
					val = result[:]
					return val, .None
				}
			case OID_ARR_TEXT:
				when T == []string {
					// Verify element type (TEXT, VARCHAR, or BPCHAR are all compatible)
					if element_oid != OID_TEXT &&
					   element_oid != OID_VARCHAR &&
					   element_oid != OID_BPCHAR {
						return val, .UnknownType
					}
					result := make([dynamic]string, 0, dim_size, allocator)
					for i := i32(0); i < dim_size; i += 1 {
						// Read element length
						elem_len :=
							i32(bytes[offset]) << 24 |
							i32(bytes[offset + 1]) << 16 |
							i32(bytes[offset + 2]) << 8 |
							i32(bytes[offset + 3])
						offset += 4

						if elem_len == -1 {
							// NULL element - append empty string
							append(&result, "")
						} else {
							// Read the string
							str := string(bytes[offset:offset + int(elem_len)])
							append(&result, strings.clone(str, allocator))
							offset += int(elem_len)
						}
					}
					val = result[:]
					return val, .None
				}
			case:
				// Other array types not yet implemented
				return val, .UnknownType
			}
		}
	case OID_JSON, OID_JSONB:
		when T == json.Value {
			// JSONB has a version byte prefix
			json_bytes := bytes
			if oid == OID_JSONB && len(bytes) > 0 {
				json_bytes = bytes[1:] // Skip version byte
			}
			json_str := string(json_bytes)
			json_val, json_err := json.parse(
				transmute([]byte)json_str,
				json.DEFAULT_SPECIFICATION,
				false,
				allocator,
			)
			if json_err != .None {
				return val, .UnknownType
			}
			val = json_val
			return val, .None
		}
		when T == string {
			// Allow reading JSON as string
			json_bytes := bytes
			if oid == OID_JSONB && len(bytes) > 0 {
				json_bytes = bytes[1:] // Skip version byte
			}
			val = strings.clone(string(json_bytes), allocator)
			return val, .None
		}
	case OID_NUMERIC:
		when T == Numeric {
			// Parse PostgreSQL NUMERIC binary format
			numeric_val, ok := parse_postgres_numeric(bytes, allocator)
			if !ok {
				return val, .UnknownType
			}
			val = numeric_val
			return val, .None
		}
		when T == f64 {
			// Parse NUMERIC and convert to f64 (potential precision loss)
			numeric_val, ok := parse_postgres_numeric(bytes, allocator)
			if !ok {
				return val, .UnknownType
			}
			val = numeric_to_f64(numeric_val)
			return val, .None
		}
		when T == string {
			// Parse NUMERIC and convert to string (exact precision)
			numeric_val, ok := parse_postgres_numeric(bytes, allocator)
			if !ok {
				return val, .UnknownType
			}
			val = numeric_to_string(numeric_val, allocator)
			return val, .None
		}
	case OID_MONEY:
		when T == i64 {
			// MONEY is stored as 8-byte signed integer (cents)
			if len(bytes) != 8 {
				return val, .UnknownType
			}
			cents :=
				i64(bytes[0]) << 56 |
				i64(bytes[1]) << 48 |
				i64(bytes[2]) << 40 |
				i64(bytes[3]) << 32 |
				i64(bytes[4]) << 24 |
				i64(bytes[5]) << 16 |
				i64(bytes[6]) << 8 |
				i64(bytes[7])
			val = cents
			return val, .None
		}
		when T == f64 {
			// Parse MONEY and convert to dollars
			if len(bytes) != 8 {
				return val, .UnknownType
			}
			cents :=
				i64(bytes[0]) << 56 |
				i64(bytes[1]) << 48 |
				i64(bytes[2]) << 40 |
				i64(bytes[3]) << 32 |
				i64(bytes[4]) << 24 |
				i64(bytes[5]) << 16 |
				i64(bytes[6]) << 8 |
				i64(bytes[7])
			val = f64(cents) / 100.0 // Convert cents to dollars
			return val, .None
		}
		when T == string {
			// Parse MONEY and convert to string
			if len(bytes) != 8 {
				return val, .UnknownType
			}
			cents :=
				i64(bytes[0]) << 56 |
				i64(bytes[1]) << 48 |
				i64(bytes[2]) << 40 |
				i64(bytes[3]) << 32 |
				i64(bytes[4]) << 24 |
				i64(bytes[5]) << 16 |
				i64(bytes[6]) << 8 |
				i64(bytes[7])
			val = fmt.aprintf("%.2f", f64(cents) / 100.0, allocator = allocator) // Convert to dollar string
			return val, .None
		}
	case OID_INTERVAL:
		when T == Interval {
			// Parse PostgreSQL INTERVAL binary format (16 bytes)
			interval_val, ok := parse_postgres_interval(bytes)
			if !ok {
				return val, .UnknownType
			}
			val = interval_val
			return val, .None
		}
		when T == time.Duration {
			// Parse INTERVAL and convert to Duration (ignores months/days)
			interval_val, ok := parse_postgres_interval(bytes)
			if !ok {
				return val, .UnknownType
			}
			val = interval_to_duration(interval_val)
			return val, .None
		}
		when T == string {
			// Parse INTERVAL and convert to string
			interval_val, ok := parse_postgres_interval(bytes)
			if !ok {
				return val, .UnknownType
			}
			// Convert to PostgreSQL text format
			temp_buf := make([dynamic]byte, 0, 64, context.temp_allocator)
			defer delete_dynamic_array(temp_buf)
			interval_to_postgres_text(interval_val, &temp_buf)
			val = strings.clone(transmute(string)temp_buf[:], allocator)
			return val, .None
		}
	}

	fmt.eprintln("Unknown type in parse_binary:", typeid_of(T), "for OID:", oid)
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
	// Check if we have a custom type with a writer
	if tid != nil && tid.writer != nil {
		return tid.writer(buf, arg, format), nil
	}

	// Debug logging
	// fmt.printf("copy_into_buf: oid=%d, format=%v, typeid=%v\n", oid, format, arg.id)
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
		case Numeric:
			// Convert Numeric to string for text format
			str = numeric_to_string(v, context.temp_allocator)
		case Interval:
			// Convert Interval to string for text format
			temp_buf := make([dynamic]byte, 0, 64, context.temp_allocator)
			defer delete_dynamic_array(temp_buf)
			interval_to_postgres_text(v, &temp_buf)
			str = transmute(string)temp_buf[:]
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
		v := i16(extract_int(actual_arg))
		append(buf, byte(v >> 8), byte(v))
		size = 2
	case OID_INT4:
		v := i32(extract_int(actual_arg))
		append(buf, byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v))
		size = 4
	case OID_INT8:
		v := i64(extract_int(actual_arg))
		append(
			buf,
			byte(v >> 56),
			byte(v >> 48),
			byte(v >> 40),
			byte(v >> 32),
			byte(v >> 24),
			byte(v >> 16),
			byte(v >> 8),
			byte(v),
		)
		size = 8
	case OID_FLOAT4:
		v := transmute(u32)actual_arg.(f32)
		append(buf, byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v))
		size = 4
	case OID_FLOAT8:
		v := transmute(u64)actual_arg.(f64)
		append(
			buf,
			byte(v >> 56),
			byte(v >> 48),
			byte(v >> 40),
			byte(v >> 32),
			byte(v >> 24),
			byte(v >> 16),
			byte(v >> 8),
			byte(v),
		)
		size = 8
	case OID_BYTEA:
		bytes := actual_arg.([]byte)
		append(buf, ..bytes)
		size = i32(len(bytes))
	case OID_TEXT, OID_VARCHAR, OID_BPCHAR:
		str := actual_arg.(string)
		p_bytes := transmute([]byte)str
		append(buf, ..p_bytes)
		size = i32(len(str))
	case OID_DATE:
		// Date as time.Time - convert to days since 2000-01-01
		t := actual_arg.(time.Time)
		pg_epoch, pg_ok := time.components_to_time(2000, 1, 1, 0, 0, 0, 0)
		if !pg_ok {
			fmt.eprintln("Failed to create PG epoch!")
			pg_epoch = time.Time{}
		}
		duration_ns := time.diff(pg_epoch, t) // diff(start, end) = end - start
		days := i32(i64(duration_ns) / (24 * i64(time.Hour)))
		// year, month, day := time.date(t)
		// fmt.printf("  Writing date %04d-%02d-%02d: days=%d\n", year, int(month), day, days)
		append(buf, byte(days >> 24), byte(days >> 16), byte(days >> 8), byte(days))
		size = 4
	case OID_TIMESTAMP, OID_TIMESTAMPTZ:
		// Timestamp as time.Time - convert to microseconds since 2000-01-01
		// 
		// Note: We're assuming the time.Time value is in UTC.
		// For TIMESTAMPTZ this is correct - PostgreSQL expects UTC.
		// For TIMESTAMP, this means the user needs to ensure their time.Time
		// represents the "local" time they want stored, not a UTC time.
		t := actual_arg.(time.Time)
		pg_epoch := time.components_to_time(2000, 1, 1, 0, 0, 0, 0) or_else time.Time{}
		microseconds := i64(time.diff(pg_epoch, t) / 1000) // diff(start, end) = end - start, then nanoseconds to microseconds
		append(
			buf,
			byte(microseconds >> 56),
			byte(microseconds >> 48),
			byte(microseconds >> 40),
			byte(microseconds >> 32),
			byte(microseconds >> 24),
			byte(microseconds >> 16),
			byte(microseconds >> 8),
			byte(microseconds),
		)
		size = 8
	case OID_UUID:
		// UUID can be passed as string or [16]byte
		switch v in actual_arg {
		case string:
			// Parse UUID string and write 16 bytes
			// Expected format: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
			if len(v) == 36 {
				// Remove hyphens and convert hex to bytes
				for i := 0; i < 16; i += 1 {
					// Map byte positions to string positions (accounting for hyphens)
					str_pos := i * 2
					if i >= 4 {str_pos += 1} 	// After first hyphen
					if i >= 6 {str_pos += 1} 	// After second hyphen
					if i >= 8 {str_pos += 1} 	// After third hyphen
					if i >= 10 {str_pos += 1} 	// After fourth hyphen

					high := hex_char_to_byte(v[str_pos])
					low := hex_char_to_byte(v[str_pos + 1])
					append(buf, high * 16 + low)
				}
				size = 16
			}
		case [16]byte:
			for b in v {
				append(buf, b)
			}
			size = 16
		case:
			return 0, .UnknownType
		}
	// Array types
	case OID_ARR_BOOL:
		// Handle []bool
		switch v in actual_arg {
		case []bool:
			// Write array header
			ndim := i32(1)
			flags := i32(0)
			elem_oid := i32(OID_BOOL)
			dim_size := i32(len(v))
			lower_bound := i32(1)

			append(buf, byte(ndim >> 24), byte(ndim >> 16), byte(ndim >> 8), byte(ndim))
			append(buf, byte(flags >> 24), byte(flags >> 16), byte(flags >> 8), byte(flags))
			append(
				buf,
				byte(elem_oid >> 24),
				byte(elem_oid >> 16),
				byte(elem_oid >> 8),
				byte(elem_oid),
			)
			append(
				buf,
				byte(dim_size >> 24),
				byte(dim_size >> 16),
				byte(dim_size >> 8),
				byte(dim_size),
			)
			append(
				buf,
				byte(lower_bound >> 24),
				byte(lower_bound >> 16),
				byte(lower_bound >> 8),
				byte(lower_bound),
			)

			// Write elements
			for elem in v {
				// Element length (1 byte for bool)
				elem_len := i32(1)
				append(
					buf,
					byte(elem_len >> 24),
					byte(elem_len >> 16),
					byte(elem_len >> 8),
					byte(elem_len),
				)
				// Element value
				append(buf, byte(elem ? 1 : 0))
			}
			size = i32(20 + len(v) * 5) // header + each element (4 bytes length + 1 byte value)
		case:
			return 0, .UnknownType
		}
	case OID_ARR_INT4:
		// Handle []int and []i32
		switch v in actual_arg {
		case []int:
			// Write array header
			ndim := i32(1) // 1-dimensional
			flags := i32(0) // no nulls
			elem_oid := i32(OID_INT4)
			dim_size := i32(len(v))
			lower_bound := i32(1)

			// Header: ndim, flags, elem_oid
			append(buf, byte(ndim >> 24), byte(ndim >> 16), byte(ndim >> 8), byte(ndim))
			append(buf, byte(flags >> 24), byte(flags >> 16), byte(flags >> 8), byte(flags))
			append(
				buf,
				byte(elem_oid >> 24),
				byte(elem_oid >> 16),
				byte(elem_oid >> 8),
				byte(elem_oid),
			)
			// Dimension: size, lower_bound
			append(
				buf,
				byte(dim_size >> 24),
				byte(dim_size >> 16),
				byte(dim_size >> 8),
				byte(dim_size),
			)
			append(
				buf,
				byte(lower_bound >> 24),
				byte(lower_bound >> 16),
				byte(lower_bound >> 8),
				byte(lower_bound),
			)

			// Write elements
			for elem in v {
				// Element length (4 bytes for int)
				elem_len := i32(4)
				append(
					buf,
					byte(elem_len >> 24),
					byte(elem_len >> 16),
					byte(elem_len >> 8),
					byte(elem_len),
				)
				// Element value
				val := i32(elem)
				append(buf, byte(val >> 24), byte(val >> 16), byte(val >> 8), byte(val))
			}
			size = i32(20 + len(v) * 8) // header + each element (4 bytes length + 4 bytes value)
		case []i32:
			// Similar to []int
			ndim := i32(1)
			flags := i32(0)
			elem_oid := i32(OID_INT4)
			dim_size := i32(len(v))
			lower_bound := i32(1)

			append(buf, byte(ndim >> 24), byte(ndim >> 16), byte(ndim >> 8), byte(ndim))
			append(buf, byte(flags >> 24), byte(flags >> 16), byte(flags >> 8), byte(flags))
			append(
				buf,
				byte(elem_oid >> 24),
				byte(elem_oid >> 16),
				byte(elem_oid >> 8),
				byte(elem_oid),
			)
			append(
				buf,
				byte(dim_size >> 24),
				byte(dim_size >> 16),
				byte(dim_size >> 8),
				byte(dim_size),
			)
			append(
				buf,
				byte(lower_bound >> 24),
				byte(lower_bound >> 16),
				byte(lower_bound >> 8),
				byte(lower_bound),
			)

			for elem in v {
				elem_len := i32(4)
				append(
					buf,
					byte(elem_len >> 24),
					byte(elem_len >> 16),
					byte(elem_len >> 8),
					byte(elem_len),
				)
				append(buf, byte(elem >> 24), byte(elem >> 16), byte(elem >> 8), byte(elem))
			}
			size = i32(20 + len(v) * 8)
		case:
			return 0, .UnknownType
		}
	case OID_ARR_INT2:
		// Handle []i16
		switch v in actual_arg {
		case []i16:
			// Write array header
			ndim := i32(1)
			flags := i32(0)
			elem_oid := i32(OID_INT2)
			dim_size := i32(len(v))
			lower_bound := i32(1)

			append(buf, byte(ndim >> 24), byte(ndim >> 16), byte(ndim >> 8), byte(ndim))
			append(buf, byte(flags >> 24), byte(flags >> 16), byte(flags >> 8), byte(flags))
			append(
				buf,
				byte(elem_oid >> 24),
				byte(elem_oid >> 16),
				byte(elem_oid >> 8),
				byte(elem_oid),
			)
			append(
				buf,
				byte(dim_size >> 24),
				byte(dim_size >> 16),
				byte(dim_size >> 8),
				byte(dim_size),
			)
			append(
				buf,
				byte(lower_bound >> 24),
				byte(lower_bound >> 16),
				byte(lower_bound >> 8),
				byte(lower_bound),
			)

			// Write elements
			for elem in v {
				// Element length (2 bytes for i16)
				elem_len := i32(2)
				append(
					buf,
					byte(elem_len >> 24),
					byte(elem_len >> 16),
					byte(elem_len >> 8),
					byte(elem_len),
				)
				// Element value
				append(buf, byte(elem >> 8), byte(elem))
			}
			size = i32(20 + len(v) * 6) // header + each element (4 bytes length + 2 bytes value)
		case:
			return 0, .UnknownType
		}
	case OID_ARR_INT8:
		// Handle []i64
		switch v in actual_arg {
		case []i64:
			// Write array header
			ndim := i32(1)
			flags := i32(0)
			elem_oid := i32(OID_INT8)
			dim_size := i32(len(v))
			lower_bound := i32(1)

			append(buf, byte(ndim >> 24), byte(ndim >> 16), byte(ndim >> 8), byte(ndim))
			append(buf, byte(flags >> 24), byte(flags >> 16), byte(flags >> 8), byte(flags))
			append(
				buf,
				byte(elem_oid >> 24),
				byte(elem_oid >> 16),
				byte(elem_oid >> 8),
				byte(elem_oid),
			)
			append(
				buf,
				byte(dim_size >> 24),
				byte(dim_size >> 16),
				byte(dim_size >> 8),
				byte(dim_size),
			)
			append(
				buf,
				byte(lower_bound >> 24),
				byte(lower_bound >> 16),
				byte(lower_bound >> 8),
				byte(lower_bound),
			)

			// Write elements
			for elem in v {
				// Element length (8 bytes for i64)
				elem_len := i32(8)
				append(
					buf,
					byte(elem_len >> 24),
					byte(elem_len >> 16),
					byte(elem_len >> 8),
					byte(elem_len),
				)
				// Element value
				append(
					buf,
					byte(elem >> 56),
					byte(elem >> 48),
					byte(elem >> 40),
					byte(elem >> 32),
					byte(elem >> 24),
					byte(elem >> 16),
					byte(elem >> 8),
					byte(elem),
				)
			}
			size = i32(20 + len(v) * 12) // header + each element (4 bytes length + 8 bytes value)
		case:
			return 0, .UnknownType
		}
	case OID_ARR_FLOAT4:
		// Handle []f32
		switch v in actual_arg {
		case []f32:
			// Write array header
			ndim := i32(1)
			flags := i32(0)
			elem_oid := i32(OID_FLOAT4)
			dim_size := i32(len(v))
			lower_bound := i32(1)

			append(buf, byte(ndim >> 24), byte(ndim >> 16), byte(ndim >> 8), byte(ndim))
			append(buf, byte(flags >> 24), byte(flags >> 16), byte(flags >> 8), byte(flags))
			append(
				buf,
				byte(elem_oid >> 24),
				byte(elem_oid >> 16),
				byte(elem_oid >> 8),
				byte(elem_oid),
			)
			append(
				buf,
				byte(dim_size >> 24),
				byte(dim_size >> 16),
				byte(dim_size >> 8),
				byte(dim_size),
			)
			append(
				buf,
				byte(lower_bound >> 24),
				byte(lower_bound >> 16),
				byte(lower_bound >> 8),
				byte(lower_bound),
			)

			// Write elements
			for elem in v {
				// Element length (4 bytes for float)
				elem_len := i32(4)
				append(
					buf,
					byte(elem_len >> 24),
					byte(elem_len >> 16),
					byte(elem_len >> 8),
					byte(elem_len),
				)
				// Element value
				u := transmute(u32)elem
				append(buf, byte(u >> 24), byte(u >> 16), byte(u >> 8), byte(u))
			}
			size = i32(20 + len(v) * 8) // header + each element (4 bytes length + 4 bytes value)
		case:
			return 0, .UnknownType
		}
	case OID_ARR_FLOAT8:
		// Handle []f64
		switch v in actual_arg {
		case []f64:
			// Write array header
			ndim := i32(1)
			flags := i32(0)
			elem_oid := i32(OID_FLOAT8)
			dim_size := i32(len(v))
			lower_bound := i32(1)

			append(buf, byte(ndim >> 24), byte(ndim >> 16), byte(ndim >> 8), byte(ndim))
			append(buf, byte(flags >> 24), byte(flags >> 16), byte(flags >> 8), byte(flags))
			append(
				buf,
				byte(elem_oid >> 24),
				byte(elem_oid >> 16),
				byte(elem_oid >> 8),
				byte(elem_oid),
			)
			append(
				buf,
				byte(dim_size >> 24),
				byte(dim_size >> 16),
				byte(dim_size >> 8),
				byte(dim_size),
			)
			append(
				buf,
				byte(lower_bound >> 24),
				byte(lower_bound >> 16),
				byte(lower_bound >> 8),
				byte(lower_bound),
			)

			// Write elements
			for elem in v {
				// Element length (8 bytes for double)
				elem_len := i32(8)
				append(
					buf,
					byte(elem_len >> 24),
					byte(elem_len >> 16),
					byte(elem_len >> 8),
					byte(elem_len),
				)
				// Element value
				u := transmute(u64)elem
				append(
					buf,
					byte(u >> 56),
					byte(u >> 48),
					byte(u >> 40),
					byte(u >> 32),
					byte(u >> 24),
					byte(u >> 16),
					byte(u >> 8),
					byte(u),
				)
			}
			size = i32(20 + len(v) * 12) // header + each element (4 bytes length + 8 bytes value)
		case:
			return 0, .UnknownType
		}
	case OID_ARR_TEXT:
		// Handle []string
		switch v in actual_arg {
		case []string:
			// Write array header
			ndim := i32(1)
			flags := i32(0)
			elem_oid := i32(OID_TEXT)
			dim_size := i32(len(v))
			lower_bound := i32(1)

			append(buf, byte(ndim >> 24), byte(ndim >> 16), byte(ndim >> 8), byte(ndim))
			append(buf, byte(flags >> 24), byte(flags >> 16), byte(flags >> 8), byte(flags))
			append(
				buf,
				byte(elem_oid >> 24),
				byte(elem_oid >> 16),
				byte(elem_oid >> 8),
				byte(elem_oid),
			)
			append(
				buf,
				byte(dim_size >> 24),
				byte(dim_size >> 16),
				byte(dim_size >> 8),
				byte(dim_size),
			)
			append(
				buf,
				byte(lower_bound >> 24),
				byte(lower_bound >> 16),
				byte(lower_bound >> 8),
				byte(lower_bound),
			)

			total_size := i32(20) // header size
			for elem in v {
				elem_len := i32(len(elem))
				append(
					buf,
					byte(elem_len >> 24),
					byte(elem_len >> 16),
					byte(elem_len >> 8),
					byte(elem_len),
				)
				append(buf, ..transmute([]byte)elem)
				total_size += 4 + elem_len
			}
			size = total_size
		case:
			return 0, .UnknownType
		}
	case OID_NUMERIC:
		// Handle Numeric (Fixed52_12) type
		switch v in actual_arg {
		case Numeric:
			// Use binary format for efficiency
			if format == .Binary {
				return numeric_to_postgres_binary(v, buf), nil
			} else {
				return numeric_to_postgres_text(v, buf), nil
			}
		case f64:
			// Convert f64 to Numeric first
			numeric_val := f64_to_numeric(v)
			if format == .Binary {
				return numeric_to_postgres_binary(numeric_val, buf), nil
			} else {
				return numeric_to_postgres_text(numeric_val, buf), nil
			}
		case string:
			// Parse string to Numeric first
			numeric_val, ok := string_to_numeric(v)
			if !ok {
				return 0, .UnknownType
			}
			if format == .Binary {
				return numeric_to_postgres_binary(numeric_val, buf), nil
			} else {
				return numeric_to_postgres_text(numeric_val, buf), nil
			}
		case:
			return 0, .UnknownType
		}
	case OID_MONEY:
		// Handle Money (cents as i64) type
		switch v in actual_arg {
		case i64:
			// MONEY: 8-byte signed integer (cents)
			cents := v
			append(
				buf,
				..[]byte {
					byte(cents >> 56),
					byte(cents >> 48),
					byte(cents >> 40),
					byte(cents >> 32),
					byte(cents >> 24),
					byte(cents >> 16),
					byte(cents >> 8),
					byte(cents),
				},
			)
			size = 8
		case f64:
			// Convert f64 dollars to cents
			cents := i64(v * 100.0)
			append(
				buf,
				..[]byte {
					byte(cents >> 56),
					byte(cents >> 48),
					byte(cents >> 40),
					byte(cents >> 32),
					byte(cents >> 24),
					byte(cents >> 16),
					byte(cents >> 8),
					byte(cents),
				},
			)
			size = 8
		case string:
			// Parse string as Money
			cents, ok := parse_money_text(v)
			if !ok {
				return 0, .UnknownType
			}
			append(
				buf,
				..[]byte {
					byte(cents >> 56),
					byte(cents >> 48),
					byte(cents >> 40),
					byte(cents >> 32),
					byte(cents >> 24),
					byte(cents >> 16),
					byte(cents >> 8),
					byte(cents),
				},
			)
			size = 8
		case:
			return 0, .UnknownType
		}
	case OID_JSON, OID_JSONB:
		// Handle both json.Value and string
		json_bytes: []byte
		switch v in actual_arg {
		case json.Value:
			// Marshal to bytes
			marshaled, marshal_err := json.marshal(v, allocator = context.temp_allocator)
			if marshal_err != nil {
				return 0, .UnknownType
			}
			json_bytes = marshaled
		case string:
			json_bytes = transmute([]byte)v
		case:
			return 0, .UnknownType
		}

		if oid == OID_JSONB {
			append(buf, 1) // JSONB version byte
		}
		append(buf, ..json_bytes)
		size = i32(len(json_bytes))
		if oid == OID_JSONB {
			size += 1 // Include version byte
		}
	case OID_INTERVAL:
		// Handle Interval type
		switch v in actual_arg {
		case Interval:
			// Use binary format for efficiency
			if format == .Binary {
				return interval_to_postgres_binary(v, buf), nil
			} else {
				return interval_to_postgres_text(v, buf), nil
			}
		case time.Duration:
			// Convert Duration to Interval first
			interval_val := duration_to_interval(v)
			if format == .Binary {
				return interval_to_postgres_binary(interval_val, buf), nil
			} else {
				return interval_to_postgres_text(interval_val, buf), nil
			}
		case string:
			// Parse string to Interval first (basic parsing)
			// For now, assume it's a simple time format like "03:04:05"
			interval_val := Interval {
				months       = 0,
				days         = 0,
				microseconds = 0,
			}
			if strings.contains(v, ":") {
				parts := strings.split(v, ":", context.temp_allocator)
				defer delete(parts, context.temp_allocator)

				if len(parts) >= 3 {
					hours, h_ok := strconv.parse_i64(parts[0])
					minutes, m_ok := strconv.parse_i64(parts[1])
					seconds, s_ok := strconv.parse_i64(parts[2])

					if h_ok && m_ok && s_ok {
						total_us := ((hours * 60 + minutes) * 60 + seconds) * 1000000
						interval_val.microseconds = total_us
					}
				}
			}
			if format == .Binary {
				return interval_to_postgres_binary(interval_val, buf), nil
			} else {
				return interval_to_postgres_text(interval_val, buf), nil
			}
		case:
			return 0, .UnknownType
		}
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
		return OID_TIMESTAMPTZ // Default to timestamptz for time.Time
	case json.Value:
		return OID_JSONB // Default to JSONB for json.Value
	case Numeric:
		return OID_NUMERIC
	case Interval:
		return OID_INTERVAL
	// Money is just i64, so it maps to OID_MONEY when context indicates it
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
	case []bool:
		return OID_ARR_BOOL
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
