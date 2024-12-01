package pg_pool

import pq "../vendor/odin-postgresql"
import "core:fmt"
import "core:reflect"

buf_writer :: #type proc(buf:^[dynamic]byte, arg:any, format: pq.Format) -> (size:i32)

Type_Decl::union{
	typeid,
	Postgres_Type,
	pq.OID, // TODO: probably support this??
}

Postgres_Type :: struct {
	oid:pq.OID,
	writer: buf_writer, // Optional
	format:pq.Format,
}

PG_OID::enum i32{
	Unknown = 0,
	Int2 = 21,
	Int4 = 23,
	Int8 = 20,
	Float4 = 700,
	Float8 = 701,
}
pg_type::#force_inline proc(val:PG_OID)-> pq.OID { return pq.OID(val) }

// TODO: make into enum with inline-proc of oid::proc(val:OID) -> pq.OID
OID_UNKNOWN::0 
// ints
OID_INT2 :: 21
OID_INT4 :: 23
OID_INT8 :: 20
// floats
OID_FLOAT4 :: 700
OID_FLOAT8 :: 701
// bool
OID_BOOL :: 16
// strings
OID_TEXT :: 25
OID_VARCHAR :: 1043
OID_BPCHAR ::1042
// dates
OID_DATE :: 1082 // 4bytes, days since 2000-01-01
OID_TIMESTAMP :: 1114 // 8bytes, us since epoch
OID_TIMESTAMPTZ :: 1184 // 8bytes, us since epoch, UTC
OID_TIME :: 1083 // 8bytes, time without tz, var len, us since midnight
OID_TIMETZ::1266 // 16bytes, as above, utc
OID_INTERVAL::1186 // 16bytes, mon,day, 'us'
// binary/json
OID_BYTEA::17
OID_JSON::114
OID_JSONB ::3802 // req 0x1 prefix on values
// array-types
OID_ARR_INT2::1005
OID_ARR_INT4::1007
OID_ARR_INT8::1016
OID_ARR_TEXT::1009
OID_ARR_FLOAT4::1021
OID_ARR_FLOAT8::1022
// 
OID_TSVECTOR :: 3614
OID_TSQUERY::3615

// DB_Type :: struct {
// 	oid:      pq.OID,
// 	name:     string,
// 	n_bytes:  int,
// 	category: TypeCategory,
// 	type:     reflect.Type_Kind,
// }

DB_Type :: struct {
	oid:     pq.OID,
	size:    int,
	write_data:   proc(arg: any, pd: ^Param_Data, idx: int) -> Error,
}
