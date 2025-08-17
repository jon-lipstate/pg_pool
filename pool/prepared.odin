package pg_pool

import pq "../vendor/odin-postgresql"
import "core:fmt"
import "core:strings"


Prepared_Statement :: struct {
	cnx:          ^Connection,
	name:         cstring,
	sql:          string,
	arg_types:    []Type_Decl,
	result_types: []pq.OID,
}
Param_Data :: struct {
	values:  [dynamic]byte,
	lengths: []i32,
	formats: []pq.Format,
}

prepare :: proc(
	cnx: ^Connection,
	name: string,
	sql: string,
	types: []Type_Decl,
) -> (
	stmt: Prepared_Statement,
	err: Error,
) {
	context.allocator = cnx.allocator

	stmt.cnx = cnx
	stmt.name = strings.clone_to_cstring(name)

	c_sql := strings.clone_to_cstring(sql)
	defer {delete(c_sql)}

	n_args := count_args(sql)
	stmt.arg_types = make([]Type_Decl, n_args)
	for type, i in types {
		stmt.arg_types[i] = types[i]
	}

	oids := extract_oids(stmt.arg_types);defer delete(oids)
	p_types := oids != nil ? &oids[0] : nil

	result := pq.prepare(cnx.cnx, stmt.name, c_sql, i32(n_args), p_types)
	if result == nil {
		err = db_error_from_msg(cnx)
		return
	}

	status := pq.result_status(result)
	if status != pq.Exec_Status.Command_OK {
		err_msg := pq.error_message(cnx.cnx)
		err = db_error_from_msg(cnx)
		return
	}

	pq.clear(result)

	return
}


exec_prepared :: proc(
	stmt: ^Prepared_Statement,
	args: ..any,
	allocator := context.allocator,
) -> (
	rows: Rows,
	err: Error,
) {
	if stmt.cnx == nil {
		err = db_error(.ConnectionError, "Prepared Statement's Connection is nil")
		return
	}
	n_args := len(args)

	if n_args != len(stmt.arg_types) {
		return {}, db_error(.InvalidArgument, fmt.tprintf("Expected '%d' arguments, got '%d' args", len(stmt.arg_types), n_args))
	}

	pd := make_param_data(stmt);defer delete_param_data(&pd)
	oids := extract_oids(stmt.arg_types);defer delete(oids) // cache this..?

	for arg, i in args {
		writing_type, ok := stmt.arg_types[i].(Postgres_Type)
		format := ok && writing_type.format != {} ? writing_type.format : .Text
		size, err := copy_into_buf(&pd.values, arg, oids[i], format, ok ? &writing_type : nil)
		if err != nil {return {}, err}
		pd.lengths[i] = size
		pd.formats[i] = format
	}

	p_lens := n_args > 0 ? &pd.lengths[0] : nil
	p_formats := n_args > 0 ? &pd.formats[0] : nil
	value_ptrs := get_value_ptrs(pd.values, pd.lengths, pd.formats)
	p_values := n_args > 0 ? transmute([^][^]byte)&value_ptrs[0] : nil
	defer if value_ptrs != nil {delete(value_ptrs)}

	result := pq.exec_prepared(
		stmt.cnx.cnx,
		stmt.name,
		i32(n_args),
		p_values,
		p_lens,
		p_formats,
		pq.Format.Text,
	)

	if result == nil {
		err_msg := pq.error_message(stmt.cnx.cnx)
		return {}, db_error(.ExecutionError, err_msg != nil ? strings.clone(string(err_msg), allocator) : "Unknown error")
	}

	status := pq.result_status(result)
	if status != pq.Exec_Status.Tuples_OK && status != pq.Exec_Status.Command_OK {
		err_msg := pq.result_error_message(result)
		return {}, db_error(.ExecutionError, err_msg != nil ? strings.clone(string(err_msg), allocator) : "Unknown error")
	}

	return result_into_rows(stmt.cnx, result)
}


@(private)
make_param_data :: proc(stmt: ^Prepared_Statement) -> Param_Data {
	return Param_Data {
		values = make([dynamic]byte),
		lengths = make([]i32, len(stmt.arg_types)),
		formats = make([]pq.Format, len(stmt.arg_types)),
	}
}
@(private)
delete_param_data :: proc(pd: ^Param_Data) {
	delete(pd.values)
	delete(pd.lengths)
	delete(pd.formats)
}
